//
//  TSSTXADArchiveSourceTests.m
//  OCR Unit Tests
//
//  Verifies TSSTXADArchiveSource (the streaming RAR/7z backend) against
//  7z fixtures built with the system `7zz` tool, cross-checked against
//  XADArchive for parity, plus a progressive-delivery test proving pages
//  can arrive before a header walk finishes. Real-comics parity for RAR
//  is gated on SC_TEST_COMICS_DIR, exactly like TSSTZipIndexTests.
//

#import <XCTest/XCTest.h>
#import <XADMaster/XADArchive.h>
#import <XADMaster/XADArchiveParser.h>
#import "TSSTRAR5QuickOpen.h"
#import "TSSTXADArchiveSource.h"
#import "TSSTArchiveByteSource.h"
#import "TSSTCachingByteSource.h"
#import "TSSTArchiveStreamer.h"
#import "TSSTTestFixtures.h"
#import "TSSTManagedGroup.h"
#import "TSSTManagedGroup+CoreDataProperties.h"

static NSString * const k7zzPath = @"/opt/homebrew/bin/7zz";

/// Collects the entry dictionaries a parser emits, so a Quick Open listing
/// can be compared key-for-key with a normal XAD walk.
@interface TSSTEntryCollector : NSObject <XADArchiveParserDelegate>
@property (nonatomic, readonly) NSMutableArray<NSDictionary *> *dicts;
@end

@implementation TSSTEntryCollector
- (instancetype)init { if ((self = [super init])) _dicts = [NSMutableArray array]; return self; }
- (void)archiveParser:(XADArchiveParser *)parser foundEntryWithDictionary:(NSDictionary *)dict { [_dicts addObject: dict]; }
- (BOOL)archiveParsingShouldStop:(XADArchiveParser *)parser { return NO; }
@end

@interface TSSTXADArchiveSourceTests : XCTestCase
@property (nonatomic, copy) NSString *tempDir;
@end

@implementation TSSTXADArchiveSourceTests

- (void)setUp
{
	[super setUp];
	NSString *base = NSTemporaryDirectory();
	self.tempDir = [base stringByAppendingPathComponent: [NSString stringWithFormat: @"TSSTXADArchiveSourceTests-%@", [[NSUUID UUID] UUIDString]]];
	[[NSFileManager defaultManager] createDirectoryAtPath: self.tempDir withIntermediateDirectories: YES attributes: nil error: NULL];
}

- (void)tearDown
{
	[[NSFileManager defaultManager] removeItemAtPath: self.tempDir error: NULL];
	[super tearDown];
}

#pragma mark - Helpers

/// Exit status of the tool, or -1 when it can't be launched (e.g. 7zz isn't
/// installed): -launch would throw, failing the test instead of skipping it.
- (int)runTask:(NSString *)launchPath arguments:(NSArray<NSString *> *)args inDirectory:(NSString *)dir
{
	NSTask *task = [[NSTask alloc] init];
	task.launchPath = launchPath;
	task.arguments = args;
	task.currentDirectoryPath = dir;
	task.standardOutput = [NSPipe pipe];
	task.standardError = [NSPipe pipe];
	if (![task launchAndReturnError: NULL]) return -1;
	[task waitUntilExit];
	return task.terminationStatus;
}

/// Builds `count` random files of 50-200KB in a fresh source dir, then
/// packs them into a 7z archive at archivePath with the given extra 7zz
/// flags (e.g. @[@"-ms=off"] for non-solid, @[@"-mx0"] for stored).
- (NSString *)build7zNamed:(NSString *)name entryCount:(NSUInteger)count extraFlags:(NSArray<NSString *> *)flags
{
	NSString *srcDir = [self.tempDir stringByAppendingPathComponent: [name stringByAppendingString: @"-src"]];
	[[NSFileManager defaultManager] createDirectoryAtPath: srcDir withIntermediateDirectories: YES attributes: nil error: NULL];

	srandom(1);
	for (NSUInteger i = 0; i < count; i++) {
		NSUInteger size = 50 * 1024 + (NSUInteger)(random() % (150 * 1024));
		NSMutableData *data = [NSMutableData dataWithLength: size];
		uint8_t *bytes = data.mutableBytes;
		for (NSUInteger b = 0; b < size; b++) bytes[b] = (uint8_t)(random() & 0xFF);
		NSString *entryName = [NSString stringWithFormat: @"file-%03lu.bin", (unsigned long)i];
		[data writeToFile: [srcDir stringByAppendingPathComponent: entryName] atomically: YES];
	}

	NSString *archivePath = [self.tempDir stringByAppendingPathComponent: name];
	NSMutableArray<NSString *> *args = [NSMutableArray arrayWithArray: @[@"a", @"-t7z", archivePath, @"."]];
	[args addObjectsFromArray: flags];
	int status = [self runTask: k7zzPath arguments: args inDirectory: srcDir];
	if (status != 0) return nil;
	return archivePath;
}

