//
//  TSSTManagedGroup.m
//  SimpleComic
//
//  Created by Alexander Rauchfuss on 6/2/07.
//  Copyright 2007 Dancing Tortoise Software. All rights reserved.
//

#import "TSSTManagedGroup.h"
#import "TSSTManagedGroup+CoreDataProperties.h"
#import "SimpleComicAppDelegate.h"
#import <XADMaster/XADArchive.h>
#import <Quartz/Quartz.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import "TSSTImageUtilities.h"
#import "TSSTPage.h"
#import "TSSTPage+CoreDataProperties.h"
#import "TSSTZipIndex.h"
#import "TSSTArchiveByteSource.h"
#import "TSSTCachingByteSource.h"
#import "TSSTArchiveStreamer.h"
#import "TSSTXADArchiveSource.h"
#import "TSSTFileSetByteSource.h"
#import <sys/stat.h>

/// Streaming state shared by every backend (zip index, XAD source, folder
/// file set): a caching byte source, the streamer that fills it in reading
/// order, and the entry index -> span index map behind
/// -noteReadingEntryIndex:/-isEntryIndexCached:. A folder's subfolders route
/// to the topmost group that owns one (see -streamingOwner).
@interface TSSTManagedGroup ()
{
	@protected
	// Set only when reads go through a caching byte source (slow volume, or
	// SC_SIMULATE_LINK). nil on local volumes.
	TSSTCachingByteSource *_cachingSource;
	TSSTArchiveStreamer *_streamer;
	NSDictionary<NSNumber *, NSNumber *> *_entryIndexToSpanIndex;
	// Folder backend (TSSTFileSetByteSource): nil for archives and for
	// folders that read straight from disk.
	TSSTFileSetByteSource *_fileSet;
	// File index -> path of the folder's loose-file pages, for reading a
	// restored session's pages without a file set. Built lazily on the
	// context's queue, dropped whenever children are inserted.
	NSDictionary<NSNumber *, NSString *> *_restoredPathByIndex;
	NSUInteger _restoredPathPageCount; // nested page count when the map was built
	NSUInteger _restoredPathBuildCount; // how many times it was built (tests)
}
- (void)startStreamerWithSpans:(NSArray<NSValue *> *)spans entryIndexMap:(nullable NSDictionary<NSNumber *, NSNumber *> *)map;
- (nullable TSSTManagedGroup *)streamingOwner;
/// YES for a group whose pages are read through the group itself (an archive
/// or PDF), NO for a folder, whose pages read through the streaming folder
/// above it (or their own files).
- (BOOL)isLeafPageSource;
- (void)tearDownStreaming;
@end

@interface TSSTManagedArchive () <XADArchiveDelegate>
{
	// Fast-path zip listing/reading, built lazily. Not persisted -- if the
	// managed object is re-fetched (e.g. session restore) this is nil again
	// and gets lazily rebuilt from fileURL, or the code falls back to XAD.
	//
	// The lock is a condition guarding only the state flags: a build (slow
	// I/O on a network volume) runs with no lock held, and concurrent
	// callers wait for its result instead of building a second index.
	TSSTZipIndex *_zipIndex;
	BOOL _zipIndexAttempted;
	BOOL _zipIndexBuilding;
	NSCondition *_zipIndexLock;

	// Streaming RAR/7z backend (TSSTXADArchiveSource), built lazily like
	// _zipIndex -- not persisted, rebuilt from fileURL if the managed
	// object is re-fetched (session restore).
	TSSTXADArchiveSource *_xadSource;
	BOOL _xadSourceAttempted;
	BOOL _xadSourceBuilding;
	NSCondition *_xadSourceLock;
	// YES once we've kicked off a background parse for a lazily-rebuilt
	// _xadSource (session restore path, where nothing progressive is
	// listening for batches).
	BOOL _xadSourceParseStarted;
}
-(void)archiveNeedsPassword:(XADArchive *)archive;

@end

@interface TSSTManagedPDF ()
/// Main-thread only: applies a PDF-kind record built while scanning an
/// enclosing archive, reusing its already-built PDFDocument instead of re-parsing.
- (void)applyPDFScanRecord:(TSSTArchiveScanRecord *)record;
@end

/// Kinds of children a scan can produce: one per entity type `-applyScanRecord:` inserts.
typedef NS_ENUM(NSInteger, TSSTArchiveScanRecordKind)
{
	TSSTArchiveScanRecordKindImage,
	TSSTArchiveScanRecordKindArchive,
	TSSTArchiveScanRecordKindPDF,
	TSSTArchiveScanRecordKindFolder,
};

/*
 * Plain value object describing one archive's worth of scanned entries (the
 * public face, `children`, is declared in the header).
 * Built entirely off values (no NSManagedObject / MOC access) so it can be
 * produced on a background queue; a matching -applyScanRecord: on the main
 * thread walks it and inserts the actual Core Data entities.
 */
@interface TSSTArchiveScanRecord ()

@property (nonatomic) TSSTArchiveScanRecordKind kind;
@property (nonatomic, copy, nullable) NSString *name;      // entry name / archive name
@property (nonatomic, copy, nullable) NSString *imagePath; // image/text kind: entry name used as imagePath
@property (nonatomic, copy, nullable) NSString *path;      // archive/pdf kind: temp file path
@property (nonatomic) NSInteger index;     // archive entry index / folder file index; -1 when the page has none
@property (nonatomic) BOOL text;
@property (nonatomic, strong, nullable) NSURL *url; // folder children: the real file/folder URL
@property (nonatomic) BOOL isUserFile;              // archive/pdf kind: path is the user's own file (folder child), never deleted with the group

// Archive/self-describing fields (used for the top-level record and for
// TSSTArchiveScanRecordKindArchive children):
@property (nonatomic, copy, nullable) NSString *password;
@property (nonatomic, copy, nullable) NSString *solidDirectory;
@property (nonatomic, strong, nullable) id builtInstance; // TSSTZipIndex, XADArchive or PDFDocument, pre-built, ready to reuse
@property (nonatomic, strong, nullable) TSSTCachingByteSource *builtCachingSource; // set only when builtInstance's zip index reads through a cache
@property (nonatomic, strong, readwrite, nullable) NSArray<TSSTArchiveScanRecord *> *children;
@property (nonatomic, copy, nullable) NSString *backendDescription; // which backend listed it (e.g. "zip-index", "XAD"); tests assert on it

/// Progressive XAD (RAR/7z) top-level scan fields:
@property (nonatomic, strong, nullable) TSSTXADArchiveSource *builtXADSource;
/// Set only on the final progressive batch: every entry found, in the
/// order XAD reported them, used to build the streamer's reading-order
/// spans once the whole parse is done.
@property (nonatomic, readwrite, copy, nullable) NSArray<TSSTXADArchiveEntry *> *xadAllEntriesForStreamer;

// PDF kind:
@property (nonatomic) NSInteger pdfPageCount;

// Folder kind (top-level record only, when streaming):
@property (nonatomic, strong, nullable) TSSTFileSetByteSource *builtFileSet;
@property (nonatomic, copy, nullable) NSArray<NSNumber *> *folderReadingOrder; // file indices, in display order

/// Set only on the final batch: every non-fatal error collected across the
/// whole scan (nested-archive/PDF extraction failures), to be reported
/// individually by the caller.
@property (nonatomic, readwrite, copy, nullable) NSArray<NSError *> *scanErrors;

@end

@implementation TSSTArchiveScanRecord
- (instancetype)init
{
	if ((self = [super init])) { _index = -1; }
	return self;
}
@end

/// Runs `block` on the main thread: inline when already there, otherwise
/// synchronously if `wait`, else asynchronously.
static void TSSTRunOnMainThread(BOOL wait, dispatch_block_t block)
{
	if (NSThread.isMainThread) { block(); }
	else if (wait) { dispatch_sync(dispatch_get_main_queue(), block); }
	else { dispatch_async(dispatch_get_main_queue(), block); }
}

/// Lightweight `XADArchiveDelegate` used only while building an `XADArchive` on
/// a background scan queue.
///
/// It must never touch a managed object -- the
/// password prompt itself is bounced to the main thread since it's UI.
@interface TSSTScanArchiveDelegate : NSObject <XADArchiveDelegate>
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy, nullable) NSString *password;
@end

@implementation TSSTScanArchiveDelegate

- (void)archiveNeedsPassword:(XADArchive *)archive
{
	NSString *password = self.password;
	if (password)
	{
		archive.password = password;
		return;
	}

	__block NSString *promptedPassword = nil;
	NSString *path = self.path;
	TSSTRunOnMainThread(YES, ^{
		promptedPassword = [(SimpleComicAppDelegate*)[NSApp delegate] passwordForArchiveWithPath: path];
	});

	archive.password = promptedPassword;
	self.password = promptedPassword;
}

@end

typedef NS_ENUM(NSInteger, TSSTScanEntryClass)
{
	TSSTScanEntryClassIgnored,
	TSSTScanEntryClassImage,
	TSSTScanEntryClassText,
	TSSTScanEntryClassArchive,
	TSSTScanEntryClassPDF,
};

/// What a scan does with an archive entry of this name (empty and dot-prefixed names are skipped).
static TSSTScanEntryClass TSSTClassifyScanEntryName(NSString *fileName)
{
	if (fileName.length == 0 || [fileName.lastPathComponent hasPrefix: @"."]) { return TSSTScanEntryClassIgnored; }
	static NSDictionary<NSString *, NSNumber *> *classByExtension;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		// Later additions win, so images take precedence over archives over text.
		NSMutableDictionary<NSString *, NSNumber *> *classes = [NSMutableDictionary dictionaryWithObject: @(TSSTScanEntryClassPDF) forKey: @"pdf"];
		for (NSString *extension in TSSTPage.textExtensions) { classes[extension] = @(TSSTScanEntryClassText); }
		for (NSString *extension in TSSTManagedArchive.archiveExtensions) { classes[extension] = @(TSSTScanEntryClassArchive); }
		for (NSString *extension in TSSTPage.imageExtensions) { classes[extension] = @(TSSTScanEntryClassImage); }
		classByExtension = [classes copy];
	});
	return (TSSTScanEntryClass)classByExtension[fileName.pathExtension.lowercaseString].integerValue;
}

/// YES when every entry a scan must read (nested archives/PDFs) can be
/// extracted by the zip index; otherwise the scan falls back to XAD, which
/// also handles non-zip formats and solid archives.
static BOOL TSSTZipIndexCanScan(TSSTZipIndex *zi)
{
	if (!zi) { return NO; }
	for (NSUInteger i = 0; i < zi.numberOfEntries; ++i)
	{
		TSSTScanEntryClass entryClass = TSSTClassifyScanEntryName([zi nameOfEntry: i]);
		if ((entryClass == TSSTScanEntryClassArchive || entryClass == TSSTScanEntryClassPDF) && ![zi canExtractEntry: i])
		{
			return NO;
		}
	}
	return YES;
}

static TSSTArchiveScanRecord *TSSTImageChildRecord(NSString *fileName, NSInteger index, BOOL text)
{
	TSSTArchiveScanRecord *child = [TSSTArchiveScanRecord new];
	child.kind = TSSTArchiveScanRecordKindImage;
	child.imagePath = fileName;
	child.index = index;
	child.text = text;
	return child;
}

NSString *TSSTCreateUnusedTempPath(BOOL isDirectory, NSString *NS_NOESCAPE (^candidateName)(NSInteger attempt))
{
	for (NSInteger attempt = 0; ; ++attempt)
	{
		NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent: candidateName(attempt)];
		int result;
		if (isDirectory)
		{
			result = mkdir(path.fileSystemRepresentation, 0755);
		}
		else
		{
			// Candidate names may contain folders.
			[[NSFileManager defaultManager] createDirectoryAtPath: path.stringByDeletingLastPathComponent
									  withIntermediateDirectories: YES attributes: nil error: NULL];
			result = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0644);
			if (result >= 0) { close(result); result = 0; }
		}
		// Only "already exists" means try the next name; for any other error
		// hand back the path and let the caller's write report the problem.
		if (result == 0 || errno != EEXIST) { return path; }
	}
}

