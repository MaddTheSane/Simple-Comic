#import "TSSTXADArchiveSource.h"
#import "TSSTByteSourceHandle.h"
#import "TSSTRAR5QuickOpen.h"
#import "TSSTPage.h"

#import <XADMaster/XADArchiveParser.h>
#import <XADMaster/XADException.h>
#import <XADMaster/XADPath.h>
#import <XADMaster/XADString.h>

NSString * const TSSTXADArchiveSourceErrorDomain = @"TSSTXADArchiveSourceErrorDomain";

static const NSUInteger kBatchEntryCount = 16;
// Wall-clock a header walk may spend extracting entries for waiting readers
// (see -serviceRequestsLocked) before it just finishes listing.
static const NSTimeInterval kInlineServiceBudget = 1.5;
static const NSTimeInterval kBatchInterval = 0.1;

@implementation TSSTXADArchiveEntry

- (instancetype)initWithIndex:(NSUInteger)index
						  name:(NSString *)name
				   isDirectory:(BOOL)isDirectory
						  size:(unsigned long long)size
				  hasSpanRange:(BOOL)hasSpanRange
					 spanRange:(NSRange)spanRange
						 solid:(BOOL)solid
					 encrypted:(BOOL)encrypted
{
	if (self = [super init]) {
		_index = index;
		_name = [name copy];
		_isDirectory = isDirectory;
		_size = size;
		_hasSpanRange = hasSpanRange;
		_spanRange = spanRange;
		_solid = solid;
		_encrypted = encrypted;
	}
	return self;
}

@end

/// One in-flight -dataForEntry: request being serviced by the parse
/// thread. Waited on via the owner's condition.
@interface TSSTXADPendingRequest : NSObject
@property (nonatomic) NSUInteger index;
@property (nonatomic) BOOL completed;
@property (nonatomic, strong, nullable) NSData *result;
@property (nonatomic, strong, nullable) NSError *error;
@end
@implementation TSSTXADPendingRequest
@end

@interface TSSTXADArchiveSource () <XADArchiveParserDelegate>
@end

@implementation TSSTXADArchiveSource
{
	XADArchiveParser *_parser;
	NSString *_archivePath;
	TSSTXADArchiveSourcePasswordProvider _passwordProvider;

	// Guarded by _condition. _entryDicts only ever grows (append-only), so
	// reads of already-appended indices need no lock once observed.
	NSCondition *_condition;
	NSMutableArray<NSDictionary *> *_entryDicts;
	NSMutableArray<TSSTXADPendingRequest *> *_pendingRequests;
	BOOL _parseFinished;
	NSError *_parseError;

	// Serializes direct (post-parse) extraction, since the parser itself
	// isn't reentrant.
	NSLock *_extractionLock;
	BOOL _servicesRequestsWhileParsing; // parsing thread only; set by -parseWithEntryBatchHandler:
	NSTimeInterval _inlineServiceSpent; // parsing thread only; wall time spent extracting mid-walk

	// Batch bookkeeping; touched only from the parsing thread.
	NSMutableArray<TSSTXADArchiveEntry *> *_currentBatch;
	NSDate *_lastFlush;
	BOOL _flushedFirstImage;
	TSSTXADArchiveSourceBatchHandler _batchHandler;
}

- (nullable instancetype)initWithByteSource:(id<TSSTArchiveByteSource>)source
										name:(NSString *)name
										path:(NSString *)path
									password:(nullable NSString *)password
								   passwordProvider:(nullable TSSTXADArchiveSourcePasswordProvider)passwordProvider
									   error:(NSError **)error
{
	if (self = [super init]) {
		_archivePath = [path copy];
		_passwordProvider = [passwordProvider copy];
		_condition = [NSCondition new];
		_entryDicts = [NSMutableArray array];
		_pendingRequests = [NSMutableArray array];
		_extractionLock = [NSLock new];
		_currentBatch = [NSMutableArray array];
		_password = [password copy];

		CSHandle *handle = [[TSSTByteSourceHandle alloc] initWithByteSource: source];
		NSError *parserError = nil;
		_parser = [XADArchiveParser archiveParserForHandle: handle name: name nserror: &parserError];
		if (!_parser) {
			if (error) {
				*error = parserError ?: [NSError errorWithDomain: TSSTXADArchiveSourceErrorDomain code: TSSTXADArchiveSourceErrorCannotOpen userInfo: nil];
			}
			return nil;
		}
		_parser.delegate = self;
		if (_password) {
			_parser.password = _password;
		}
	}
	return self;
}

#pragma mark - Parsing