/// Parses the whole archive synchronously (blocking until done) and
/// returns the entries found, or nil on failure.
- (nullable NSArray<TSSTXADArchiveEntry *> *)parseArchiveAtPath:(NSString *)path source:(out TSSTXADArchiveSource * _Nullable * _Nullable)sourceOut error:(NSError **)error
{
	id<TSSTArchiveByteSource> byteSource = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: error];
	if (!byteSource) return nil;

	TSSTXADArchiveSource *source = [[TSSTXADArchiveSource alloc] initWithByteSource: byteSource
																				name: path.lastPathComponent
																				path: path
																			password: nil
																	passwordProvider: nil
																			   error: error];
	if (!source) return nil;
	if (sourceOut) *sourceOut = source;

	NSMutableArray<TSSTXADArchiveEntry *> *all = [NSMutableArray array];
	__block NSError *finalError = nil;
	BOOL success = [source parseWithEntryBatchHandler: ^(NSArray<TSSTXADArchiveEntry *> *batch, BOOL isFinal, NSError *err) {
		[all addObjectsFromArray: batch];
		if (isFinal) finalError = err;
	}];
	if (!success) {
		if (error) *error = finalError;
		return nil;
	}
	return all;
}

#pragma mark - Parity vs XADArchive

- (void)assertParityForArchiveAtPath:(NSString *)path
{
	NSError *error = nil;
	TSSTXADArchiveSource *source = nil;
	NSArray<TSSTXADArchiveEntry *> *entries = [self parseArchiveAtPath: path source: &source error: &error];
	XCTAssertNotNil(entries, @"%@: %@", path.lastPathComponent, error);
	if (!entries) return;

	XADArchive *archive = [[XADArchive alloc] initWithFileURL: [NSURL fileURLWithPath: path] delegate: nil error: &error];
	XCTAssertNotNil(archive, @"%@: %@", path.lastPathComponent, error);
	if (!archive) return;

	XCTAssertEqual((NSInteger)entries.count, [archive numberOfEntries], @"%@ entry count must match XAD", path.lastPathComponent);

	NSInteger compareCount = MIN((NSInteger)entries.count, [archive numberOfEntries]);
	for (NSInteger i = 0; i < compareCount; i++) {
		TSSTXADArchiveEntry *entry = entries[i];
		NSString *xadName = [archive nameOfEntry: i];
		XCTAssertEqualObjects(entry.name, xadName, @"%@ entry %ld name must match XAD", path.lastPathComponent, (long)i);

		if (entry.isDirectory) continue;

		NSError *ourError = nil;
		NSData *ourData = [source dataForEntry: (NSUInteger)i error: &ourError];
		NSData *xadData = [archive contentsOfEntry: i];
		XCTAssertEqualObjects(ourData, xadData, @"%@ entry %ld (%@) bytes must match XAD, error: %@", path.lastPathComponent, (long)i, entry.name, ourError);
	}
}

- (void)testSolid7zMatchesXAD
{
	NSString *path = [self build7zNamed: @"solid.7z" entryCount: 30 extraFlags: @[]];
	XCTSkipUnless(path != nil, @"7zz not available or failed to build fixture");
	[self assertParityForArchiveAtPath: path];
}

- (void)testNonSolid7zMatchesXAD
{
	NSString *path = [self build7zNamed: @"nonsolid.7z" entryCount: 30 extraFlags: @[@"-ms=off"]];
	XCTSkipUnless(path != nil, @"7zz not available or failed to build fixture");
	[self assertParityForArchiveAtPath: path];
}

- (void)testStored7zMatchesXAD
{
	NSString *path = [self build7zNamed: @"stored.7z" entryCount: 30 extraFlags: @[@"-mx0"]];
	XCTSkipUnless(path != nil, @"7zz not available or failed to build fixture");
	[self assertParityForArchiveAtPath: path];
}

#pragma mark - Progressive delivery