/// Extracts a nested archive to a temp file ("<n>-<fileName>") and scans it,
/// returning its own record as an archive child.
static TSSTArchiveScanRecord *TSSTNestedArchiveChildRecord(NSData *fileData, NSString *fileName)
{
	NSString *archivePath = TSSTCreateUnusedTempPath(NO, ^NSString *(NSInteger n) {
		return [NSString stringWithFormat: @"%li-%@", (long)n, fileName];
	});
	[fileData writeToFile: archivePath atomically: NO];

	TSSTArchiveScanRecord *nestedRecord = [TSSTManagedArchive scanRecordForFileURL: [NSURL fileURLWithPath: archivePath] name: fileName password: nil];
	nestedRecord.kind = TSSTArchiveScanRecordKindArchive;
	nestedRecord.path = archivePath;
	return nestedRecord;
}

/// Writes a nested PDF's bytes to the temp directory (under its base name,
/// "<n>-" prefixed until unused) and returns its record, PDFDocument built.
static TSSTArchiveScanRecord *TSSTPDFChildRecord(NSData *fileData, NSString *fileName)
{
	NSString *baseName = fileName.lastPathComponent;
	NSString *pdfPath = TSSTCreateUnusedTempPath(NO, ^NSString *(NSInteger n) {
		return n == 0 ? baseName : [NSString stringWithFormat: @"%li-%@", (long)n, baseName];
	});
	[fileData writeToFile: pdfPath atomically: NO];

	TSSTArchiveScanRecord *child = [TSSTArchiveScanRecord new];
	child.kind = TSSTArchiveScanRecordKindPDF;
	child.path = pdfPath;
	child.name = fileName;
	PDFDocument *pdfDoc = [[PDFDocument alloc] initWithURL: [NSURL fileURLWithPath: pdfPath]];
	child.builtInstance = pdfDoc;
	child.pdfPageCount = pdfDoc.pageCount;
	return child;
}

#pragma mark - Folder scanning

/// Shared state while walking one folder tree (see
/// +scanRecordForFolderURL:name:streaming:).
@interface TSSTFolderScanContext : NSObject
@property (nonatomic) BOOL streaming;
@property (nonatomic, strong) NSMutableArray<NSURL *> *files;      // streaming: every image/text file, indexed
@property (nonatomic, strong) NSMutableArray<NSNumber *> *sizes;
@property (nonatomic, strong) NSMutableArray<TSSTArchiveScanRecord *> *fileRecords;
@end

@implementation TSSTFolderScanContext
- (instancetype)init
{
	if ((self = [super init]))
	{
		_files = [NSMutableArray array];
		_sizes = [NSMutableArray array];
		_fileRecords = [NSMutableArray array];
	}
	return self;
}
@end

#if DEBUG
/// The DEBUG SC_SIMULATE_LINK profile name ("wifi", "smb", "lan"), or nil.
/// Read live from the environment (not NSProcessInfo's launch-time
/// snapshot) so tests can switch it per test.
static NSString * _Nullable TSSTSimulatedLinkProfileName(void)
{
	const char *value = getenv("SC_SIMULATE_LINK");
	return (value && *value) ? [[NSString stringWithUTF8String: value] lowercaseString] : nil;
}
#endif

/// The display order pages are sorted in (TSSTSortDescriptor's comparison
/// on imagePath), which is also the order the streamer reads in.
static NSComparisonResult TSSTReadingOrderCompare(NSString *a, NSString *b)
{
	const NSStringCompareOptions comparisonOptions = NSCaseInsensitiveSearch | NSNumericSearch | NSWidthInsensitiveSearch | NSForcedOrderingSearch;
	return [a compare: b options: comparisonOptions];
}

NSString * const TSSTArchiveCacheProgressNotification = @"TSSTArchiveCacheProgressNotification";

/*
 * Batching of per-file URL errors. setFileURL:/fileURL report failures through
 * +reportURLError:, which queues them while a recursive scan
 * (nestedFolderContents/nestedArchiveContents) is running and presents a single
 * summary alert from +endURLErrorBatch once the whole top-level scan finishes.
 * Outside a scan (depth 0) the error is presented immediately.
 *
 * Scans can run on background threads, so the batch is kept per thread (in
 * the thread dictionary) rather than in shared statics: each scan only ever
 * touches its own batch, which needs no locking and keeps concurrent scans'
 * errors from being mixed into one alert.
 */
@interface TSSTURLErrorBatch : NSObject
@property NSInteger depth;
@property (copy) NSString *groupName;
@property (readonly) NSMutableArray<NSError *> *errors;
@end

@implementation TSSTURLErrorBatch
- (instancetype)init
{
	if ((self = [super init]))
	{
		_errors = [NSMutableArray array];
	}
	return self;
}
@end

static NSString *const kURLErrorBatchThreadKey = @"TSSTManagedGroupURLErrorBatch";

static TSSTURLErrorBatch *CurrentURLErrorBatch(void)
{
	return NSThread.currentThread.threadDictionary[kURLErrorBatchThreadKey];
}

@implementation TSSTManagedGroup

+ (void)beginURLErrorBatchForGroupName:(NSString *)groupName
{
	TSSTURLErrorBatch *batch = CurrentURLErrorBatch();
	if (batch == nil)
	{
		batch = [[TSSTURLErrorBatch alloc] init];
		batch.groupName = groupName;
		NSThread.currentThread.threadDictionary[kURLErrorBatchThreadKey] = batch;
	}
	batch.depth++;
}

/// Pure summary-message builder, split out of endURLErrorBatch so it can be
/// unit tested without going through NSAlert/-runModal.
+ (nullable NSString *)urlErrorBatchSummaryMessageForErrorCount:(NSUInteger)errorCount groupName:(NSString *)groupName
{
	if (errorCount == 0)
	{
		return nil;
	}
	return [NSString localizedStringWithFormat: NSLocalizedString(@"%lu files in \"%@\" could not be opened.", @"unreadable files summary"), (unsigned long)errorCount, groupName];
}

+ (void)endURLErrorBatch
{
	TSSTURLErrorBatch *batch = CurrentURLErrorBatch();
	if (batch == nil || --batch.depth > 0)
	{
		return;
	}
	[NSThread.currentThread.threadDictionary removeObjectForKey: kURLErrorBatchThreadKey];
	NSString *summary = [self urlErrorBatchSummaryMessageForErrorCount: batch.errors.count groupName: batch.groupName];
	if (summary == nil)
	{
		return;
	}
	// A modal alert would hang a hosted test run waiting for a click.
	if (NSClassFromString(@"XCTestCase") != Nil) { return; }
	NSString *detail = batch.errors.firstObject.localizedDescription ?: @"";
	// Alerts belong on the main thread; don't block the scan thread on the user.
	dispatch_block_t present = ^{
		NSAlert *alert = [[NSAlert alloc] init];
		alert.alertStyle = NSAlertStyleWarning;
		alert.messageText = summary;
		alert.informativeText = detail;
		[alert runModal];
	};
	TSSTRunOnMainThread(NO, present);
}

+ (void)reportURLError:(NSError *)error
{
	TSSTURLErrorBatch *batch = CurrentURLErrorBatch();
	if (batch != nil)
	{
		[batch.errors addObject: error];
	}
	else
	{
		[NSApp presentError: error];
	}
}

/// Runs `during` inside a begin/end pair. The end is in a `@finally` so an
/// exception thrown by the scan can't leave this thread's batch depth stuck
/// above zero (which would silently swallow every later error into a batch
/// that never presents).
+ (void)batchURLErrorsForGroupName:(NSString *)groupName during:(void (^)(NSMutableArray<NSError *> *errors))during
{
	[self beginURLErrorBatchForGroupName: groupName];
	NSMutableArray<NSError *> *errors = [NSMutableArray array];
	@try
	{
		during(errors);
	}
	@finally
	{
		for (NSError *error in errors)
		{
			[self reportURLError: error];
		}
		[self endURLErrorBatch];
	}
}

#pragma mark - Testing support
// Accessors for the current thread's batch, used only by
// TSSTManagedGroupURLErrorBatchTests so the test target can observe queueing
// behavior without ever triggering the NSAlert/-runModal path.

+ (NSInteger)urlErrorBatchDepthForTesting
{
	return CurrentURLErrorBatch().depth;
}

+ (NSUInteger)pendingURLErrorCountForTesting
{
	return CurrentURLErrorBatch().errors.count;
}

+ (void)resetURLErrorBatchStateForTesting
{
	[NSThread.currentThread.threadDictionary removeObjectForKey: kURLErrorBatchThreadKey];
}

- (void)awakeFromInsert
{
	[super awakeFromInsert];
	groupLock = [NSLock new];
	instance = nil;
}

- (void)awakeFromFetch
{
	[super awakeFromFetch];
	groupLock = [NSLock new];
	instance = nil;
}

- (void)willTurnIntoFault
{
	NSError * error = nil;
	if(self.nested)
	{
		NSURL *fileURL = self.fileURL;
		if(fileURL != nil && ![[NSFileManager defaultManager] removeItemAtURL:fileURL  error: &error])
		{
			NSLog(@"%@",[error localizedDescription]);
		}
	}
	[self.fileURL stopAccessingSecurityScopedResource];
	[_streamer cancel];
	[_cachingSource invalidate];
}

- (void)didTurnIntoFault
{
	instance = nil;
	groupLock = nil;
	_restoredPathByIndex = nil;
	[self tearDownStreaming];
}

@synthesize fileURL=_url;

- (void)setFileURL:(NSURL *)fileURL
{
	if (_url && _url != fileURL) {
		// Balance the access we started on the old URL, not the new one.
		[_url stopAccessingSecurityScopedResource];
	}
	_url = fileURL;
	NSError * urlError = nil;
	[fileURL startAccessingSecurityScopedResource];
	NSData * bookmarkData = [fileURL bookmarkDataWithOptions: NSURLBookmarkCreationWithSecurityScope | NSURLBookmarkCreationSecurityScopeAllowOnlyReadAccess
							  includingResourceValuesForKeys: @[NSURLVolumeURLForRemountingKey, NSURLVolumeUUIDStringKey]
											   relativeToURL: nil
													   error: &urlError];
	if (bookmarkData == nil || urlError != nil)
	{
		bookmarkData = nil;
		[TSSTManagedGroup reportURLError: urlError];
	}
	self.pathData = bookmarkData;
}

/// helper: common code of `probeFileURL` and `fileURL`
- (NSURL *)ResolvingURLWithStale:(BOOL *)stalep error:(NSError **)errorp {
	return self.pathData ? [NSURL URLByResolvingBookmarkData: self.pathData
												options: NSURLBookmarkResolutionWithoutUI | NSURLBookmarkResolutionWithSecurityScope
										  relativeToURL: nil
									bookmarkDataIsStale: stalep
												  error: errorp] : nil;
}

- (NSURL *)probeFileURL {
	if (_url && [_url checkResourceIsReachableAndReturnError:NULL]) {
		return _url;
	}
	NSError * urlError = nil;
	BOOL stale = NO;
	NSURL *fileURL = [self ResolvingURLWithStale:&stale error:&urlError];
	if (stale && fileURL) {
		// regenerate stale bookmark.
		self.fileURL = fileURL;
	} else if (fileURL) {
		//cache fileURL
		_url = fileURL;
	}
	return fileURL;
}

- (NSURL *)fileURL
{
	if (_url && [_url checkResourceIsReachableAndReturnError:NULL]) {
		return _url;
	}
	NSError * urlError = nil;
	BOOL stale = NO;
	NSURL *fileURL = [self ResolvingURLWithStale:&stale error:&urlError];
	//For backwards compatibility
	if (fileURL == nil || urlError != nil) {
		NSError *othErr = nil;
		fileURL = [NSURL URLByResolvingBookmarkData: self.pathData
											options: 0
									  relativeToURL: nil
								bookmarkDataIsStale: &stale
											  error: &othErr];
		
		if (fileURL && othErr == nil) {
			NSOpenPanel *panel = [NSOpenPanel openPanel];
			panel.canChooseDirectories = YES;
			panel.allowsMultipleSelection = NO;
			//panel.expanded = YES;
			panel.message = [NSString stringWithFormat:NSLocalizedString(@"Please re-select '%@'", @"re-select file request"), fileURL.lastPathComponent];
			panel.directoryURL = [fileURL URLByDeletingLastPathComponent];
			
			if ([panel runModal] == NSModalResponseOK) {
				othErr = nil;
				NSData *bookmarkData = [panel.URL bookmarkDataWithOptions: NSURLBookmarkCreationWithSecurityScope | NSURLBookmarkCreationSecurityScopeAllowOnlyReadAccess
										   includingResourceValuesForKeys: @[NSURLVolumeURLForRemountingKey, NSURLVolumeUUIDStringKey]
															relativeToURL: nil
																	error: &othErr];
				
				if (bookmarkData) {
					self.pathData = bookmarkData;
					fileURL = [NSURL URLByResolvingBookmarkData: bookmarkData
														options: NSURLBookmarkResolutionWithoutUI | NSURLBookmarkResolutionWithSecurityScope
												  relativeToURL: nil
											bookmarkDataIsStale: &stale
														  error: &othErr];
					
				}
			} else {
				fileURL = nil;
			}
			urlError = othErr;
		}
	}
	
	if (fileURL == nil || urlError != nil)
	{
		fileURL = nil;
		[[self managedObjectContext] deleteObject: self];
		if (urlError) {
			[TSSTManagedGroup reportURLError: urlError];
		}
	}
	else if (stale)
	{
		// regenerate stale bookmark.
		self.fileURL = fileURL;
	} else {
		//cache fileURL
		_url = fileURL;
	}
	
	return fileURL;
}