- (BOOL)parseWithEntryBatchHandler:(TSSTXADArchiveSourceBatchHandler)handler
{
	_batchHandler = [handler copy];
	_lastFlush = [NSDate date];

	NSError *error = nil;
	BOOL success;
	// A Quick Open listing hands over every entry in one CPU-only burst, so
	// nothing needs servicing mid-listing: requests wait for the parse to
	// finish and are then extracted by their own callers. Servicing them
	// inline instead would make each entry's discovery wait behind the
	// extractions already queued (seconds per page on a slow link). Only a
	// real header walk, which is slow itself, services requests as it goes
	// so page 1 can show before the walk ends.
	_servicesRequestsWhileParsing = NO;
	if ([TSSTRAR5QuickOpen listParser: _parser error: &error]) {
		success = (error == nil);
	} else {
		_servicesRequestsWhileParsing = YES;
		success = [_parser parseWithError: &error];
	}

	[self flushBatchFinal: NO];

	[_condition lock];
	_parseFinished = YES;
	_parseError = success ? nil : (error ?: [NSError errorWithDomain: TSSTXADArchiveSourceErrorDomain code: TSSTXADArchiveSourceErrorExtraction userInfo: nil]);
	[_condition broadcast];
	[_condition unlock];

	if (_batchHandler) {
		_batchHandler(@[], YES, success ? nil : _parseError);
	}

	return success;
}

- (NSUInteger)entryCount
{
	[_condition lock];
	NSUInteger count = _entryDicts.count;
	[_condition unlock];
	return count;
}

- (BOOL)parseFinished
{
	[_condition lock];
	BOOL finished = _parseFinished;
	[_condition unlock];
	return finished;
}

#pragma mark - Delegate (runs on the parsing thread)

- (BOOL)archiveParser:(XADArchiveParser *)parser foundEntryWithDictionary:(NSDictionary *)dict error:(NSError **)outError
{
	NSUInteger index;
	TSSTXADArchiveEntry *entry = [self recordForDictionary: dict index: &index];

	[_condition lock];
	[_entryDicts addObject: dict];
	[_currentBatch addObject: entry];
	[self serviceRequestsLocked];
	[_condition broadcast];
	[_condition unlock];

	// Get the first image out as soon as it's found so page 1 can show while
	// the (possibly slow) walk carries on; after that, batch by count/time.
	BOOL firstImage = NO;
	if (!_flushedFirstImage && !entry.isDirectory && [[TSSTPage imageExtensions] containsObject: entry.name.pathExtension.lowercaseString]) {
		_flushedFirstImage = firstImage = YES;
	}
	if (firstImage) {
		[self flushBatchFinal: NO];
	} else {
		[self flushBatchIfDueFinal: NO];
	}

	return YES;
}

- (BOOL)archiveParsingShouldStop:(XADArchiveParser *)parser
{
	// No cancellation support yet; use the callback as a chance to service
	// any queued extraction requests without waiting for the next entry.
	[_condition lock];
	[self serviceRequestsLocked];
	[_condition broadcast];
	[_condition unlock];
	return NO;
}

- (void)archiveParserNeedsPassword:(XADArchiveParser *)parser
{
	NSString *password = _password;
	if (!password && _passwordProvider) {
		NSString *path = _archivePath;
		__block NSString *prompted = nil;
		void (^promptBlock)(void) = ^{
			prompted = self->_passwordProvider(path, self->_password);
		};
		if ([NSThread isMainThread]) {
			promptBlock();
		} else {
			dispatch_sync(dispatch_get_main_queue(), promptBlock);
		}
		password = prompted;
	}
	_password = [password copy];
	parser.password = password;
}

/// Must be called with _condition held. Services every pending request
/// whose entry has now been found, saving and restoring the parser's
/// handle position around the extractions (XAD's delegate callback runs
/// with the handle wherever the header walk left it).
- (void)serviceRequestsLocked
{
	if (_pendingRequests.count == 0 || !_servicesRequestsWhileParsing) return;

	CSHandle *handle = _parser.handle;
	off_t saved = handle.offsetInFile;
	BOOL extractedAny = NO;

	while (YES) {
		TSSTXADPendingRequest *next = nil;
		for (TSSTXADPendingRequest *request in _pendingRequests) {
			if (!request.completed && request.index < _entryDicts.count) { next = request; break; }
		}
		// Past the budget, requests wait for the walk to finish and are then
		// extracted by their own callers: on a slow link each extraction here
		// would otherwise delay every remaining header by about as long as
		// the page takes to fetch, stretching the walk from seconds to minutes.
		if (!next || _inlineServiceSpent >= kInlineServiceBudget) break;

		// Extract without holding the lock (slow on a network volume), so
		// callers of -entryCount / -nameForEntryAtIndex: etc. aren't stuck
		// behind it. The parser's handle is only ever touched from this
		// (the parsing) thread while parsing.
		NSUInteger index = next.index;
		NSDictionary *dict = _entryDicts[index];
		[_condition unlock];
		NSError *extractError = nil;
		CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
		NSData *data = [self extractDictionary: dict error: &extractError];
		_inlineServiceSpent += CFAbsoluteTimeGetCurrent() - started;
		[_condition lock];
		extractedAny = YES;

		// Every caller waiting on this same entry (e.g. the visible page and
		// its pre-decode) shares the one extraction.
		for (TSSTXADPendingRequest *request in _pendingRequests) {
			if (request.completed || request.index != index) continue;
			request.result = data;
			request.error = extractError;
			request.completed = YES;
		}
		[_condition broadcast];
	}

	if (extractedAny) {
		[handle seekToFileOffset: saved];
	}
}