/// Over a timeless simulated link, the first batch of entries must arrive
/// well before the whole parse finishes for a multi-entry archive -- the
/// entire point of batching entries as they're found instead of only
/// reporting once at the end (as XADArchive effectively does).
- (void)testProgressiveDeliveryOverSimulatedLink
{
	NSString *path = [self build7zNamed: @"progressive-nonsolid.7z" entryCount: 40 extraFlags: @[@"-ms=off"]];
	XCTSkipUnless(path != nil, @"7zz not available or failed to build fixture");

	NSError *error = nil;
	id<TSSTArchiveByteSource> fileSource = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: &error];
	XCTAssertNotNil(fileSource, @"%@", error);

	TSSTSimulatedLinkByteSource *link = [TSSTSimulatedLinkByteSource smbWifiLinkWrapping: fileSource];
	link.simulateTime = NO; // timeless: fast and deterministic
	link.logsRequests = YES;

	TSSTXADArchiveSource *source = [[TSSTXADArchiveSource alloc] initWithByteSource: link
																				name: path.lastPathComponent
																				path: path
																			password: nil
																	passwordProvider: nil
																			   error: &error];
	XCTAssertNotNil(source, @"%@", error);
	if (!source) return;

	__block NSUInteger firstBatchCount = 0;
	__block BOOL sawFirstBatch = NO;
	__block NSUInteger totalCount = 0;
	__block NSUInteger readsAtFirstBatch = 0;

	BOOL success = [source parseWithEntryBatchHandler: ^(NSArray<TSSTXADArchiveEntry *> *batch, BOOL isFinal, NSError *err) {
		if (!sawFirstBatch && batch.count > 0) {
			sawFirstBatch = YES;
			firstBatchCount = batch.count;
			readsAtFirstBatch = link.readCount;
		}
		totalCount += batch.count;
	}];

	XCTAssertTrue(success, @"parse should succeed");
	XCTAssertTrue(sawFirstBatch, @"at least one non-final batch should have been delivered");
	XCTAssertLessThan(firstBatchCount, totalCount, @"first batch should be a strict subset of all entries for a 40-entry archive");
	NSLog(@"[fast-open][xad-progressive] first batch (%lu entries) after %lu reads; total %lu entries, %lu reads",
		  (unsigned long)firstBatchCount, (unsigned long)readsAtFirstBatch, (unsigned long)totalCount, (unsigned long)link.readCount);
}

/// Requesting an entry's bytes while the parse is still running must
/// return the same bytes as after the parse completes, exercising the
/// mid-parse request-queue path in TSSTXADArchiveSource.
- (void)testDataForEntryDuringParseMatchesXAD
{
	NSString *path = [self build7zNamed: @"midparse-nonsolid.7z" entryCount: 40 extraFlags: @[@"-ms=off"]];
	XCTSkipUnless(path != nil, @"7zz not available or failed to build fixture");

	NSError *error = nil;
	id<TSSTArchiveByteSource> fileSource = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: &error];
	TSSTSimulatedLinkByteSource *link = [TSSTSimulatedLinkByteSource smbWifiLinkWrapping: fileSource];
	link.simulateTime = NO;

	TSSTXADArchiveSource *source = [[TSSTXADArchiveSource alloc] initWithByteSource: link
																				name: path.lastPathComponent
																				path: path
																			password: nil
																	passwordProvider: nil
																			   error: &error];
	XCTAssertNotNil(source, @"%@", error);
	if (!source) return;

	XADArchive *archive = [[XADArchive alloc] initWithFileURL: [NSURL fileURLWithPath: path] delegate: nil error: &error];
	XCTAssertNotNil(archive, @"%@", error);

	dispatch_queue_t parseQueue = dispatch_queue_create("TSSTXADArchiveSourceTests.parse", DISPATCH_QUEUE_SERIAL);
	dispatch_semaphore_t parseStarted = dispatch_semaphore_create(0);
	__block BOOL parseSuccess = NO;
	dispatch_async(parseQueue, ^{
		[source parseWithEntryBatchHandler: ^(NSArray<TSSTXADArchiveEntry *> *batch, BOOL isFinal, NSError *err) {
			if (batch.count > 0) dispatch_semaphore_signal(parseStarted);
			if (isFinal) parseSuccess = (err == nil);
		}];
	});

	// Wait for at least one entry to be found, then request entry 0's
	// bytes while the parse is (almost certainly) still running.
	dispatch_semaphore_wait(parseStarted, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));

	NSError *dataError = nil;
	NSData *midParseData = [source dataForEntry: 0 error: &dataError];
	XCTAssertNotNil(midParseData, @"%@", dataError);

	NSData *xadData = [archive contentsOfEntry: 0];
	XCTAssertEqualObjects(midParseData, xadData, @"mid-parse extraction must match XAD's own bytes");

	// Drain the parse queue so teardown doesn't race a still-running parse.
	dispatch_sync(parseQueue, ^{});
	XCTAssertTrue(parseSuccess);
}

#pragma mark - Session-restore determinism

/// Session restore rebuilds a fresh TSSTXADArchiveSource and re-parses
/// from scratch, relying on TSSTPage.index values inserted by the first
/// parse still lining up with the second one. Verify that explicitly:
/// parsing the same archive twice yields identical name arrays in the
/// same order.
- (void)testParsingSameArchiveTwiceIsDeterministic
{
	NSString *path = [self build7zNamed: @"determinism-nonsolid.7z" entryCount: 30 extraFlags: @[@"-ms=off"]];
	XCTSkipUnless(path != nil, @"7zz not available or failed to build fixture");

	NSError *error1 = nil, *error2 = nil;
	NSArray<TSSTXADArchiveEntry *> *first = [self parseArchiveAtPath: path source: nil error: &error1];
	NSArray<TSSTXADArchiveEntry *> *second = [self parseArchiveAtPath: path source: nil error: &error2];

	XCTAssertNotNil(first, @"%@", error1);
	XCTAssertNotNil(second, @"%@", error2);
	XCTAssertEqual(first.count, second.count);

	NSUInteger compareCount = MIN(first.count, second.count);
	for (NSUInteger i = 0; i < compareCount; i++)
	{
		XCTAssertEqual(first[i].index, second[i].index, @"entry %lu index must match across parses", (unsigned long)i);
		XCTAssertEqualObjects(first[i].name, second[i].name, @"entry %lu name must match across parses", (unsigned long)i);
	}
}