- (void)setPath:(NSString *)newPath
{
	self.fileURL = [[NSURL alloc] initFileURLWithPath: newPath];
}


- (NSString *)path
{
	return self.fileURL.path;
}


- (id)instance
{
	return nil;
}

- (NSData *)dataForPageIndex:(NSInteger)index
{
	return nil;
}

/// Folder pages that stream carry the index of their file in the top folder's
/// file set (folders read straight from disk have no index and never get
/// here). Reads go through the same caching source the streamer fills.
- (void)requestDataForPageIndex:(NSInteger)index completionHandler:(void(^)(NSData *_Nullable pageData, NSError *_Nullable error))callback
{
	TSSTManagedGroup *owner = [self streamingOwner];
	TSSTFileSetByteSource *fileSet = owner ? owner->_fileSet : nil;
	if (fileSet && index >= 0 && (NSUInteger)index < fileSet.fileCount)
	{
		NSRange range = [fileSet rangeOfFileAtIndex: (NSUInteger)index];
		NSError *error = nil;
		NSData *data = [owner->_cachingSource readAtOffset: range.location length: range.length error: &error];
		callback(data, error);
		return;
	}
	// A restored session: pages remember their file index but the file set
	// (not persisted) is gone. Read the page's own file straight from disk.
	NSString *path = [self restoredFilePathForEntryIndex: index];
	if (path)
	{
		NSError *error = nil;
		NSData *data = [NSData dataWithContentsOfFile: path options: 0 error: &error];
		callback(data, error);
		return;
	}
	callback(nil, [NSError errorWithDomain:NSOSStatusErrorDomain code:unimpErr userInfo:nil]);
}

/// Path of the loose file whose file index is `index`, from a map built
/// once and reused (this used to scan every nested page per read). A miss
/// rebuilds the map only if pages were added since it was built, so pages
/// added behind its back are still found without a permanent miss costing
/// a rebuild per call. Pages of a nested archive number their entries from
/// 0 in their own index space, so they can collide with a folder file's
/// index: they are left out. Context's queue only.
- (nullable NSString *)restoredFilePathForEntryIndex:(NSInteger)index
{
	NSString *path = _restoredPathByIndex[@(index)];
	if (path) { return path; }
	NSUInteger pageCount = [self nestedImageCount];
	if (_restoredPathByIndex && pageCount == _restoredPathPageCount) { return nil; }

	NSMutableDictionary<NSNumber *, NSString *> *map = [NSMutableDictionary dictionary];
	for (TSSTPage *page in self.nestedImages)
	{
		if ([page.group isKindOfClass: [TSSTManagedArchive class]] || page.index == nil || page.imagePath.length == 0) { continue; }
		map[page.index] = page.imagePath;
	}
	_restoredPathByIndex = map;
	_restoredPathPageCount = pageCount;
	_restoredPathBuildCount++;
	return map[@(index)];
}

- (NSUInteger)restoredPathMapBuildCountForTesting
{
	return _restoredPathBuildCount;
}

/// Same as `self.nestedImages.count` without building the set.
- (NSUInteger)nestedImageCount
{
	NSUInteger count = self.images.count;
	for (TSSTManagedGroup *group in self.groups) { count += [group nestedImageCount]; }
	return count;
}

/// The group a page snapshot should read through (see -[TSSTPage
/// dataSnapshot]): resolved here, on the context's queue, because walking
/// up to the streaming folder reads Core Data. An archive or PDF reads its
/// own pages; a folder reads through the folder that owns the cache, and
/// nil (the page reads its own file) when nothing streams.
- (nullable TSSTManagedGroup *)groupForOffQueueReads
{
	if ([self isLeafPageSource]) { return self; }
	return [self streamingOwner];
}

- (BOOL)isLeafPageSource
{
	return NO;
}

- (NSManagedObject *)topLevelGroup
{
	return self;
}

- (nullable NSString *)nameOfEntryAtIndex:(NSInteger)index
{
	return nil;
}

- (void)nestedFolderContents
{
	[TSSTManagedGroup batchURLErrorsForGroupName: self.name ?: self.fileURL.lastPathComponent during: ^(NSMutableArray<NSError *> *errors) {
		// Local folders never stream: reads stay straight from disk.
		[self applyFolderScanRecord: [TSSTManagedGroup scanRecordForFolderURL: self.fileURL name: self.name streaming: NO]];
	}];
}

/// DEBUG SC_SIMULATE_LINK: a directory read costs one round trip.
+ (void)simulateDirectoryLatency
{
#if DEBUG
	NSString *profile = TSSTSimulatedLinkProfileName();
	if (profile)
	{
		TSSTFileSetByteSource *empty = [[TSSTFileSetByteSource alloc] initWithFileURLs: @[] sizes: @[]];
		TSSTSimulatedLinkByteSource *link = [TSSTSimulatedLinkByteSource linkWithProfileName: profile wrapping: empty];
		if (link) { [NSThread sleepForTimeInterval: link.latency]; }
	}
#endif
}

/// One folder level: a single enumeration that also fetches each entry's
/// directory/symlink/size properties, so nothing is stat'ed per file.
+ (TSSTArchiveScanRecord *)folderRecordForURL:(NSURL *)folderURL name:(nullable NSString *)name context:(TSSTFolderScanContext *)context
{
	TSSTArchiveScanRecord *record = [TSSTArchiveScanRecord new];
	record.kind = TSSTArchiveScanRecordKindFolder;
	record.name = name;
	record.url = folderURL;
	NSMutableArray<TSSTArchiveScanRecord *> *children = [NSMutableArray array];

	NSError *error = nil;
	NSArray<NSURLResourceKey> *keys = @[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLFileSizeKey];
	NSArray<NSURL *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtURL: folderURL includingPropertiesForKeys: keys options: (NSDirectoryEnumerationSkipsSubdirectoryDescendants | NSDirectoryEnumerationSkipsHiddenFiles) error: &error];
	if (error)
	{
		NSLog(@"%@", [error localizedDescription]);
	}
	[self simulateDirectoryLatency];
	
	for (NSURL *url in contents)
	{
		NSString *lastComponent = url.lastPathComponent;
		NSString *fileExtension = url.pathExtension.lowercaseString;

		BOOL exists = YES, isDirectory = NO;
		unsigned long long size = 0;
		NSDictionary<NSURLResourceKey, id> *values = [url resourceValuesForKeys: keys error: NULL];
		if (!values || [values[NSURLIsSymbolicLinkKey] boolValue])
		{
			// Symlinks (and anything the properties couldn't describe) are
			// judged by where they point, like fileExistsAtPath: always did.
			struct stat st;
			exists = stat(url.fileSystemRepresentation, &st) == 0;
			isDirectory = exists && S_ISDIR(st.st_mode);
			size = exists ? (unsigned long long)st.st_size : 0;
		}
		else
		{
			isDirectory = [values[NSURLIsDirectoryKey] boolValue];
			size = [values[NSURLFileSizeKey] unsignedLongLongValue];
		}
		if (!exists || lastComponent.length == 0 || [lastComponent hasPrefix: @"."]) { continue; }

		NSString *childName = url.relativePath ?: url.path;
		TSSTArchiveScanRecord *child = nil;
		if (isDirectory)
		{
			child = [self folderRecordForURL: url name: childName context: context];
		}
		else if ([[TSSTManagedArchive archiveExtensions] containsObject: fileExtension])
		{
			child = [TSSTManagedArchive scanRecordForFileURL: url name: childName password: nil];
			child.kind = TSSTArchiveScanRecordKindArchive;
			child.path = url.path;
			child.url = url;
			child.isUserFile = YES;
		}
		else if ([fileExtension isEqualToString: @"pdf"])
		{
			child = [TSSTArchiveScanRecord new];
			child.kind = TSSTArchiveScanRecordKindPDF;
			child.name = childName;
			child.path = url.path;
			child.url = url;
			child.isUserFile = YES;
			PDFDocument *pdfDoc = [[PDFDocument alloc] initWithURL: url];
			child.builtInstance = pdfDoc;
			child.pdfPageCount = pdfDoc.pageCount;
		}
		else
		{
			BOOL isImage = [[TSSTPage imageExtensions] containsObject: fileExtension];
			if (isImage || [[TSSTPage textExtensions] containsObject: fileExtension])
			{
				child = TSSTImageChildRecord(url.path, -1, !isImage);
				if (context.streaming)
				{
					child.index = (NSInteger)context.files.count;
					[context.files addObject: url];
					[context.sizes addObject: @(size)];
					[context.fileRecords addObject: child];
				}
			}
		}
		if (child) { [children addObject: child]; }
	}
	record.children = children;
	return record;
}

+ (nullable TSSTArchiveScanRecord *)scanRecordForFolderURL:(NSURL *)folderURL name:(nullable NSString *)name streaming:(BOOL)streaming
{
	TSSTFolderScanContext *context = [TSSTFolderScanContext new];
	context.streaming = streaming;
	TSSTArchiveScanRecord *record = [self folderRecordForURL: folderURL name: name ?: folderURL.lastPathComponent context: context];

	if (streaming && context.files.count > 0)
	{
		// One virtual byte space for the whole tree, through the same
		// [simulated link ->] caching stack the archives use.
		TSSTFileSetByteSource *fileSet = [[TSSTFileSetByteSource alloc] initWithFileURLs: context.files sizes: context.sizes];
		TSSTCachingByteSource *cachingSource = nil;
		[self byteSourceStackOverFile: fileSet fileURL: folderURL requireCache: YES cachingSource: &cachingSource];
		record.builtFileSet = fileSet;
		record.builtCachingSource = cachingSource;

		NSArray<TSSTArchiveScanRecord *> *sorted = [context.fileRecords sortedArrayUsingComparator: ^NSComparisonResult(TSSTArchiveScanRecord *a, TSSTArchiveScanRecord *b) {
			return TSSTReadingOrderCompare(a.imagePath, b.imagePath);
		}];
		NSMutableArray<NSNumber *> *order = [NSMutableArray arrayWithCapacity: sorted.count];
		for (TSSTArchiveScanRecord *fileRecord in sorted) { [order addObject: @(fileRecord.index)]; }
		record.folderReadingOrder = order;
	}
	return record;
}

- (void)applyFolderScanRecord:(TSSTArchiveScanRecord *)record
{
	if (!record) { return; }
	if (record.builtFileSet && record.builtCachingSource)
	{
		_fileSet = record.builtFileSet;
		[self adoptCachingSource: record.builtCachingSource];
		NSDictionary<NSNumber *, NSNumber *> *map = nil;
		NSArray<NSValue *> *spans = [_fileSet spansForFileIndices: record.folderReadingOrder ?: @[] spanIndexMap: &map];
		[self startStreamerWithSpans: spans entryIndexMap: map];
	}
	[self insertChildRecords: record.children];
}