#pragma mark - Batching

- (void)flushBatchIfDueFinal:(BOOL)isFinal
{
	BOOL due = isFinal || _currentBatch.count >= kBatchEntryCount || -[_lastFlush timeIntervalSinceNow] >= kBatchInterval;
	if (due) {
		[self flushBatchFinal: isFinal];
	}
}

- (void)flushBatchFinal:(BOOL)isFinal
{
	if (_currentBatch.count == 0 && !isFinal) return;
	NSArray<TSSTXADArchiveEntry *> *batch = [_currentBatch copy];
	[_currentBatch removeAllObjects];
	_lastFlush = [NSDate date];
	if (_batchHandler) {
		_batchHandler(batch, NO, nil);
	}
}

#pragma mark - Entry records

/// Touches no parser state, so it is safe from any thread, unlike the span lookups.
- (nullable NSString *)nameForDictionary:(NSDictionary *)dict
{
	XADPath *xadName = dict[XADFileNameKey];
	return xadName.encodingIsKnown ? xadName.sanitizedPathString : [xadName sanitizedPathStringWithEncoding: NSISOLatin1StringEncoding];
}

- (TSSTXADArchiveEntry *)recordForDictionary:(NSDictionary *)dict index:(NSUInteger *)outIndex
{
	NSUInteger index = [dict[XADIndexKey] unsignedIntegerValue];
	if (outIndex) *outIndex = index;

	NSString *name = [self nameForDictionary: dict];

	BOOL isDirectory = [dict[XADIsDirectoryKey] boolValue];
	unsigned long long size = [dict[XADFileSizeKey] unsignedLongLongValue];
	BOOL solid = [dict[XADIsSolidKey] boolValue];
	BOOL encrypted = [dict[XADIsEncryptedKey] boolValue];

	NSRange span;
	BOOL hasSpan = [self spanForDictionary: dict range: &span];

	return [[TSSTXADArchiveEntry alloc] initWithIndex: index
												  name: name ?: @""
										   isDirectory: isDirectory
												  size: size
										  hasSpanRange: hasSpan
											 spanRange: span
												 solid: solid
											 encrypted: encrypted];
}

/// The min offset to max end of an entry's input parts, covering the RAR4
/// ("Parts" inside the solid-object dict, see XADRARParser.m), RAR5
/// ("RAR5InputParts", see XADRAR5Parser.m) and 7z (its folder's packed
/// streams, see -spanForSevenZipDictionary:range:) shapes. NO means the
/// entry has no known range.
- (BOOL)spanForDictionary:(NSDictionary *)dict range:(NSRange *)outRange
{
	NSArray *parts = dict[@"RAR5InputParts"];
	if (!parts) {
		id solidObject = dict[XADSolidObjectKey];
		if ([solidObject isKindOfClass: [NSArray class]]) {
			NSInteger solidIndex = [dict[@"RARSolidIndex"] integerValue];
			NSArray *files = (NSArray *)solidObject;
			if (solidIndex >= 0 && (NSUInteger)solidIndex < files.count) {
				parts = files[solidIndex][@"Parts"];
			}
		}
	}
	if (!parts) return [self spanForSevenZipDictionary: dict range: outRange];
	if (![parts isKindOfClass: [NSArray class]] || parts.count == 0) return NO;

	unsigned long long minOffset = ULLONG_MAX;
	unsigned long long maxEnd = 0;
	for (NSDictionary *part in parts) {
		id offsetValue = part[@"Offset"] ?: part[@"InputOffset"];
		id lengthValue = part[@"InputLength"] ?: part[@"Length"];
		if (!offsetValue || !lengthValue) return NO;
		unsigned long long offset = [offsetValue unsignedLongLongValue];
		unsigned long long length = [lengthValue unsignedLongLongValue];
		if (offset < minOffset) minOffset = offset;
		if (offset + length > maxEnd) maxEnd = offset + length;
	}
	if (minOffset == ULLONG_MAX || maxEnd <= minOffset) return NO;

	outRange->location = (NSUInteger)minOffset;
	outRange->length = (NSUInteger)(maxEnd - minOffset);
	return YES;
}