#pragma mark - Real-world RAR/7z parity (optional, only when SC_TEST_COMICS_DIR is set)

- (void)testRealWorldNonZipComicsParity
{
	NSString *dir = NSProcessInfo.processInfo.environment[@"SC_TEST_COMICS_DIR"];
	XCTSkipUnless(dir.length > 0, @"SC_TEST_COMICS_DIR not set");
	BOOL isDir = NO;
	BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath: dir isDirectory: &isDir] && isDir;
	XCTSkipUnless(exists, @"SC_TEST_COMICS_DIR is not a directory: %@", dir);

	NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath: dir error: NULL];
	NSMutableArray<NSString *> *paths = [NSMutableArray array];
	for (NSString *name in entries) {
		NSString *ext = [name.pathExtension lowercaseString];
		if ([ext isEqualToString: @"cbr"] || [ext isEqualToString: @"rar"] || [ext isEqualToString: @"cb7"]) {
			[paths addObject: [dir stringByAppendingPathComponent: name]];
		}
	}
	XCTSkipUnless(paths.count > 0, @"no .cbr/.rar/.cb7 files found in %@", dir);

	for (NSString *path in paths) {
		NSURL *url = [NSURL fileURLWithPath: path];
		NSError *error = nil;

		id<TSSTArchiveByteSource> fileSource = [TSSTFileByteSource sourceWithFileURL: url error: &error];
		TSSTSimulatedLinkByteSource *link = [TSSTSimulatedLinkByteSource smbWifiLinkWrapping: fileSource];
		link.simulateTime = NO;
		link.logsRequests = NO;

		CFAbsoluteTime xadStart = CFAbsoluteTimeGetCurrent();
		TSSTXADArchiveSource *source = [[TSSTXADArchiveSource alloc] initWithByteSource: link
																					name: path.lastPathComponent
																					path: path
																				password: nil
																		passwordProvider: nil
																				   error: &error];
		XCTAssertNotNil(source, @"%@: %@", path.lastPathComponent, error);
		if (!source) continue;

		__block NSMutableArray<TSSTXADArchiveEntry *> *allEntries = [NSMutableArray array];
		BOOL success = [source parseWithEntryBatchHandler: ^(NSArray<TSSTXADArchiveEntry *> *batch, BOOL isFinal, NSError *err) {
			[allEntries addObjectsFromArray: batch];
		}];
		CFAbsoluteTime xadElapsed = CFAbsoluteTimeGetCurrent() - xadStart;
		XCTAssertTrue(success, @"%@ failed to parse", path.lastPathComponent);
		if (!success) continue;

		XADArchive *archive = [[XADArchive alloc] initWithFileURL: url delegate: nil error: &error];
		XCTAssertNotNil(archive, @"%@: %@", path.lastPathComponent, error);
		if (!archive) continue;

		NSLog(@"[fast-open][parity][xad] %@: TSSTXADArchiveSource listed %lu entries in %.3fs, %lu reads, simulated %.3fs",
			  path.lastPathComponent, (unsigned long)allEntries.count, xadElapsed, (unsigned long)link.readCount, link.simulatedElapsed);

		XCTAssertEqual((NSInteger)allEntries.count, [archive numberOfEntries], @"%@", path.lastPathComponent);

		NSInteger imagesCompared = 0;
		for (NSInteger i = 0; i < (NSInteger)allEntries.count && imagesCompared < 3; i++) {
			TSSTXADArchiveEntry *entry = allEntries[i];
			XCTAssertEqualObjects(entry.name, [archive nameOfEntry: i], @"%@ entry %ld", path.lastPathComponent, (long)i);
			NSString *ext = [entry.name.pathExtension lowercaseString];
			BOOL isImage = [@[@"jpg", @"jpeg", @"png", @"gif", @"webp"] containsObject: ext];
			if (!isImage || entry.isDirectory) continue;

			NSError *ourError = nil;
			NSData *ourData = [source dataForEntry: (NSUInteger)i error: &ourError];
			NSData *xadData = [archive contentsOfEntry: i];
			XCTAssertEqualObjects(ourData, xadData, @"%@ entry %ld (%@)", path.lastPathComponent, (long)i, entry.name);
			imagesCompared++;
		}
	}
}

#pragma mark - 7z byte spans

- (NSArray<TSSTXADArchiveEntry *> *)listPath:(NSString *)path source:(TSSTXADArchiveSource **)sourceOut
{
	return [self listPath: path source: sourceOut reads: NULL];
}