/// Main-thread only: inserts the Core Data entities for newChildren (a
/// subset of some record's children, or the whole list for a single-batch
/// scan) and returns the newly created image pages.
- (NSSet<TSSTPage *> *)insertChildRecords:(NSArray<TSSTArchiveScanRecord *> *)newChildren
{
	_restoredPathByIndex = nil;
	NSMutableSet<TSSTPage *> *newImages = [NSMutableSet set];
	for (TSSTArchiveScanRecord *child in newChildren)
	{
		__kindof TSSTManagedGroup *nestedDescription = nil;
		switch (child.kind)
		{
			case TSSTArchiveScanRecordKindImage:
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"Image" inManagedObjectContext: [self managedObjectContext]];
				[nestedDescription setValue: child.imagePath forKey: @"imagePath"];
				if (child.index >= 0)
				{
					[nestedDescription setValue: @(child.index) forKey: @"index"];
				}
				if (child.text)
				{
					[nestedDescription setValue: @YES forKey: @"text"];
				}
				[newImages addObject: (TSSTPage *)nestedDescription];
				break;
			case TSSTArchiveScanRecordKindArchive:
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"Archive" inManagedObjectContext: [self managedObjectContext]];
				nestedDescription.name = child.name;
				nestedDescription.nested = !child.isUserFile;
				if (child.url) { nestedDescription.fileURL = child.url; } else { nestedDescription.path = child.path; }
				[nestedDescription applyScanRecord: child];
				break;
			case TSSTArchiveScanRecordKindPDF:
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"PDF" inManagedObjectContext: [self managedObjectContext]];
				if (child.url) { nestedDescription.fileURL = child.url; } else { nestedDescription.path = child.path; }
				nestedDescription.nested = !child.isUserFile;
				nestedDescription.name = child.name;
				[nestedDescription applyPDFScanRecord: child];
				break;
			case TSSTArchiveScanRecordKindFolder:
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"ImageGroup" inManagedObjectContext: [self managedObjectContext]];
				nestedDescription.fileURL = child.url;
				nestedDescription.name = child.name;
				[nestedDescription insertChildRecords: child.children];
				break;
		}

		if (nestedDescription)
		{
			nestedDescription.group = self;
		}
	}
	return newImages;
}

#pragma mark - Streaming (shared by archives and folders)

/// YES when the given file is worth caching/streaming: a non-local
/// volume (e.g. SMB), or DEBUG SC_SIMULATE_LINK is set (so the app can be
/// exercised against the caching path using a local file).
+ (BOOL)shouldUseCacheForFileURL:(NSURL *)fileURL
{
#if DEBUG
	if (TSSTSimulatedLinkProfileName())
	{
		return YES;
	}
#endif
	NSNumber *isLocal = nil;
	NSError *error = nil;
	if ([fileURL getResourceValue: &isLocal forKey: NSURLVolumeIsLocalKey error: &error] && isLocal)
	{
		return !isLocal.boolValue;
	}
	return NO;
}

/// The byte-source stack every backend (zip index, XAD source, folder file
/// set) reads through: file -> [simulated slow link, DEBUG
/// SC_SIMULATE_LINK=<profile>, so slow-volume behaviour can be checked
/// against a local file] -> [caching source]. The caching source is added
/// when the file is on a slow volume (see +shouldUseCacheForFileURL:) or
/// \c requireCache is YES (a folder scan already decided to stream); it is
/// returned through \c cachingSourceOut (nil when reads go straight through)
/// so the caller can keep it for the streamer.
+ (id<TSSTArchiveByteSource>)byteSourceStackOverFile:(id<TSSTArchiveByteSource>)source fileURL:(NSURL *)fileURL requireCache:(BOOL)requireCache cachingSource:(TSSTCachingByteSource * _Nullable * _Nullable)cachingSourceOut
{
	if (cachingSourceOut) { *cachingSourceOut = nil; }
#if DEBUG
	NSString *simulatedLinkName = TSSTSimulatedLinkProfileName();
	TSSTSimulatedLinkByteSource *linkSource = simulatedLinkName ? [TSSTSimulatedLinkByteSource linkWithProfileName: simulatedLinkName wrapping: source] : nil;
	if (linkSource)
	{
		linkSource.simulateTime = YES;
		source = linkSource;
	}
#endif
	if (requireCache || [self shouldUseCacheForFileURL: fileURL])
	{
		TSSTCachingByteSource *cachingSource = [[TSSTCachingByteSource alloc] initWithUpstream: source];
		if (cachingSourceOut) { *cachingSourceOut = cachingSource; }
		source = cachingSource;
	}
	return source;
}

/// Makes \c cachingSource this group's cache, shutting down (streamer and
/// temp directory) any different one it replaces.
- (void)adoptCachingSource:(nullable TSSTCachingByteSource *)cachingSource
{
	if (_cachingSource && _cachingSource != cachingSource)
	{
		[_streamer cancel];
		[_cachingSource invalidate];
	}
	_cachingSource = cachingSource;
}

/// The group that owns the streaming cache serving this group's pages:
/// itself, or (for a subfolder) the folder above it. nil when nothing here
/// streams (local volume, PDF, archive without a cache).
- (nullable TSSTManagedGroup *)streamingOwner
{
	if (_cachingSource) { return self; }
	if ([self isLeafPageSource]) { return nil; }
	id parent = [self valueForKey: @"group"];
	return [parent isKindOfClass: [TSSTManagedGroup class]] ? [(TSSTManagedGroup *)parent streamingOwner] : nil;
}

/// The one place a streamer is built, for zip, XAD and folder backends.
/// \c map takes an entry index to its span index (see
/// -noteReadingEntryIndex:). Replaces any running streamer.
- (void)startStreamerWithSpans:(NSArray<NSValue *> *)spans entryIndexMap:(nullable NSDictionary<NSNumber *, NSNumber *> *)map
{
	[_streamer cancel];
	_entryIndexToSpanIndex = map;
	_streamer = [[TSSTArchiveStreamer alloc] initWithCachingByteSource: _cachingSource spans: spans];
	_streamer.avoidsRuntTailReads = (_fileSet != nil);
	// Lets the timeline bar redraw as spans land in the cache.
	__weak typeof(self) weakSelf = self;
	_streamer.progressHandler = ^(NSIndexSet *cachedSpanIndexes, double cachedFraction, double throughputBytesPerSecond, BOOL isComplete) {
		TSSTManagedGroup *strongSelf = weakSelf;
		if (strongSelf)
		{
			[[NSNotificationCenter defaultCenter] postNotificationName: TSSTArchiveCacheProgressNotification object: strongSelf];
		}
	};
	[_streamer start];
}

#if DEBUG
- (nullable TSSTArchiveStreamer *)streamer
{
	return _streamer;
}
#endif

/// Retargets the streamer at the page the reader is on. Called only from
/// the session's display path (-changeViewImages), never from the byte-read
/// path: hover thumbnails, pre-decoding and the exposé all read pages the
/// reader is not on, and each such read would drag the streamer's target
/// away from the reader's own neighbourhood.
- (void)noteReadingEntryIndex:(NSInteger)entryIndex
{
	TSSTManagedGroup *owner = [self streamingOwner];
	if (!owner) { return; }
	NSNumber *spanIndex = owner->_entryIndexToSpanIndex[@(entryIndex)];
	if (spanIndex) { owner->_streamer.currentSpanIndex = spanIndex.unsignedIntegerValue; }
}

- (void)prioritizeEntryIndex:(NSInteger)entryIndex
{
	TSSTManagedGroup *owner = [self streamingOwner];
	if (!owner) { return; }
	NSNumber *spanIndex = owner->_entryIndexToSpanIndex[@(entryIndex)];
	if (spanIndex) { [owner->_streamer prioritizeSpanIndex: spanIndex.unsignedIntegerValue]; }
}

- (nullable TSSTCachingByteSource *)cachingSourceForTesting
{
	TSSTManagedGroup *owner = [self streamingOwner];
	return owner ? owner->_cachingSource : nil;
}

- (BOOL)isStreamingArchive
{
	return [self streamingOwner] != nil;
}

- (BOOL)isEntryIndexCached:(NSInteger)entryIndex
{
	TSSTManagedGroup *owner = [self streamingOwner];
	if (!owner)
	{
		// No streaming cache -- local file, reads are already fast.
		return YES;
	}
	if (!owner->_streamer)
	{
		// Streaming archive whose streamer hasn't started yet (a RAR/7z
		// still being listed): nothing is known to be cached, so callers
		// must not read on the main thread -- doing so re-extracted the
		// displayed page synchronously on every progressive batch.
		return NO;
	}
	NSNumber *spanIndex = owner->_entryIndexToSpanIndex[@(entryIndex)];
	if (!spanIndex)
	{
		// Not a span we know about (out of range, or non-zip fallback):
		// treat conservatively as not-cached.
		return NO;
	}
	NSArray<NSValue *> *spans = owner->_streamer.spans;
	NSUInteger idx = spanIndex.unsignedIntegerValue;
	if (idx >= spans.count) { return NO; }
	NSRange span = spans[idx].rangeValue;
	return [owner->_cachingSource isRangeCachedAtOffset: span.location length: span.length];
}

- (NSIndexSet *)indexesOfCachedEntries:(NSArray<NSNumber *> *)entryIndexes
{
	TSSTManagedGroup *owner = [self streamingOwner];
	if (!owner)
	{
		return [NSIndexSet indexSetWithIndexesInRange: NSMakeRange(0, entryIndexes.count)];
	}
	if (!owner->_streamer) { return [NSIndexSet indexSet]; } // see -isEntryIndexCached:
	NSArray<NSValue *> *spans = owner->_streamer.spans;
	NSMutableArray<NSValue *> *ranges = [NSMutableArray arrayWithCapacity: entryIndexes.count];
	NSMutableArray<NSNumber *> *positions = [NSMutableArray arrayWithCapacity: entryIndexes.count]; // ranges[i] answers entryIndexes[positions[i]]
	[entryIndexes enumerateObjectsUsingBlock:^(NSNumber *entryIndex, NSUInteger position, BOOL *stop) {
		NSNumber *spanIndex = owner->_entryIndexToSpanIndex[entryIndex];
		if (spanIndex && spanIndex.unsignedIntegerValue < spans.count)
		{
			[ranges addObject: spans[spanIndex.unsignedIntegerValue]];
			[positions addObject: @(position)];
		}
	}];
	NSMutableIndexSet *cached = [NSMutableIndexSet indexSet];
	[[owner->_cachingSource indexesOfCachedRanges: ranges] enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
		[cached addIndex: positions[i].unsignedIntegerValue];
	}];
	return cached;
}

- (void)tearDownStreaming
{
	[_streamer cancel];
	[_cachingSource invalidate];
	_streamer = nil;
	_cachingSource = nil;
	_fileSet = nil;
	_entryIndexToSpanIndex = nil;
}

- (NSSet *)nestedImages
{
	NSMutableSet * allImages = [self.images mutableCopy];
	NSSet * groups = self.groups;
	for(TSSTManagedGroup * group in groups)
	{
		[allImages unionSet: group.nestedImages];
	}
	
	return allImages;
}

@end


/// The real thing: a modal open panel asking the user to pick the folder.
@interface TSSTOpenPanelFolderAccessProvider : NSObject <TSSTFolderAccessProvider>
@end

@implementation TSSTOpenPanelFolderAccessProvider
- (nullable NSURL *)folderAccessGrantForFolderURL:(NSURL *)folderURL message:(NSString *)message
{
#if DEBUG
	// Never put a modal panel in front of a test run: decline instead.
	if (NSClassFromString(@"XCTestCase") != Nil) { return nil; }
#endif
	NSOpenPanel *panel = [NSOpenPanel openPanel];
	panel.canChooseDirectories = YES;
	panel.canChooseFiles = NO;
	panel.allowsMultipleSelection = NO;
	panel.directoryURL = folderURL;
	panel.prompt = NSLocalizedString(@"Grant Access", @"folder access panel button");
	panel.message = message;
	return [panel runModal] == NSModalResponseOK ? panel.URL : nil;
}
@end

@interface TSSTManagedArchive ()
+ (void)runOnMainThreadSynchronously:(void (^)(void))block;
+ (nullable NSArray<id<TSSTArchiveByteSource>> *)openVolumeSourcesForURLs:(NSArray<NSURL *> *)volumeURLs accessingFolder:(nullable NSURL *)folder failedURL:(NSURL * _Nullable * _Nonnull)failedURL error:(NSError **)error;
@end

@implementation TSSTManagedArchive

- (BOOL)isLeafPageSource
{
	return YES;
}