/// A 7z entry's range is its folder's packed streams (PackInfo/UnpackInfo):
/// one folder per non-solid file, one shared folder for a solid block, so
/// entries of a solid block all report the same range. XAD7ZipParser keeps
/// the parsed header in its (protected) `mainstreams` ivar, which holds
/// "Folders", each with "InStreams" -> "PackedStream" {Offset, Size}, and
/// XADSolidObjectKey on the entry is the folder index.
- (BOOL)spanForSevenZipDictionary:(NSDictionary *)dict range:(NSRange *)outRange
{
	NSNumber *folderIndex = dict[XADSolidObjectKey];
	if (![folderIndex isKindOfClass: [NSNumber class]] || ![NSStringFromClass([_parser class]) isEqualToString: @"XAD7ZipParser"]) return NO;

	NSDictionary *mainStreams = nil;
	@try { mainStreams = [_parser valueForKey: @"mainstreams"]; }
	@catch (id exception) { return NO; }
	NSArray *folders = [mainStreams isKindOfClass: [NSDictionary class]] ? mainStreams[@"Folders"] : nil;
	if (![folders isKindOfClass: [NSArray class]] || folderIndex.unsignedIntegerValue >= folders.count) return NO;

	unsigned long long minOffset = ULLONG_MAX;
	unsigned long long maxEnd = 0;
	for (NSDictionary *inStream in folders[folderIndex.unsignedIntegerValue][@"InStreams"]) {
		NSDictionary *packed = inStream[@"PackedStream"];
		if (!packed) continue;
		unsigned long long offset = [packed[@"Offset"] unsignedLongLongValue];
		unsigned long long length = [packed[@"Size"] unsignedLongLongValue];
		if (offset < minOffset) minOffset = offset;
		if (offset + length > maxEnd) maxEnd = offset + length;
	}
	if (minOffset == ULLONG_MAX || maxEnd <= minOffset) return NO;

	outRange->location = (NSUInteger)minOffset;
	outRange->length = (NSUInteger)(maxEnd - minOffset);
	return YES;
}

#pragma mark - Extraction

/// Not thread-safe on its own -- caller must ensure only one thread ever
/// touches _parser at a time (either the parsing thread mid-parse, or
/// under _extractionLock post-parse).
- (nullable NSData *)extractDictionary:(NSDictionary *)dict error:(NSError **)error
{
	@try {
		CSHandle *handle = [_parser handleForEntryWithDictionary: dict wantChecksum: YES];
		if (!handle) {
			if (error) *error = [NSError errorWithDomain: TSSTXADArchiveSourceErrorDomain code: TSSTXADArchiveSourceErrorExtraction userInfo: nil];
			return nil;
		}
		NSData *data = [handle remainingFileContents];
		return data;
	}
	@catch (id exception) {
		if (error) *error = [XADException parseExceptionReturningNSError: exception];
		return nil;
	}
}

- (nullable NSString *)nameForEntryAtIndex:(NSUInteger)index
{
	[_condition lock];
	while (index >= _entryDicts.count && !_parseFinished) {
		[_condition wait];
	}
	NSDictionary *dict = index < _entryDicts.count ? _entryDicts[index] : nil;
	[_condition unlock];
	if (!dict) return nil;

	return [self nameForDictionary: dict] ?: @"";
}

- (nullable NSData *)dataForEntry:(NSUInteger)index error:(NSError **)error
{
	[_condition lock];

	while (index >= _entryDicts.count && !_parseFinished) {
		[_condition wait];
	}

	if (index >= _entryDicts.count) {
		// Parse finished without ever finding this entry.
		[_condition unlock];
		if (error) *error = [NSError errorWithDomain: TSSTXADArchiveSourceErrorDomain code: TSSTXADArchiveSourceErrorEntryNotFound userInfo: nil];
		return nil;
	}

	if (!_parseFinished) {
		// Parse still running: hand the request to the parsing thread,
		// which extracts it inline (header walk) or leaves it for direct
		// extraction below once the parse has finished (Quick Open).
		TSSTXADPendingRequest *request = [TSSTXADPendingRequest new];
		request.index = index;
		[_pendingRequests addObject: request];

		while (!request.completed && !_parseFinished) {
			[_condition wait];
		}
		[_pendingRequests removeObject: request];
		if (request.completed) {
			[_condition unlock];
			if (request.error) {
				if (error) *error = request.error;
				return nil;
			}
			return request.result;
		}
	}

	// The parsing thread is done; safe to extract directly here, as long
	// as we serialize with any other post-parse caller.
	NSDictionary *dict = _entryDicts[index];
	[_condition unlock];

	[_extractionLock lock];
	NSData *data = [self extractDictionary: dict error: error];
	[_extractionLock unlock];
	return data;
}

@end