/// Non-solid stored 7z: every file is its own folder, so each entry maps to
/// its own packed range, which (stored) holds exactly the file's bytes.
- (void)testNonSolid7zEntriesHaveOwnPackedSpans
{
	NSString *path = [self build7zNamed: @"spans-nonsolid.7z" entryCount: 12 extraFlags: @[@"-ms=off", @"-mx0"]];
	XCTSkipUnless(path != nil, @"7zz not available or failed to build fixture");
	TSSTXADArchiveSource *source = nil;
	NSArray<TSSTXADArchiveEntry *> *entries = [self listPath: path source: &source];
	XCTAssertEqual(entries.count, 12u);
	NSData *file = [NSData dataWithContentsOfFile: path];
	NSMutableSet<NSValue *> *distinct = [NSMutableSet set];
	for (TSSTXADArchiveEntry *entry in entries) {
		XCTAssertTrue(entry.hasSpanRange, @"%@", entry.name);
		if (!entry.hasSpanRange) continue;
		XCTAssertLessThanOrEqual(NSMaxRange(entry.spanRange), file.length);
		XCTAssertEqual(entry.spanRange.length, (NSUInteger)entry.size, @"stored entry's packed span is its size");
		[distinct addObject: [NSValue valueWithRange: entry.spanRange]];
		NSData *extracted = [source dataForEntry: entry.index error: NULL];
		XCTAssertEqualObjects([file subdataWithRange: entry.spanRange], extracted, @"%@", entry.name);
	}
	XCTAssertEqual(distinct.count, entries.count, @"one span per non-solid file");
}

/// Solid 7z: all files of the folder share one span, within the file.
- (void)testSolid7zEntriesShareOneFolderSpan
{
	NSString *path = [self build7zNamed: @"spans-solid.7z" entryCount: 12 extraFlags: @[@"-ms=on"]];
	XCTSkipUnless(path != nil, @"7zz not available or failed to build fixture");
	TSSTXADArchiveSource *source = nil;
	NSArray<TSSTXADArchiveEntry *> *entries = [self listPath: path source: &source];
	XCTAssertEqual(entries.count, 12u);
	NSUInteger fileLength = [[NSData dataWithContentsOfFile: path] length];
	NSMutableSet<NSValue *> *distinct = [NSMutableSet set];
	for (TSSTXADArchiveEntry *entry in entries) {
		XCTAssertTrue(entry.hasSpanRange, @"%@", entry.name);
		if (!entry.hasSpanRange) continue;
		XCTAssertGreaterThan(entry.spanRange.length, 0u);
		XCTAssertLessThanOrEqual(NSMaxRange(entry.spanRange), fileLength);
		[distinct addObject: [NSValue valueWithRange: entry.spanRange]];
	}
	XCTAssertEqual(distinct.count, 1u, @"a solid folder is one shared span");
}

/// The shared builder gives entries with identical ranges one span, and
/// leaves range-less entries unmapped.
- (void)testSpanBuilderSharesIdenticalRangesAndSkipsUnknown
{
	NSDictionary<NSNumber *, NSNumber *> *map = nil;
	NSArray<NSValue *> *spans = [TSSTArchiveStreamer spansForEntryIndices: @[@5, @2, @9, @1]
															rangeProvider: ^BOOL(NSUInteger idx, NSRange *out) {
		if (idx == 9) return NO;
		*out = idx == 2 ? NSMakeRange(100, 50) : NSMakeRange(0, 100);
		return YES;
	} spanIndexMap: &map];
	XCTAssertEqual(spans.count, 2u);
	XCTAssertEqualObjects(map[@5], @0);
	XCTAssertEqualObjects(map[@1], @0);
	XCTAssertEqualObjects(map[@2], @1);
	XCTAssertNil(map[@9]);
}

#pragma mark - RAR4 walk over a slow link

/// The real RAR4 (signature byte 6 == 0), Die - Loaded 009, in SC_TEST_COMICS_DIR.
- (NSString *)realRAR4Path
{
	NSString *dir = NSProcessInfo.processInfo.environment[@"SC_TEST_COMICS_DIR"];
	XCTSkipUnless(dir.length > 0, @"SC_TEST_COMICS_DIR not set");
	for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath: dir error: NULL]) {
		if (![name.pathExtension.lowercaseString isEqualToString: @"cbr"] && ![name.pathExtension.lowercaseString isEqualToString: @"rar"]) continue;
		NSString *path = [dir stringByAppendingPathComponent: name];
		NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath: path];
		NSData *sig = [fh readDataOfLength: 8];
		[fh closeFile];
		if (sig.length == 8 && ((const uint8_t *)sig.bytes)[6] == 0 && [sig rangeOfData: [NSData dataWithBytes: "Rar!" length: 4] options: 0 range: NSMakeRange(0, 4)].location == 0) return path;
	}
	XCTSkip(@"no RAR4 file in %@", dir);
	return nil;
}