+ (NSArray *)archiveExtensions
{
	static NSArray * extensions = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSArray *archives = self.archiveTypes;
		NSMutableSet<NSString*> *aimageTypes = [[NSMutableSet alloc] initWithCapacity:archives.count];
		for (NSString *uti in archives) {
			UTType *uti2 = [UTType typeWithIdentifier:uti];
			NSArray *fileExts = uti2.tags[UTTagClassFilenameExtension];
			[aimageTypes addObjectsFromArray:fileExts];
		}
		extensions = [[aimageTypes allObjects] sortedArrayUsingSelector:@selector(compare:)];
	});
	
	return extensions;
}

+ (NSArray*)archiveTypes
{
	static NSArray * extensions = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		// TODO: have this expansive?
		extensions = @[@"com.rarlab.rar-archive", @"cx.c3.cbr-archive",
					   (NSString*)kUTTypeZipArchive, @"cx.c3.cbz-archive",
					   @"org.7-zip.7-zip-archive",
					   @"public.archive.lha", @"cx.c3.lha-archive",
					   @"com.dancingtortoise.simplecomic.cbt", @"public.tar-archive",
					   @"com.yacreader.yacreader.cbr", @"com.yacreader.yacreader.cbz",
					   @"com.simplecomic.cbz-archive", @"com.simplecomic.cbr-archive",
					   @"com.simplecomic.cb7-archive", @"com.simplecomic.cbt-archive"];
	});
	
	return extensions;
}

+ (NSArray *)quicklookExtensions
{
	static NSArray * extensions = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		extensions = @[@"cbr", @"cbz", @"cbt", @"cb7"];
	});
	
	return extensions;
}

- (void)awakeFromInsert
{
	[super awakeFromInsert];
	_zipIndexLock = [NSCondition new];
	_xadSourceLock = [NSCondition new];
}

- (void)awakeFromFetch
{
	[super awakeFromFetch];
	_zipIndexLock = [NSCondition new];
	_xadSourceLock = [NSCondition new];
}

- (void)willTurnIntoFault
{
	NSError * error;
	if(self.nested)
	{
		if(![[NSFileManager defaultManager] removeItemAtPath: self.path error: &error])
		{
			NSLog(@"%@",[error localizedDescription]);
		}
	}
	
	NSString * solid  = self.solidDirectory;
	if(solid)
	{
		if(![[NSFileManager defaultManager] removeItemAtPath: solid error: &error])
		{
			NSLog(@"%@",[error localizedDescription]);
		}
	}
}

/// Prompts for (or reuses) an archive's password the same way for every
/// backend: XADArchive's delegate (-archiveNeedsPassword:), the
/// background-scan delegate (TSSTScanArchiveDelegate), and
/// TSSTXADArchiveSource's password provider block. Always prompts on the
/// main thread, synchronously if called from elsewhere.
+ (nullable NSString *)promptForPasswordAtPath:(NSString *)path knownPassword:(nullable NSString *)known
{
	if (known) { return known; }
	__block NSString *prompted = nil;
	[self runOnMainThreadSynchronously: ^{
		prompted = [(SimpleComicAppDelegate*)[NSApp delegate] passwordForArchiveWithPath: path];
	}];
	return prompted;
}

/// Runs \c block on the main thread and waits: inline when already there,
/// dispatch_sync otherwise. Callers must hold no lock the main thread may
/// wait for while the block runs (the shared deadlock rule for every prompt).
+ (void)runOnMainThreadSynchronously:(void (^)(void))block
{
	if ([NSThread isMainThread]) { block(); }
	else { dispatch_sync(dispatch_get_main_queue(), block); }
}

#pragma mark - Folder access (sandbox)

static NSString * const TSSTFolderAccessBookmarksKey = @"TSSTFolderAccessBookmarks";
static id<TSSTFolderAccessProvider> sFolderAccessProvider = nil;
static NSUserDefaults *sFolderBookmarkDefaults = nil;
static NSMutableDictionary<NSString *, NSURL *> *sGrantedFolders = nil;   // this session's grants
static NSMutableSet<NSString *> *sDeclinedFolders = nil;                  // this session's cancels
static NSObject *sFolderAccessLock = nil;

+ (void)initialize
{
	if (self == [TSSTManagedArchive class])
	{
		sFolderAccessLock = [NSObject new];
		sGrantedFolders = [NSMutableDictionary dictionary];
		sDeclinedFolders = [NSMutableSet set];
	}
}

+ (nullable id<TSSTFolderAccessProvider>)folderAccessProvider { @synchronized (sFolderAccessLock) { return sFolderAccessProvider; } }
+ (void)setFolderAccessProvider:(nullable id<TSSTFolderAccessProvider>)provider { @synchronized (sFolderAccessLock) { sFolderAccessProvider = provider; } }
+ (void)setFolderBookmarkDefaults:(nullable NSUserDefaults *)defaults { @synchronized (sFolderAccessLock) { sFolderBookmarkDefaults = defaults; } }
+ (void)resetFolderAccessSessionState
{
	@synchronized (sFolderAccessLock) { [sGrantedFolders removeAllObjects]; [sDeclinedFolders removeAllObjects]; }
}

+ (NSUserDefaults *)folderBookmarkDefaults { @synchronized (sFolderAccessLock) { return sFolderBookmarkDefaults ?: [NSUserDefaults standardUserDefaults]; } }

+ (BOOL)storeAccessBookmarkForFolderURL:(NSURL *)folderURL
{
	NSData *bookmark = [folderURL bookmarkDataWithOptions: NSURLBookmarkCreationWithSecurityScope includingResourceValuesForKeys: nil relativeToURL: nil error: NULL];
	if (!bookmark) { return NO; }
	NSUserDefaults *defaults = [self folderBookmarkDefaults];
	NSMutableDictionary *all = [([defaults dictionaryForKey: TSSTFolderAccessBookmarksKey] ?: @{}) mutableCopy];
	all[folderURL.URLByStandardizingPath.path] = bookmark;
	[defaults setObject: all forKey: TSSTFolderAccessBookmarksKey];
	return YES;
}

+ (nullable NSURL *)resolvedAccessBookmarkForFolderURL:(NSURL *)folderURL
{
	NSString *key = folderURL.URLByStandardizingPath.path;
	NSData *bookmark = [[self folderBookmarkDefaults] dictionaryForKey: TSSTFolderAccessBookmarksKey][key];
	if (![bookmark isKindOfClass: [NSData class]]) { return nil; }
	BOOL stale = NO;
	NSURL *resolved = [NSURL URLByResolvingBookmarkData: bookmark options: NSURLBookmarkResolutionWithSecurityScope relativeToURL: nil bookmarkDataIsStale: &stale error: NULL];
	if (resolved && stale)
	{
		BOOL started = [resolved startAccessingSecurityScopedResource];
		[self storeAccessBookmarkForFolderURL: resolved];
		if (started) { [resolved stopAccessingSecurityScopedResource]; }
	}
	return resolved;
}

/// A sibling the sandbox refuses: the file is there but open() fails with a
/// permission error (as opposed to being genuinely absent).
static BOOL TSSTFileIsPermissionBlocked(NSURL *url)
{
	if (![[NSFileManager defaultManager] fileExistsAtPath: url.path]) { return NO; }
	int fd = open(url.path.fileSystemRepresentation, O_RDONLY);
	if (fd >= 0) { close(fd); return NO; }
	return errno == EPERM || errno == EACCES;
}

/// Asks (once per folder per session) for access to \c folderURL through the
/// provider, always on the main thread and holding no lock while it runs.
/// Returns the granted URL, or nil when declined (remembered until relaunch).
+ (nullable NSURL *)requestAccessToFolderURL:(NSURL *)folderURL archiveName:(NSString *)archiveName
{
	NSString *key = folderURL.URLByStandardizingPath.path;
	__block NSURL *granted = nil;
	[self runOnMainThreadSynchronously: ^{
		@synchronized (sFolderAccessLock)
		{
			// Concurrent opens queue up on the main thread: later ones reuse the first answer.
			if ([sDeclinedFolders containsObject: key]) { return; }
			granted = sGrantedFolders[key];
		}
		if (granted) { return; }
		NSString *message = [NSString stringWithFormat: NSLocalizedString(@"Simple Comic needs access to this folder to read the other volumes of the multi-part archive “%@”.", @"folder access panel message"), archiveName];
		id<TSSTFolderAccessProvider> provider = [self folderAccessProvider] ?: [TSSTOpenPanelFolderAccessProvider new];
		granted = [provider folderAccessGrantForFolderURL: folderURL message: message];
		@synchronized (sFolderAccessLock)
		{
			if (granted) { sGrantedFolders[key] = granted; } else { [sDeclinedFolders addObject: key]; }
		}
		if (granted)
		{
			BOOL started = [granted startAccessingSecurityScopedResource];
			[self storeAccessBookmarkForFolderURL: granted];
			if (started) { [granted stopAccessingSecurityScopedResource]; }
		}
	}];
	return granted;
}

/// Opens every volume, with \c folder (when given) accessed for the duration
/// (the open file descriptors outlive the scope). On failure sets
/// \c failedURL to the first volume that could not be opened.
+ (nullable NSArray<id<TSSTArchiveByteSource>> *)openVolumeSourcesForURLs:(NSArray<NSURL *> *)volumeURLs accessingFolder:(nullable NSURL *)folder failedURL:(NSURL * _Nullable * _Nonnull)failedURL error:(NSError **)error
{
	BOOL started = [folder startAccessingSecurityScopedResource];
	NSMutableArray<id<TSSTArchiveByteSource>> *sources = [NSMutableArray arrayWithCapacity: volumeURLs.count];
	NSArray<id<TSSTArchiveByteSource>> *result = sources;
	for (NSURL *url in volumeURLs)
	{
		NSError *openError = nil;
		id<TSSTArchiveByteSource> volumeSource = [TSSTFileByteSource sourceWithFileURL: url error: &openError];
		if (!volumeSource)
		{
			*failedURL = url;
			if (error)
			{
				NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject: [NSString stringWithFormat: NSLocalizedString(@"A volume of this multi-volume archive could not be opened: “%@”. Keep all of its parts together in one folder.", @"missing RAR volume"), url.lastPathComponent] forKey: NSLocalizedDescriptionKey];
				info[NSFilePathErrorKey] = url.path;
				if (openError) { info[NSUnderlyingErrorKey] = openError; }
				*error = [NSError errorWithDomain: TSSTXADArchiveSourceErrorDomain code: TSSTXADArchiveSourceErrorMissingVolume userInfo: info];
			}
			result = nil;
			break;
		}
		[sources addObject: volumeSource];
	}
	if (started) { [folder stopAccessingSecurityScopedResource]; }
	return result;
}

/// Opens every volume of a multi-volume set. A sandboxed app is granted
/// only the file the user picked, so a sibling may fail to open until its
/// folder is accessed. In order: the folder as-is (harmless when the URL
/// isn't security-scoped), a stored bookmark grant, and -- when a volume
/// exists but is permission-blocked -- one request to the folder access
/// provider (an open panel by default; remembered per folder). Returns nil
/// with a TSSTXADArchiveSourceErrorMissingVolume error naming the first
/// volume that still can't be opened.
+ (nullable NSArray<id<TSSTArchiveByteSource>> *)openVolumeSourcesForURLs:(NSArray<NSURL *> *)volumeURLs error:(NSError **)error
{
	NSURL *folder = [volumeURLs.firstObject URLByDeletingLastPathComponent];
	NSURL *failedURL = nil;
	NSArray<id<TSSTArchiveByteSource>> *result = [self openVolumeSourcesForURLs: volumeURLs accessingFolder: folder failedURL: &failedURL error: error];
	if (result || !failedURL || !TSSTFileIsPermissionBlocked(failedURL)) { return result; }

	NSURL *bookmarked = [self resolvedAccessBookmarkForFolderURL: folder];
	if (bookmarked)
	{
		result = [self openVolumeSourcesForURLs: volumeURLs accessingFolder: bookmarked failedURL: &failedURL error: error];
		if (result || !failedURL || !TSSTFileIsPermissionBlocked(failedURL)) { return result; }
	}

	NSURL *granted = [self requestAccessToFolderURL: folder archiveName: volumeURLs.firstObject.lastPathComponent];
	if (granted)
	{
		result = [self openVolumeSourcesForURLs: volumeURLs accessingFolder: granted failedURL: &failedURL error: error];
	}
	return result;
}

/// Builds the zip index over the shared byte-source stack, or returns nil
/// to make callers use XADArchive (non-zips, unreadable files, unsupported
/// zip features). Shared by the lazy -zipIndex accessor and the background
/// scan. DEBUG builds: SC_FORCE_XAD skips the index.
+ (nullable TSSTZipIndex *)buildZipIndexForFileURL:(NSURL *)fileURL cachingSource:(TSSTCachingByteSource * _Nullable * _Nullable)cachingSourceOut
{
	if (cachingSourceOut) { *cachingSourceOut = nil; }
#if DEBUG
	if (getenv("SC_FORCE_XAD") != NULL) { return nil; }
#endif
	if (![fileURL checkResourceIsReachableAndReturnError: NULL]) { return nil; }

	// Non-zips (RAR, 7z, ...) must not cost a wrapped source, a cache and a
	// tail read over the network just to fail: look at the first bytes of
	// the raw file first (a "PK" local header / end record / spanning marker).
	id<TSSTArchiveByteSource> rawFile = [TSSTFileByteSource sourceWithFileURL: fileURL error: NULL];
	NSData *magic = [rawFile readAtOffset: 0 length: 2 error: NULL];
	if (magic.length < 2 || memcmp(magic.bytes, "PK", 2) != 0) { return nil; }

	id<TSSTArchiveByteSource> source = [self byteSourceStackOverFile: rawFile fileURL: fileURL requireCache: NO cachingSource: cachingSourceOut];
	TSSTZipIndex *index = [TSSTZipIndex indexWithByteSource: source error: NULL];
	if (!index && cachingSourceOut && *cachingSourceOut)
	{
		// Not a zip we can read: a half-built cache is invalidated, never leaked.
		[*cachingSourceOut invalidate];
		*cachingSourceOut = nil;
	}
	return index;
}

/// Builds a streaming TSSTXADArchiveSource over the same byte-source stack.
/// Returns nil (with TSSTXADArchiveSourceErrorMissingVolume) when a volume
/// of a multi-volume set can't be opened, so callers can fall back to the
/// XADArchive path and tell the user what is missing.
+ (nullable TSSTXADArchiveSource *)buildXADSourceForFileURL:(NSURL *)fileURL
														 name:(NSString *)name
													 password:(nullable NSString *)password
											 passwordProvider:(TSSTXADArchiveSourcePasswordProvider)passwordProvider
												cachingSource:(TSSTCachingByteSource * _Nullable * _Nullable)cachingSourceOut
														error:(NSError **)error
{
	if (cachingSourceOut) { *cachingSourceOut = nil; }
	// A multi-volume RAR set reads as one concatenated byte space, so the
	// link simulation, cache and streamer treat it like a single file.
	NSArray<NSURL *> *volumeURLs = [TSSTXADArchiveSource volumeURLsForFileURL: fileURL];
	NSArray<id<TSSTArchiveByteSource>> *fileSources;
	if (volumeURLs)
	{
		fileSources = [self openVolumeSourcesForURLs: volumeURLs error: error];
	}
	else
	{
		id<TSSTArchiveByteSource> single = [TSSTFileByteSource sourceWithFileURL: fileURL error: error];
		fileSources = single ? @[single] : nil;
	}
	if (!fileSources) { return nil; }
	TSSTVolumeSetByteSource *volumeSet = volumeURLs ? [[TSSTVolumeSetByteSource alloc] initWithVolumeSources: fileSources] : nil;
	id<TSSTArchiveByteSource> fileSource = volumeSet ?: fileSources.firstObject;

	id<TSSTArchiveByteSource> source = [self byteSourceStackOverFile: fileSource fileURL: fileURL requireCache: NO cachingSource: cachingSourceOut];
	TSSTXADArchiveSource *xadSource = [[TSSTXADArchiveSource alloc] initWithByteSource: source volumeLengths: volumeSet.volumeLengths name: name path: fileURL.path password: password passwordProvider: passwordProvider error: error];
	if (!xadSource && cachingSourceOut && *cachingSourceOut)
	{
		[*cachingSourceOut invalidate];
		*cachingSourceOut = nil;
	}
	return xadSource;
}

- (id)instance
{
	if (!instance)
	{
		NSURL *aFileURL = self.fileURL;
		if([aFileURL checkResourceIsReachableAndReturnError:NULL])
		{
			[aFileURL startAccessingSecurityScopedResource];
			instance = [[XADArchive alloc] initWithFileURL: aFileURL delegate: self error:NULL];
			
			// Set the archive delegate so that password and encoding queries can have a modal pop up.
			
			if(self.password)
			{
				[instance setPassword: self.password];
			}
		}
	}
	
	return instance;
}

/// The zip index a scan should read through (with the cache it reads
/// through, if any): nil when the file isn't a zip, SC_FORCE_XAD is set, or
/// the index can't extract every entry the scan needs. The caller then lists
/// through XADArchive, and any cache built for the discarded index is
/// invalidated here.
+ (nullable TSSTZipIndex *)scannableZipIndexForFileURL:(NSURL *)fileURL cachingSource:(TSSTCachingByteSource * _Nullable * _Nonnull)cachingSourceOut
{
	TSSTZipIndex *zi = [self buildZipIndexForFileURL: fileURL cachingSource: cachingSourceOut];
	if (!TSSTZipIndexCanScan(zi))
	{
		[*cachingSourceOut invalidate];
		*cachingSourceOut = nil;
		return nil;
	}
	return zi;
}

/// Build-once gate for the lazy accessors. Returns `YES` to exactly one
/// caller (the builder), which must build with `NO` lock held and then call
/// `TSSTFinishBuild`. Every other caller waits until the build is done and
/// gets `NO`. A main-thread waiter keeps servicing the main run loop, because
/// the builder may be blocked in `dispatch_sync(main)` for a password prompt.
static BOOL TSSTBeginBuild(NSCondition *lock, BOOL *attempted, BOOL *building)
{
	[lock lock];
	TSSTWaitOnConditionWhile(lock, ^BOOL{ return *building; });
	BOOL shouldBuild = !*attempted;
	if (shouldBuild) { *attempted = YES; *building = YES; }
	[lock unlock];
	return shouldBuild;
}

/// Publishes a build's result (under the lock) and wakes the waiters.
static void TSSTFinishBuild(NSCondition *lock, BOOL *building, void (^publish)(void))
{
	[lock lock];
	publish();
	*building = NO;
	[lock broadcast];
	[lock unlock];
}

/// Lazily builds (or rebuilds, e.g. after the managed object was re-fetched
/// and the ivar reset) the fast zip index for this archive's fileURL. Returns
/// nil for non-zips, unreadable files, or zip features this class can't
/// fully handle -- callers should fall back to -instance / XADArchive.
/// Thread-safe: background page reads may call this off-main while the
/// window's main thread also reads pages. The build runs outside the lock
/// (see TSSTBeginBuild).
- (nullable TSSTZipIndex *)zipIndex
{
	if (TSSTBeginBuild(_zipIndexLock, &_zipIndexAttempted, &_zipIndexBuilding))
	{
		TSSTCachingByteSource *cachingSource = nil;
		TSSTZipIndex *built = [TSSTManagedArchive buildZipIndexForFileURL: self.fileURL cachingSource: &cachingSource];
		TSSTFinishBuild(_zipIndexLock, &_zipIndexBuilding, ^{
			if (built && !self->_zipIndex)
			{
				self->_zipIndex = built;
				[self adoptCachingSource: cachingSource];
			}
			else
			{
				[cachingSource invalidate];
			}
		});
	}
	[_zipIndexLock lock];
	TSSTZipIndex *result = _zipIndex;
	[_zipIndexLock unlock];
	return result;
}

/// A password-provider block bound to this managed object: reuses the
/// password already known (\c initialPassword, captured by the caller on
/// the right thread, or an earlier answer), otherwise prompts (main thread)
/// and remembers the answer on self.password -- exactly like
/// -archiveNeedsPassword:, but usable off the XADArchiveDelegate protocol
/// since TSSTXADArchiveSource's provider is a plain block. Never reads a
/// managed-object attribute, so it is safe to call from the scan queue.
- (TSSTXADArchiveSourcePasswordProvider)xadPasswordProviderWithInitialPassword:(nullable NSString *)initialPassword
{
	__weak typeof(self) weakSelf = self;
	NSObject *rememberedLock = [NSObject new];
	__block NSString *remembered = initialPassword;
	return ^NSString *(NSString *path, NSString *known) {
		NSString *existing = known;
		@synchronized (rememberedLock) { existing = existing ?: remembered; }
		NSString *result = [TSSTManagedArchive promptForPasswordAtPath: path knownPassword: existing];
		@synchronized (rememberedLock) { remembered = result; }
		typeof(self) strongSelf = weakSelf;
		if (strongSelf && [NSThread isMainThread])
		{
			strongSelf.password = result;
		}
		else if (strongSelf)
		{
			dispatch_async(dispatch_get_main_queue(), ^{ strongSelf.password = result; });
		}
		return result;
	};
}

/// Lazily builds (or rebuilds, e.g. after the managed object was
/// re-fetched and the ivar reset) the streaming XAD source for this
/// archive's fileURL. Used both by the requestDataForPageIndex: fallback
/// (session restore, where nothing progressive built it yet) and
/// -nameOfEntryAtIndex:. Doesn't itself trigger a parse -- see
/// -ensureXADSourceParseStarted.
- (nullable TSSTXADArchiveSource *)xadSource
{
	if (TSSTBeginBuild(_xadSourceLock, &_xadSourceAttempted, &_xadSourceBuilding))
	{
		TSSTXADArchiveSource *built = nil;
		TSSTCachingByteSource *cachingSource = nil;
		NSURL *aFileURL = self.fileURL;
		if ([aFileURL checkResourceIsReachableAndReturnError: NULL])
		{
			NSString *password = self.password;
			built = [TSSTManagedArchive buildXADSourceForFileURL: aFileURL
															name: self.name ?: aFileURL.lastPathComponent
														password: password
												passwordProvider: [self xadPasswordProviderWithInitialPassword: password]
												   cachingSource: &cachingSource
														   error: NULL];
		}
		TSSTFinishBuild(_xadSourceLock, &_xadSourceBuilding, ^{
			if (built && !self->_xadSource)
			{
				self->_xadSource = built;
				[self adoptCachingSource: cachingSource];
			}
			else
			{
				[cachingSource invalidate];
			}
		});
	}
	[_xadSourceLock lock];
	TSSTXADArchiveSource *result = _xadSource;
	[_xadSourceLock unlock];
	return result;
}

/// Kicks off (once) a background parse of a lazily-rebuilt _xadSource --
/// used only on the session-restore path, where the progressive scan
/// never ran, so nothing would otherwise ever call -parseWithEntryBatchHandler:.
/// -dataForEntry:/-nameOfEntryAtIndex: block correctly regardless of
/// which thread this runs on.
- (void)ensureXADSourceParseStarted
{
	[_xadSourceLock lock];
	BOOL shouldStart = _xadSource && !_xadSourceParseStarted;
	if (shouldStart) { _xadSourceParseStarted = YES; }
	TSSTXADArchiveSource *source = _xadSource;
	[_xadSourceLock unlock];

	if (!shouldStart) { return; }

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		[source parseWithEntryBatchHandler: ^(NSArray<TSSTXADArchiveEntry *> *batch, BOOL isFinal, NSError *error) {
			// Nothing progressive is listening on this path (session
			// restore): the pages already exist from the previous
			// session's Core Data, and -dataForEntry: just needs the
			// parse to finish finding them.
		}];
	});
}

- (nullable NSString *)nameOfEntryAtIndex:(NSInteger)index
{
	TSSTZipIndex *zi = self.zipIndex;
	if (zi && index >= 0 && (NSUInteger)index < zi.numberOfEntries)
	{
		return [zi nameOfEntry: (NSUInteger)index];
	}
	// Only try the streaming XAD backend for archives that actually use
	// it (top-level RAR/7z, progressive or restored). Nested archives
	// always have `instance` (an XADArchive) set by
	// -applyScanRecordHeader: instead -- building a parser here for them
	// would silently abandon that already-built backend.
	if (!instance && index >= 0)
	{
		TSSTXADArchiveSource *xad = self.xadSource;
		if (xad)
		{
			[self ensureXADSourceParseStarted];
			return [xad nameForEntryAtIndex: (NSUInteger)index];
		}
	}
	return [(XADArchive *)self.instance nameOfEntry: index];
}