/// Listing a RAR4 through the production stack (caching source over the
/// simulated Wi-Fi link) must not cost a network round trip per entry, and
/// the first batch (holding the first image) must arrive early.
- (void)testRAR4WalkOverWifiLinkIsCheapAndFlushesFirstImageEarly
{
	NSString *path = [self realRAR4Path];
	NSError *error = nil;
	id<TSSTArchiveByteSource> fileSource = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: &error];
	TSSTSimulatedLinkByteSource *link = [TSSTSimulatedLinkByteSource smbWifiLinkWrapping: fileSource];
	link.simulateTime = NO;
	TSSTCachingByteSource *cache = [[TSSTCachingByteSource alloc] initWithUpstream: link];
	TSSTXADArchiveSource *source = [[TSSTXADArchiveSource alloc] initWithByteSource: cache name: path.lastPathComponent path: path password: nil passwordProvider: nil error: &error];
	XCTAssertNotNil(source, @"%@", error);
	if (!source) return;

	__block NSUInteger total = 0, firstBatchCount = 0, readsAtFirstBatch = 0;
	__block NSTimeInterval simAtFirstBatch = 0;
	__block BOOL firstBatchHasImage = NO;
	XCTAssertTrue([source parseWithEntryBatchHandler: ^(NSArray<TSSTXADArchiveEntry *> *batch, BOOL isFinal, NSError *err) {
		if (firstBatchCount == 0 && batch.count > 0) {
			firstBatchCount = batch.count;
			readsAtFirstBatch = link.readCount;
			simAtFirstBatch = link.simulatedElapsed;
			for (TSSTXADArchiveEntry *e in batch) {
				NSString *ext = e.name.pathExtension.lowercaseString;
				if ([@[@"jpg", @"jpeg", @"png", @"gif", @"webp", @"jxl"] containsObject: ext]) firstBatchHasImage = YES;
			}
		}
		total += batch.count;
	}]);
	NSLog(@"[fast-open][rar4-walk] %@: %lu entries, %lu reads, simulated %.3fs; first batch %lu entries after %lu reads / %.3fs",
		  path.lastPathComponent, (unsigned long)total, (unsigned long)link.readCount, link.simulatedElapsed,
		  (unsigned long)firstBatchCount, (unsigned long)readsAtFirstBatch, simAtFirstBatch);
	XCTAssertGreaterThan(total, 0u);
	XCTAssertTrue(firstBatchHasImage, @"first batch should contain the first image entry");
	XCTAssertLessThanOrEqual(readsAtFirstBatch, 3u, @"first image should be listed after a handful of reads");
	XCTAssertLessThanOrEqual(simAtFirstBatch, 0.6, @"first batch should arrive within ~0.3s on the wifi link");
	XCTAssertLessThanOrEqual(link.simulatedElapsed, 0.06 * (double)total + 0.5, @"walk should cost well under ~60 ms per entry");
}

#pragma mark - RAR5 Quick Open

/// Real RAR5 comics (signature byte 6 == 1) in SC_TEST_COMICS_DIR.
- (NSArray<NSString *> *)realRAR5Paths
{
	NSString *dir = NSProcessInfo.processInfo.environment[@"SC_TEST_COMICS_DIR"];
	XCTSkipUnless(dir.length > 0, @"SC_TEST_COMICS_DIR not set");
	NSMutableArray<NSString *> *paths = [NSMutableArray array];
	for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath: dir error: NULL]) {
		NSString *path = [dir stringByAppendingPathComponent: name];
		NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath: path];
		NSData *head = [fh readDataOfLength: 8];
		[fh closeFile];
		if (head.length == 8 && memcmp(head.bytes, "Rar!\x1a\x07\x01\x00", 8) == 0) [paths addObject: path];
	}
	XCTSkipUnless(paths.count > 0, @"no RAR5 files in %@", dir);
	return paths;
}

/// The real RAR5s whose Quick Open record the lister accepts. One test comic
/// has a QO block that omits entries, which the lister must (and does)
/// decline; those fall back to the walk and are checked for parity only.
- (NSArray<NSString *> *)quickOpenPaths:(NSArray<NSString *> *)paths
{
	NSMutableArray<NSString *> *accepted = [NSMutableArray array];
	for (NSString *path in paths) {
		if ([TSSTRAR5QuickOpen listParser: [XADArchiveParser archiveParserForPath: path nserror: NULL] error: NULL]) [accepted addObject: path];
	}
	XCTAssertGreaterThanOrEqual(accepted.count, 2u, @"most real RAR5s should have a usable Quick Open record");
	return accepted;
}

- (NSArray<NSDictionary *> *)dictionariesForParserAtPath:(NSString *)path quickOpen:(BOOL)quickOpen
{
	XADArchiveParser *parser = [XADArchiveParser archiveParserForPath: path nserror: NULL];
	TSSTEntryCollector *collector = [[TSSTEntryCollector alloc] init];
	parser.delegate = collector;
	if (quickOpen) {
		NSError *error = nil;
		XCTAssertTrue([TSSTRAR5QuickOpen listParser: parser error: &error], @"%@ should list via Quick Open", path.lastPathComponent);
		XCTAssertNil(error);
	} else {
		XCTAssertTrue([parser parseWithError: NULL]);
	}
	return collector.dicts;
}