/// Starts a background prefetcher over \c zi's extractable entries, in
/// the same order pages are displayed in (TSSTSortDescriptor's
/// comparison on imagePath). Only called when a caching byte source was
/// built for this archive (see +buildZipIndexForFileURL:cachingSource:).
- (void)startStreamerForZipIndex:(TSSTZipIndex *)zi
{
	NSMutableArray<NSNumber *> *extractable = [NSMutableArray array];
	for (NSUInteger i = 0; i < zi.numberOfEntries; ++i)
	{
		if ([zi canExtractEntry: i]) { [extractable addObject: @(i)]; }
	}

	NSArray<NSNumber *> *sorted = [extractable sortedArrayUsingComparator: ^NSComparisonResult(NSNumber *a, NSNumber *b) {
		return TSSTReadingOrderCompare([zi nameOfEntry: a.unsignedIntegerValue], [zi nameOfEntry: b.unsignedIntegerValue]);
	}];

	NSDictionary<NSNumber *, NSNumber *> *map = nil;
	NSArray<NSValue *> *spans = [TSSTArchiveStreamer spansForZipIndex: zi entryIndices: sorted spanIndexMap: &map];
	[self startStreamerWithSpans: spans entryIndexMap: map];
}

/// XAD counterpart to -startStreamerForZipIndex: -- builds spans directly
/// from the already-known entry list (collected across every progressive
/// batch) instead of re-querying a listing, since TSSTXADArchiveSource
/// doesn't keep its own name-sorted view. Only called once the whole
/// parse has finished, so entries/spans are complete and stable. No-op when
/// this archive doesn't read through a caching byte source.
- (void)startXADStreamerWithAllEntries:(NSArray<TSSTXADArchiveEntry *> *)entries
{
	if (!_cachingSource || entries.count == 0) { return; }
	NSMutableArray<TSSTXADArchiveEntry *> *extractable = [NSMutableArray array];
	for (TSSTXADArchiveEntry *entry in entries)
	{
		if (!entry.isDirectory) { [extractable addObject: entry]; }
	}

	NSArray<TSSTXADArchiveEntry *> *sorted = [extractable sortedArrayUsingComparator: ^NSComparisonResult(TSSTXADArchiveEntry *a, TSSTXADArchiveEntry *b) {
		return TSSTReadingOrderCompare(a.name, b.name);
	}];

	BOOL anyHasSpan = NO;
	for (TSSTXADArchiveEntry *entry in sorted)
	{
		if (entry.hasSpanRange) { anyHasSpan = YES; break; }
	}

	NSArray<NSValue *> *spans;
	NSDictionary<NSNumber *, NSNumber *> *map = nil;

	if (!anyHasSpan)
	{
		// No entry has a computable byte range: a single whole-file span,
		// so the streamer fills the cache sequentially from the start
		// instead of one span per entry.
		NSUInteger fileLength = (NSUInteger)MIN((unsigned long long)NSUIntegerMax, _cachingSource.length);
		spans = @[[NSValue valueWithRange: NSMakeRange(0, fileLength)]];
		// _entryIndexToSpanIndex left empty: -isEntryIndexCached: already
		// treats an unmapped entry as conservatively not-cached.
	}
	else
	{
		// One span per distinct range: RAR/non-solid 7z entries get their
		// own, files of a solid 7z folder share the folder's.
		NSMutableDictionary<NSNumber *, TSSTXADArchiveEntry *> *byIndex = [NSMutableDictionary dictionaryWithCapacity: sorted.count];
		NSMutableArray<NSNumber *> *order = [NSMutableArray arrayWithCapacity: sorted.count];
		for (TSSTXADArchiveEntry *entry in sorted)
		{
			byIndex[@(entry.index)] = entry;
			[order addObject: @(entry.index)];
		}
		spans = [TSSTArchiveStreamer spansForEntryIndices: order rangeProvider: ^BOOL(NSUInteger idx, NSRange *outRange) {
			TSSTXADArchiveEntry *entry = byIndex[@(idx)];
			if (!entry.hasSpanRange) { return NO; }
			*outRange = entry.spanRange;
			return YES;
		} spanIndexMap: &map];
	}
	[self startStreamerWithSpans: spans entryIndexMap: map];
}

- (void)didTurnIntoFault
{
	[super didTurnIntoFault];
	_zipIndex = nil;
	_zipIndexAttempted = NO;
	_xadSource = nil;
	_xadSourceAttempted = NO;
	_xadSourceParseStarted = NO;
}


- (void)requestDataForPageIndex:(NSInteger)index completionHandler:(void(^)(NSData *_Nullable pageData, NSError *_Nullable error))callback
{
	NSString * solidDirectory = self.solidDirectory;
	NSData * imageData;
	// Zip archives are never solid, so if we have a fast zip index for this
	// archive we can read straight from it -- pread() is safe for
	// concurrent callers, so no groupLock is needed on this path.
	TSSTZipIndex *zi = solidDirectory ? nil : self.zipIndex;
	if (zi && index >= 0 && (NSUInteger)index < zi.numberOfEntries && [zi canExtractEntry: (NSUInteger)index])
	{
		NSError *err;
		imageData = [zi contentsOfEntry: (NSUInteger)index error: &err];
		callback(imageData, err);
		return;
	}
	// RAR/7z (or a zip forced onto this path via SC_FORCE_XAD): the
	// streaming XAD backend, when this archive has one -- built by the
	// progressive scan, or lazily rebuilt here after session restore.
	// -dataForEntry: is thread-safe and blocks appropriately whether the
	// parse is still running (progressive open) or already finished
	// (restore, or a later re-read). Gated on `instance == nil`: nested
	// archives always have `instance` (an XADArchive) set by
	// -applyScanRecordHeader: instead, and must keep using it rather
	// than silently getting a second, independent parser here.
	TSSTXADArchiveSource *xadSource = (solidDirectory || instance) ? nil : self.xadSource;
	if (xadSource && index >= 0)
	{
		[self ensureXADSourceParseStarted];
		NSError *err;
		imageData = [xadSource dataForEntry: (NSUInteger)index error: &err];
		callback(imageData, err);
		return;
	}
	if(!solidDirectory)
	{
		[groupLock lock];
		NSError *err;
		imageData = [[self instance] contentsOfEntry: index error: &err];
		[groupLock unlock];
		callback(imageData, err);
	}
	else
	{
		NSString * name = [[self instance] nameOfEntry: index];
		NSString * fileName = [NSString stringWithFormat:@"%li.%@", (long)index, [name pathExtension]];
		fileName = [solidDirectory stringByAppendingPathComponent: fileName];
		if(![[NSFileManager defaultManager] fileExistsAtPath: fileName])
		{
			[groupLock lock];
			NSError *err;
			imageData = [[self instance] contentsOfEntry: index error: &err];
			[groupLock unlock];
			[imageData writeToFile: fileName options: 0 error: nil];
			callback(imageData, err);
		}
		else
		{
			NSError *err = nil;
			imageData = [NSData dataWithContentsOfFile: fileName options:0 error:&err];
			callback(imageData, err);
			return;
		}
	}
}


- (NSManagedObject *)topLevelGroup
{
	NSManagedObject * group = self;
	NSManagedObject * parentGroup = group;
	
	while(group)
	{
		group = [group valueForKeyPath: @"group"];
		parentGroup = group && [group isMemberOfClass:[TSSTManagedArchive class]] ? group : parentGroup;
	}
	
	return parentGroup;
}

/// Background-safe: builds the backend and scans entries for the archive at
/// \c fileURL, returning a value-only record tree. Never touches an
/// \c NSManagedObject / the MOC, so it can run on any queue. Recurses into
/// nested archives/PDFs (writing their bytes to temp files) and returns
/// their own fully-built records as children.
+ (nullable TSSTArchiveScanRecord *)scanRecordForFileURL:(NSURL *)fileURL name:(nullable NSString *)name password:(nullable NSString *)password
{
	// Try the fast zip-index path first: it only needs one pread() of the
	// central directory instead of XADArchive walking every local header
	// (slow on high-latency volumes like SMB).
	TSSTCachingByteSource *cachingSource = nil;
	TSSTZipIndex *zi = [self scannableZipIndexForFileURL: fileURL cachingSource: &cachingSource];
	return [self scanRecordForFileURL: fileURL name: name password: password zipIndex: zi cachingSource: cachingSource];
}

/// The scan proper. \c zi (with its cache, if any) is an already-built index
/// that can extract everything the scan needs, or nil to list through
/// XADArchive (non-zips, solid archives, zips the index can't fully read).
+ (nullable TSSTArchiveScanRecord *)scanRecordForFileURL:(NSURL *)fileURL name:(nullable NSString *)name password:(nullable NSString *)password zipIndex:(nullable TSSTZipIndex *)zi cachingSource:(nullable TSSTCachingByteSource *)cachingSource
{
	TSSTArchiveScanRecord *record = [TSSTArchiveScanRecord new];
	record.name = name ?: fileURL.lastPathComponent;

	const BOOL zipIndexUsable = (zi != nil);
	XADArchive *imageArchive = nil;
	TSSTScanArchiveDelegate *passwordDelegate = nil;
	if (!zipIndexUsable)
	{
		passwordDelegate = [TSSTScanArchiveDelegate new];
		passwordDelegate.path = fileURL.path;
		passwordDelegate.password = password;
		[fileURL startAccessingSecurityScopedResource];
		imageArchive = [[XADArchive alloc] initWithFileURL: fileURL delegate: passwordDelegate error: NULL];
		if (imageArchive && passwordDelegate.password)
		{
			[imageArchive setPassword: passwordDelegate.password];
		}
	}

	record.builtInstance = zipIndexUsable ? zi : imageArchive;
	record.builtCachingSource = zipIndexUsable ? cachingSource : nil;
	record.password = passwordDelegate.password;
	record.backendDescription = zipIndexUsable ? @"zip-index" : @"XAD";

	const NSInteger archivedFilesCount = zipIndexUsable ? (NSInteger)zi.numberOfEntries : [imageArchive numberOfEntries];
	if (!zipIndexUsable && [imageArchive isSolid])
	{
		NSString *solidPath = TSSTCreateUnusedTempPath(YES, ^NSString *(NSInteger n) {
			return [NSString stringWithFormat: @"SC-images-%li", (long)n];
		});
		record.solidDirectory = solidPath;
	}

	NSMutableArray<TSSTArchiveScanRecord *> *children = [NSMutableArray arrayWithCapacity: archivedFilesCount];

	for (NSInteger counter = 0; counter < archivedFilesCount; ++counter)
	{
		NSString *fileName = zipIndexUsable ? [zi nameOfEntry: (NSUInteger)counter] : [imageArchive nameOfEntry: counter];
		TSSTArchiveScanRecord *child = nil;

		switch (TSSTClassifyScanEntryName(fileName))
		{
			case TSSTScanEntryClassImage:
				child = TSSTImageChildRecord(fileName, counter, NO);
				break;
			case TSSTScanEntryClassText:
				child = TSSTImageChildRecord(fileName, counter, YES);
				break;
			case TSSTScanEntryClassArchive:
			{
				NSData *fileData = zipIndexUsable ? [zi contentsOfEntry: (NSUInteger)counter error: NULL] : [imageArchive contentsOfEntry: counter];
				child = TSSTNestedArchiveChildRecord(fileData, fileName);
				break;
			}
			case TSSTScanEntryClassPDF:
			{
				NSData *fileData = zipIndexUsable ? [zi contentsOfEntry: (NSUInteger)counter error: NULL] : [imageArchive contentsOfEntry: counter];
				child = TSSTPDFChildRecord(fileData, fileName);
				break;
			}
			case TSSTScanEntryClassIgnored:
				break;
		}
		if (child) { [children addObject: child]; }
	}

	record.children = children;
	return record;
}

/// Removes the temp items \c record created. Its own \c path is a temp copy
/// unless the record came from a folder scan, where it is the user's file.
static void TSSTDiscardScanRecord(TSSTArchiveScanRecord *record, BOOL pathIsTemp)
{
	NSFileManager *fileManager = [NSFileManager defaultManager];
	// Only top-level and nested archives have a solid directory.
	if (record.solidDirectory) { [fileManager removeItemAtPath: record.solidDirectory error: NULL]; }
	if (pathIsTemp && record.path) { [fileManager removeItemAtPath: record.path error: NULL]; }
	BOOL childrenAreTemp = record.kind != TSSTArchiveScanRecordKindFolder;
	for (TSSTArchiveScanRecord *child in record.children)
	{
		TSSTDiscardScanRecord(child, childrenAreTemp);
	}
}