/// Lists over a timeless simulated link; returns the entries and read count.
- (NSArray<TSSTXADArchiveEntry *> *)listPath:(NSString *)path source:(TSSTXADArchiveSource **)sourceOut reads:(NSUInteger *)reads
{
	NSError *error = nil;
	id<TSSTArchiveByteSource> fileSource = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: &error];
	TSSTSimulatedLinkByteSource *link = [TSSTSimulatedLinkByteSource smbWifiLinkWrapping: fileSource];
	link.simulateTime = NO;
	TSSTXADArchiveSource *source = [[TSSTXADArchiveSource alloc] initWithByteSource: link name: path.lastPathComponent path: path password: nil passwordProvider: nil error: &error];
	XCTAssertNotNil(source, @"%@", error);
	NSMutableArray<TSSTXADArchiveEntry *> *all = [NSMutableArray array];
	XCTAssertTrue([source parseWithEntryBatchHandler: ^(NSArray<TSSTXADArchiveEntry *> *batch, BOOL isFinal, NSError *err) {
		[all addObjectsFromArray: batch];
	}]);
	if (sourceOut) *sourceOut = source;
	if (reads) *reads = link.readCount;
	return all;
}

- (void)testRAR5QuickOpenDictionariesMatchXADWalk
{
	for (NSString *path in [self quickOpenPaths: [self realRAR5Paths]]) {
		NSArray<NSDictionary *> *walked = [self dictionariesForParserAtPath: path quickOpen: NO];
		NSArray<NSDictionary *> *quick = [self dictionariesForParserAtPath: path quickOpen: YES];
		XCTAssertEqual(quick.count, walked.count, @"%@", path.lastPathComponent);
		for (NSUInteger i = 0; i < MIN(quick.count, walked.count); i++) {
			XCTAssertEqualObjects([NSSet setWithArray: quick[i].allKeys],
								  [NSSet setWithArray: walked[i].allKeys], @"%@ entry %lu key set", path.lastPathComponent, (unsigned long)i);
			for (NSString *key in walked[i]) {
				XCTAssertEqualObjects(quick[i][key], walked[i][key], @"%@ entry %lu key %@", path.lastPathComponent, (unsigned long)i, key);
			}
		}
	}
}

- (void)testRAR5QuickOpenListsInFewReadsAndExtractsLikeXAD
{
	NSArray<NSString *> *all = [self realRAR5Paths];
	NSArray<NSString *> *accepted = [self quickOpenPaths: all];
	for (NSString *path in all) {
		BOOL quick = [accepted containsObject: path];
		NSUInteger reads = 0;
		TSSTXADArchiveSource *source = nil;
		NSArray<TSSTXADArchiveEntry *> *entries = [self listPath: path source: &source reads: &reads];
		NSLog(@"[fast-open][rar5-qo] %@: %lu entries in %lu reads", path.lastPathComponent, (unsigned long)entries.count, (unsigned long)reads);
		if (quick) XCTAssertLessThanOrEqual(reads, 4u, @"%@ must list in <= 4 reads", path.lastPathComponent);
		else XCTAssertGreaterThan(reads, 4u, @"%@ declined by Quick Open should have walked", path.lastPathComponent);

		NSError *error = nil;
		XADArchive *archive = [[XADArchive alloc] initWithFileURL: [NSURL fileURLWithPath: path] delegate: nil error: &error];
		XCTAssertNotNil(archive, @"%@", error);
		if (!archive) continue;
		XCTAssertEqual((NSInteger)entries.count, [archive numberOfEntries]);

		// First, middle and last files: covers stored and compressed entries alike.
		NSMutableArray<NSNumber *> *files = [NSMutableArray array];
		for (NSUInteger i = 0; i < entries.count; i++) if (!entries[i].isDirectory) [files addObject: @(i)];
		NSMutableIndexSet *picks = [NSMutableIndexSet indexSet];
		if (files.count) { [picks addIndex: 0]; [picks addIndex: files.count / 2]; [picks addIndex: files.count - 1]; }
		[picks enumerateIndexesUsingBlock: ^(NSUInteger k, BOOL *stop) {
			NSInteger i = files[k].integerValue;
			XCTAssertEqualObjects(entries[i].name, [archive nameOfEntry: i]);
			XCTAssertEqualObjects([source dataForEntry: (NSUInteger)i error: NULL], [archive contentsOfEntry: i], @"%@ entry %ld bytes", path.lastPathComponent, (long)i);
		}];
	}
}

/// With the QO record's name clobbered (on a copy-on-write clone; the
/// original is untouched) the lister must decline and the normal walk
/// must still produce the same entries.
- (void)testRAR5WithoutQuickOpenFallsBackToWalk
{
	NSString *original = [self quickOpenPaths: [self realRAR5Paths]].firstObject;
	NSString *clone = [self.tempDir stringByAppendingPathComponent: @"no-qo.rar"];
	NSError *error = nil;
	XCTAssertTrue([[NSFileManager defaultManager] copyItemAtPath: original toPath: clone error: &error], @"%@", error);

	NSFileHandle *fh = [NSFileHandle fileHandleForUpdatingAtPath: clone];
	unsigned long long size = [fh seekToEndOfFile];
	unsigned long long tail = MIN(size, 262144ull);
	[fh seekToFileOffset: size - tail];
	NSData *data = [fh readDataOfLength: (NSUInteger)tail];
	const uint8_t needle[3] = { 0x02, 'Q', 'O' };
	NSRange found = [data rangeOfData: [NSData dataWithBytes: needle length: 3] options: NSDataSearchBackwards range: NSMakeRange(0, data.length)];
	XCTAssertNotEqual(found.location, (NSUInteger)NSNotFound, @"QO name not found in tail");
	[fh seekToFileOffset: size - tail + found.location + 1];
	[fh writeData: [NSData dataWithBytes: "XX" length: 2]];
	[fh closeFile];

	XADArchiveParser *parser = [XADArchiveParser archiveParserForPath: clone nserror: NULL];
	XCTAssertFalse([TSSTRAR5QuickOpen listParser: parser error: NULL], @"clobbered QO must be declined");

	NSUInteger reads = 0;
	NSArray<TSSTXADArchiveEntry *> *entries = [self listPath: clone source: NULL reads: &reads];
	NSArray<TSSTXADArchiveEntry *> *reference = [self listPath: original source: NULL reads: NULL];
	XCTAssertEqual(entries.count, reference.count);
	XCTAssertGreaterThan(reads, 4u, @"fallback should have walked the headers");
	for (NSUInteger i = 0; i < MIN(entries.count, reference.count); i++) {
		XCTAssertEqualObjects(entries[i].name, reference[i].name);
	}
}

/// Encrypted RAR (rarzoo) on a
/// simulated Wi-Fi link: with no password available the parse must finish
/// (no hang, no prompt loop) and report what it can -- names for
/// content-only encryption, a clean failure for encrypted headers -- and
/// with the right one every entry must extract.
- (void)testEncryptedRARWithoutAndWithPasswordOverWifiLink
{
	NSDictionary<NSString *, NSNumber *> *cases = @{@"jj-rar4-enccontent.cbr": @YES, @"jj-rar5-enccontent.cbr": @YES, @"jj-rar4-encheaders.cbr": @NO, @"jj-rar5-encheaders.cbr": @NO};
	for (NSString *name in cases) {
		TSSTRequireFixture(url, name);
		BOOL namesVisible = cases[name].boolValue;
		for (NSString *password in @[@"", @"TESTPW"]) {
			id<TSSTArchiveByteSource> file = [TSSTFileByteSource sourceWithFileURL: url error: NULL];
			TSSTSimulatedLinkByteSource *link = [TSSTSimulatedLinkByteSource smbWifiLinkWrapping: file];
			link.simulateTime = NO;
			__block NSUInteger prompts = 0;
			TSSTXADArchiveSource *source = [[TSSTXADArchiveSource alloc] initWithByteSource: link name: url.path path: url.path password: password.length ? password : nil
																			passwordProvider: ^NSString *(NSString *path, NSString *known) { prompts++; return nil; } error: NULL];
			XCTAssertNotNil(source, @"%@", name);
			NSMutableArray<TSSTXADArchiveEntry *> *entries = [NSMutableArray array];
			XCTestExpectation *done = [self expectationWithDescription: name];
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
				[source parseWithEntryBatchHandler: ^(NSArray<TSSTXADArchiveEntry *> *batch, BOOL isFinal, NSError *error) { [entries addObjectsFromArray: batch]; }];
				[done fulfill];
			});
			[self waitForExpectations: @[done] timeout: 30];
			if (password.length) {
				XCTAssertEqual(entries.count, (NSUInteger)6, @"%@ with password", name);
				XCTAssertEqual(prompts, (NSUInteger)0);
				for (TSSTXADArchiveEntry *entry in entries) {
					NSData *data = [source dataForEntry: entry.index error: NULL];
					XCTAssertEqual(data.length, (NSUInteger)entry.size, @"%@ %@", name, entry.name);
				}
			} else {
				XCTAssertLessThanOrEqual(prompts, (NSUInteger)2, @"%@ asks for a password repeatedly", name);
				if (namesVisible) { XCTAssertEqual(entries.count, (NSUInteger)6, @"%@ lists names without a password", name); }
				else { XCTAssertEqual(entries.count, (NSUInteger)0, @"%@ has nothing to list without the password", name); }
			}
		}
	}
}

@end