+ (void)discardScanRecords:(NSArray<TSSTArchiveScanRecord *> *)records
{
	for (TSSTArchiveScanRecord *record in records)
	{
		TSSTDiscardScanRecord(record, YES);
	}
}

/// Progressive counterpart of +scanRecordForFileURL:...: for RAR/7z (or a
/// zip under SC_FORCE_XAD) the listing is delivered in batches as entries
/// are found. Takes the file's URL, name and password as plain values (the
/// caller captures them on the main thread): this runs on the scan queue
/// and must not read managed-object attributes.
- (void)scanArchiveProgressivelyForFileURL:(NSURL *)fileURL name:(nullable NSString *)name password:(nullable NSString *)password perBatch:(void (^)(id _Nullable recordSoFar, NSArray<id> *newChildren, BOOL isFinal, NSError * _Nullable error))perBatch
{
	// Build the zip index once; a scannable one goes straight to the
	// single-shot scan, which reuses it (and its cache).
	TSSTCachingByteSource *zipCachingSource = nil;
	TSSTZipIndex *zi = [TSSTManagedArchive scannableZipIndexForFileURL: fileURL cachingSource: &zipCachingSource];
	if (zi)
	{
		// The zip index is already fast and fully synchronous (one
		// pread() of the central directory) -- no need for progressive
		// batching.
		TSSTArchiveScanRecord *record = [TSSTManagedArchive scanRecordForFileURL: fileURL name: name password: password zipIndex: zi cachingSource: zipCachingSource];
		record.scanErrors = @[]; // the zip path has no non-fatal errors to report
		perBatch(record, record.children, YES, nil);
		return;
	}

	// RAR/7z (or SC_FORCE_XAD): progressive listing on TSSTXADArchiveSource.
	NSError *buildError = nil;
	TSSTCachingByteSource *xadCachingSource = nil;
	TSSTXADArchiveSource *source = [TSSTManagedArchive buildXADSourceForFileURL: fileURL
																			 name: name ?: fileURL.lastPathComponent
																		 password: password
																 passwordProvider: [self xadPasswordProviderWithInitialPassword: password]
																	cachingSource: &xadCachingSource
																			error: &buildError];
	if (!source)
	{
		if ([buildError.domain isEqualToString: TSSTXADArchiveSourceErrorDomain] && buildError.code == TSSTXADArchiveSourceErrorMissingVolume)
		{
			// A sibling volume can't be read (typically sandbox access):
			// list what XADArchive can from the file itself, and tell the
			// user what is missing.
			TSSTArchiveScanRecord *record = [TSSTManagedArchive scanRecordForFileURL: fileURL name: name password: password zipIndex: nil cachingSource: nil];
			record.scanErrors = @[buildError];
			perBatch(record, record.children, YES, nil);
			return;
		}
		perBatch(nil, @[], YES, buildError ?: [NSError errorWithDomain: TSSTXADArchiveSourceErrorDomain code: TSSTXADArchiveSourceErrorCannotOpen userInfo: nil]);
		return;
	}

	TSSTArchiveScanRecord *record = [TSSTArchiveScanRecord new];
	record.name = name ?: fileURL.lastPathComponent;
	record.builtXADSource = source;
	record.builtCachingSource = xadCachingSource;
	record.backendDescription = @"XAD-progressive";

	NSMutableArray<NSError *> *scanErrors = [NSMutableArray array];
	NSMutableArray<TSSTXADArchiveEntry *> *pendingDataEntries = [NSMutableArray array]; // archive/pdf entries, resolved after the parse finishes
	NSMutableArray<TSSTXADArchiveEntry *> *allEntries = [NSMutableArray array];
	__block BOOL headerDelivered = NO;

	[source parseWithEntryBatchHandler: ^(NSArray<TSSTXADArchiveEntry *> *batch, BOOL isFinal, NSError *parseError) {
		NSMutableArray<TSSTArchiveScanRecord *> *children = [NSMutableArray arrayWithCapacity: batch.count];
		[allEntries addObjectsFromArray: batch];

		for (TSSTXADArchiveEntry *entry in batch)
		{
			if (entry.isDirectory) { continue; }
			switch (TSSTClassifyScanEntryName(entry.name))
			{
				case TSSTScanEntryClassImage:
					[children addObject: TSSTImageChildRecord(entry.name, (NSInteger)entry.index, NO)];
					break;
				case TSSTScanEntryClassText:
					[children addObject: TSSTImageChildRecord(entry.name, (NSInteger)entry.index, YES)];
					break;
				case TSSTScanEntryClassArchive:
				case TSSTScanEntryClassPDF:
					// Needs entry bytes -- extracting here (still mid-parse,
					// on the parse thread) would deadlock against
					// TSSTXADArchiveSource's own request queue. Defer to
					// after the parse finishes, when direct extraction is
					// safe; see below.
					[pendingDataEntries addObject: entry];
					break;
				case TSSTScanEntryClassIgnored:
					break;
			}
		}

		if (isFinal)
		{
			for (TSSTXADArchiveEntry *entry in pendingDataEntries)
			{
				NSError *dataError = nil;
				NSData *fileData = [source dataForEntry: entry.index error: &dataError];
				if (!fileData)
				{
					if (dataError) { [scanErrors addObject: dataError]; }
					continue;
				}
				if (TSSTClassifyScanEntryName(entry.name) == TSSTScanEntryClassArchive)
				{
					[children addObject: TSSTNestedArchiveChildRecord(fileData, entry.name)];
				}
				else
				{
					[children addObject: TSSTPDFChildRecord(fileData, entry.name)];
				}
			}
			record.xadAllEntriesForStreamer = [allEntries copy];
			record.scanErrors = scanErrors; // reported individually by the caller, not folded into a single fatal error
		}

		perBatch(headerDelivered ? nil : record, children, isFinal, isFinal ? parseError : nil);
		headerDelivered = YES;
	}];
}

/// Main-thread only: walks a record produced by
/// +scanRecordForFileURL:name:password: and inserts the corresponding
/// Core Data entities, reusing the already-built backend (no re-parsing).
- (void)applyScanRecord:(TSSTArchiveScanRecord *)record
{
	if (!record)
	{
		return;
	}
	[self applyScanRecordHeader: record];
	[self insertChildRecords: record.children];
}

- (void)applyScanRecordHeader:(id)recordObject
{
	TSSTArchiveScanRecord *record = (TSSTArchiveScanRecord *)recordObject;
	if (!record)
	{
		return;
	}

	if ([record.builtInstance isKindOfClass: [TSSTZipIndex class]])
	{
		_zipIndex = record.builtInstance;
		_zipIndexAttempted = YES;
		[self adoptCachingSource: record.builtCachingSource];
		if (_cachingSource)
		{
			[self startStreamerForZipIndex: _zipIndex];
		}
	}
	else if (record.builtXADSource)
	{
		_xadSource = record.builtXADSource;
		_xadSourceAttempted = YES;
		_zipIndexAttempted = YES; // not a zip: never build a second source for it
		_xadSourceParseStarted = YES; // -scanArchiveProgressivelyForFileURL:name:password:perBatch: is already driving the parse
		[self adoptCachingSource: record.builtCachingSource];
		// The streamer starts once the whole parse finishes (see
		// -scanArchiveProgressivelyForFileURL:name:password:perBatch:'s final-batch handling),
		// since it needs every entry's span up front, in reading order.
	}
	else if (record.builtInstance)
	{
		instance = record.builtInstance;
		// The scan's own delegate is gone by now (XADArchive holds it weakly).
		[instance setDelegate: self];
	}

	if (record.password)
	{
		self.password = record.password;
	}
	if (record.solidDirectory)
	{
		self.solidDirectory = record.solidDirectory;
	}
}

- (void)nestedArchiveContents
{
	[TSSTManagedGroup batchURLErrorsForGroupName: self.name ?: self.fileURL.lastPathComponent during: ^(NSMutableArray<NSError *> *errors) {
		[self applyScanRecord: [TSSTManagedArchive scanRecordForFileURL: self.fileURL name: self.name password: self.password]];
	}];
}


- (BOOL)quicklookCompatible
{	
	NSString * extension = [[self.name pathExtension] lowercaseString];
	return [TSSTManagedArchive.quicklookExtensions containsObject: extension];
}


/* Delegates */

/// Called when Simple Comic encounters a password protected
/// archive.  Brings a password dialog forward.
- (void)archiveNeedsPassword:(XADArchive *)archive
{
	NSString * password = self.password;
	
	if(password)
	{
		archive.password = password;
		return;
	}
	
	password = [(SimpleComicAppDelegate*)[NSApp delegate] passwordForArchiveWithPath: self.path];
	archive.password = password;
	
	self.password = password;
}

@end


@implementation TSSTManagedPDF

- (BOOL)isLeafPageSource
{
	return YES;
}

- (id)instance
{
	if (!instance)
	{
		NSURL *aURL = self.fileURL;
		[aURL startAccessingSecurityScopedResource];
		instance = [[PDFDocument alloc] initWithURL: aURL];
	}
	
	return instance;
}

- (void)requestDataForPageIndex:(NSInteger)index completionHandler:(void(^)(NSData *_Nullable pageData, NSError *_Nullable error))callback
{
	[groupLock lock];
	PDFPage * page = [(PDFDocument*)[self instance] pageAtIndex: index];
	[groupLock unlock];
	
	NSRect bounds = [page boundsForBox: kPDFDisplayBoxMediaBox];
	CGFloat dimension = 1400;
	CGFloat scale = 1 > (NSHeight(bounds) / NSWidth(bounds)) ? dimension / NSWidth(bounds) :  dimension / NSHeight(bounds);
	bounds.size = scaleSize(bounds.size, scale);
	if (NSEqualRects(bounds, NSZeroRect)) {
		// Prevent zero size exception for images
		bounds.size = NSMakeSize(50, 50);
	}
	if (isinf(scale) || scale == 0) {
		scale = 1;
	}
	
	NSImage * pageImage = [[NSImage alloc] initWithSize: bounds.size];
	[pageImage lockFocus];
		[[NSColor whiteColor] set];
		NSRectFill(bounds);
		NSAffineTransform * scaleTransform = [NSAffineTransform transform];
		[scaleTransform scaleBy: scale];
		[scaleTransform concat];
		[page drawWithBox: kPDFDisplayBoxMediaBox toContext:[[NSGraphicsContext currentContext] CGContext]];
	[pageImage unlockFocus];
	
	NSData * imageData = [pageImage TIFFRepresentation];
	
	callback(imageData, nil);
}

- (void)pdfContents
{
	PDFDocument * rep = [self instance];
	[self insertImagesForPageCount: rep.pageCount];
}

/// Main-thread only: shared by `-pdfContents` (top-level/synchronous PDFs) and
/// `-applyPDFScanRecord:` (PDFs found nested inside a background-scanned
/// archive) -- inserts one Image entity per page.
- (void)insertImagesForPageCount:(NSInteger)imageCount
{
	TSSTPage * imageDescription;
	NSMutableSet<TSSTPage*> * pageSet = [NSMutableSet set];
	for (NSInteger pageNumber = 0; pageNumber < imageCount; ++pageNumber)
	{
		imageDescription = [NSEntityDescription insertNewObjectForEntityForName: @"Image" inManagedObjectContext: [self managedObjectContext]];
		imageDescription.imagePath = [NSString stringWithFormat: NSLocalizedString(@"PDF page %li", @"PDF page number"), (long)(pageNumber + 1)];
		imageDescription.index = @(pageNumber);
		[pageSet addObject: imageDescription];
	}
	self.images = pageSet;
}

/// Main-thread only: applies a TSSTArchiveScanRecord (kind PDF) built by
/// `+[TSSTManagedArchive scanRecordForFileURL:...]` for a PDF found nested
/// inside an archive during a background scan. Reuses the already-built
/// PDFDocument instead of re-parsing it.
- (void)applyPDFScanRecord:(TSSTArchiveScanRecord *)record
{
	if (record.builtInstance)
	{
		instance = record.builtInstance;
	}
	[self insertImagesForPageCount: record.pdfPageCount];
}

@end
