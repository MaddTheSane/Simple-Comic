//
//  TSSTArchiveStreamingTests.m
//  OCR Unit Tests
//
//  Verifies TSSTCachingByteSource (correctness, no-double-fetch,
//  budget/eviction, invalidate) and TSSTArchiveStreamer (fills the
//  cache in reading order, preemption by demand reads, and a
//  page-at-a-time reading simulation over a wifi-like link).
//

#import <XCTest/XCTest.h>
#import "TSSTArchiveByteSource.h"
#import "TSSTCachingByteSource.h"
#import "TSSTArchiveStreamer.h"
#import "TSSTZipIndex.h"
#import "TSSTPageDecodeCache.h"

@interface TSSTArchiveStreamingTests : XCTestCase
@property (nonatomic, copy) NSString *tempDir;
@end

@implementation TSSTArchiveStreamingTests

- (void)setUp
{
	[super setUp];
	NSString *base = NSTemporaryDirectory();
	self.tempDir = [base stringByAppendingPathComponent: [NSString stringWithFormat: @"TSSTArchiveStreamingTests-%@", [[NSUUID UUID] UUIDString]]];
	[[NSFileManager defaultManager] createDirectoryAtPath: self.tempDir withIntermediateDirectories: YES attributes: nil error: NULL];
}

- (void)tearDown
{
	[[NSFileManager defaultManager] removeItemAtPath: self.tempDir error: NULL];
	[super tearDown];
}

#pragma mark - Helpers

- (NSString *)pathForName:(NSString *)name
{
	return [self.tempDir stringByAppendingPathComponent: name];
}

/// Builds a file of `length` bytes of incompressible random data.
- (NSString *)buildRandomFileNamed:(NSString *)name length:(NSUInteger)length
{
	NSString *path = [self pathForName: name];
	NSMutableData *data = [NSMutableData dataWithLength: length];
	int fd = open("/dev/urandom", O_RDONLY);
	read(fd, data.mutableBytes, length);
	close(fd);
	[data writeToFile: path atomically: YES];
	return path;
}

- (int)runTask:(NSString *)launchPath arguments:(NSArray<NSString *> *)args inDirectory:(NSString *)dir
{
	NSTask *task = [[NSTask alloc] init];
	task.launchPath = launchPath;
	task.arguments = args;
	task.currentDirectoryPath = dir;
	task.standardOutput = [NSPipe pipe];
	[task launch];
	[task waitUntilExit];
	return task.terminationStatus;
}

/// Builds a zip with `count` random, incompressible entries (50-300 KB)
/// and returns its path.
- (NSString *)buildZipNamed:(NSString *)zipName withEntryCount:(NSUInteger)count
{
	NSString *srcDir = [self.tempDir stringByAppendingPathComponent: [zipName stringByAppendingString: @"-src"]];
	[[NSFileManager defaultManager] createDirectoryAtPath: srcDir withIntermediateDirectories: YES attributes: nil error: NULL];
	srand(42);
	for (NSUInteger i = 0; i < count; ++i)
	{
		NSString *name = [NSString stringWithFormat: @"entry-%05lu.bin", (unsigned long)i];
		NSUInteger size = 50 * 1024 + (arc4random_uniform(250 * 1024));
		NSMutableData *data = [NSMutableData dataWithLength: size];
		int fd = open("/dev/urandom", O_RDONLY);
		read(fd, data.mutableBytes, size);
		close(fd);
		[data writeToFile: [srcDir stringByAppendingPathComponent: name] atomically: YES];
	}
	NSString *zipPath = [self pathForName: zipName];
	int status = [self runTask: @"/usr/bin/zip" arguments: @[@"-r", @"-q", zipPath, @"."] inDirectory: srcDir];
	XCTAssertEqual(status, 0);
	return zipPath;
}

#pragma mark - Caching correctness

- (void)testCachingSourceParityWithRandomReads
{
	NSString *path = [self buildRandomFileNamed: @"parity.bin" length: 2 * 1024 * 1024 + 12345];
	NSError *error = nil;
	TSSTFileByteSource *upstream = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: &error];
	XCTAssertNotNil(upstream, @"%@", error);

	TSSTCachingByteSource *cache = [[TSSTCachingByteSource alloc] initWithUpstream: upstream];
	cache.maxCacheBytes = upstream.length; // no eviction for this test

	srand(7);
	for (int i = 0; i < 1000; ++i)
	{
		uint64_t maxOffset = upstream.length > 0 ? upstream.length - 1 : 0;
		uint64_t offset = maxOffset > 0 ? (uint64_t)(rand() % (int)maxOffset) : 0;
		NSUInteger length = 1 + (NSUInteger)(rand() % (256 * 1024));
		// occasionally force crossing a block boundary or EOF
		if (i % 7 == 0) { offset = (offset / TSSTCachingByteSourceBlockSize) * TSSTCachingByteSourceBlockSize - 4; }
		if (i % 11 == 0) { offset = upstream.length > 2048 ? upstream.length - 2048 : 0; length = 4096; }

		NSError *e1 = nil, *e2 = nil;
		NSData *fromCache = [cache readAtOffset: offset length: length error: &e1];
		NSData *fromUpstream = [upstream readAtOffset: offset length: length error: &e2];
		XCTAssertEqualObjects(fromCache, fromUpstream, @"mismatch at offset %llu length %lu", offset, (unsigned long)length);
	}
	[cache invalidate];
}

- (void)testNoDoubleFetchOnRepeatRead
{
	NSString *path = [self buildRandomFileNamed: @"nodupe.bin" length: 1024 * 1024];
	NSError *error = nil;
	TSSTFileByteSource *fileSource = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: &error];
	TSSTSimulatedLinkByteSource *link = [TSSTSimulatedLinkByteSource lanLinkWrapping: fileSource];
	link.simulateTime = NO;

	TSSTCachingByteSource *cache = [[TSSTCachingByteSource alloc] initWithUpstream: link];
	cache.maxCacheBytes = link.length;

	NSData *first = [cache readAtOffset: 10000 length: 50000 error: &error];
	XCTAssertNotNil(first);
	uint64_t bytesAfterFirst = link.bytesRead;
	XCTAssertGreaterThan(bytesAfterFirst, (uint64_t)0);

	NSData *second = [cache readAtOffset: 10000 length: 50000 error: &error];
	XCTAssertEqualObjects(first, second);
	XCTAssertEqual(link.bytesRead, bytesAfterFirst, @"re-reading a cached range should not touch upstream again");
	[cache invalidate];
}

- (void)testConcurrentDemandReadsFetchEachBlockOnce
{
	NSString *path = [self buildRandomFileNamed: @"concurrent.bin" length: 2 * 1024 * 1024];
	NSError *error = nil;
	TSSTFileByteSource *fileSource = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: &error];
	TSSTSimulatedLinkByteSource *link = [TSSTSimulatedLinkByteSource smbWifiLinkWrapping: fileSource];
	link.simulateTime = NO;

	TSSTCachingByteSource *cache = [[TSSTCachingByteSource alloc] initWithUpstream: link];
	cache.maxCacheBytes = link.length;

	NSUInteger rangeLength = 300 * 1024; // spans multiple 256 KB blocks
	dispatch_group_t group = dispatch_group_create();
	dispatch_queue_t concurrentQueue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
	for (int i = 0; i < 8; ++i)
	{
		dispatch_group_async(group, concurrentQueue, ^{
			NSError *readError = nil;
			[cache readAtOffset: 0 length: rangeLength error: &readError];
		});
	}
	dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

	NSUInteger expectedBlocks = (rangeLength + TSSTCachingByteSourceBlockSize - 1) / TSSTCachingByteSourceBlockSize;
	uint64_t expectedBytes = expectedBlocks * TSSTCachingByteSourceBlockSize;
	// Contiguous blocks are coalesced into one upstream read, so readCount
	// can be fewer than expectedBlocks; what matters is each byte is only
	// ever fetched once, not once per thread.
	XCTAssertLessThanOrEqual(link.readCount, expectedBlocks);
	XCTAssertEqual(link.bytesRead, expectedBytes, @"each block's bytes should be fetched exactly once across 8 threads");
	[cache invalidate];
}

#pragma mark - Streamer

- (void)testStreamerFillsEverythingOverTimelessLink
{
	NSString *path = [self buildRandomFileNamed: @"streamfill.bin" length: 4 * 1024 * 1024];
	NSError *error = nil;
	TSSTFileByteSource *fileSource = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: &error];
	TSSTSimulatedLinkByteSource *link = [TSSTSimulatedLinkByteSource lanLinkWrapping: fileSource];
	link.simulateTime = NO;
	link.logsRequests = YES;

	TSSTCachingByteSource *cache = [[TSSTCachingByteSource alloc] initWithUpstream: link];
	cache.maxCacheBytes = link.length;

	NSMutableArray<NSValue *> *spans = [NSMutableArray array];
	NSUInteger spanSize = 150 * 1024;
	for (uint64_t offset = 0; offset < fileSource.length; offset += spanSize)
	{
		NSUInteger len = (NSUInteger)MIN((uint64_t)spanSize, fileSource.length - offset);
		[spans addObject: [NSValue valueWithRange: NSMakeRange((NSUInteger)offset, len)]];
	}

	TSSTArchiveStreamer *streamer = [[TSSTArchiveStreamer alloc] initWithCachingByteSource: cache spans: spans];
	XCTestExpectation *complete = [self expectationWithDescription: @"streamer completes"];
	streamer.progressHandler = ^(NSIndexSet *cachedSpanIndexes, double cachedFraction, double throughput, BOOL isComplete) {
		if (isComplete) { [complete fulfill]; }
	};
	[streamer start];
	[self waitForExpectations: @[complete] timeout: 20.0];
	XCTAssertTrue(streamer.isComplete);

	uint64_t bytesBefore = link.bytesRead;
	for (NSValue *span in spans)
	{
		NSRange r = span.rangeValue;
		NSError *e = nil;
		NSData *d = [cache readAtOffset: r.location length: r.length error: &e];
		XCTAssertEqual(d.length, (NSUInteger)r.length);
	}
	XCTAssertEqual(link.bytesRead, bytesBefore, @"reading every span after completion should add 0 upstream bytes");

	// First upstream reads should cover the spans from currentSpanIndex (0) forward.
	NSArray<NSValue *> *log = link.requestLog;
	XCTAssertGreaterThan(log.count, (NSUInteger)0);
	NSRange firstRequest = log.firstObject.rangeValue;
	XCTAssertEqual(firstRequest.location, (NSUInteger)0);

	[cache invalidate];
}

- (void)testPreemptionDemandBeatsPrefetch
{
	NSString *path = [self buildRandomFileNamed: @"preempt.bin" length: 6 * 1024 * 1024];
	NSError *error = nil;
	TSSTFileByteSource *fileSource = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: &error];
	// Scaled-down wifi-like link: real time, but faster than the real profile so the test runs quickly.
	NSTimeInterval latency = 0.010;
	double bytesPerSecond = 2.0 * 1024 * 1024;
	TSSTSimulatedLinkByteSource *link = [[TSSTSimulatedLinkByteSource alloc] initWithByteSource: fileSource latency: latency bytesPerSecond: bytesPerSecond];
	link.simulateTime = YES;

	TSSTCachingByteSource *cache = [[TSSTCachingByteSource alloc] initWithUpstream: link];
	cache.maxCacheBytes = link.length;

	NSMutableArray<NSValue *> *spans = [NSMutableArray array];
	NSUInteger spanSize = 150 * 1024;
	for (uint64_t offset = 0; offset < fileSource.length; offset += spanSize)
	{
		NSUInteger len = (NSUInteger)MIN((uint64_t)spanSize, fileSource.length - offset);
		[spans addObject: [NSValue valueWithRange: NSMakeRange((NSUInteger)offset, len)]];
	}
	NSUInteger farIndex = spans.count - 1;

	TSSTArchiveStreamer *streamer = [[TSSTArchiveStreamer alloc] initWithCachingByteSource: cache spans: spans];
	[streamer start];
	usleep(20000); // let the streamer get going near span 0

	[streamer prioritizeSpanIndex: farIndex];

	NSRange farSpan = spans[farIndex].rangeValue;
	NSDate *start = [NSDate date];
	NSError *demandError = nil;
	NSData *demandData = [cache readAtOffset: farSpan.location length: farSpan.length error: &demandError];
	NSTimeInterval elapsed = -[start timeIntervalSinceNow];
	XCTAssertEqual(demandData.length, (NSUInteger)farSpan.length);

	NSTimeInterval chunkTime = 0.25; // adaptive chunk target
	NSTimeInterval spanTransferTime = latency + (double)farSpan.length / bytesPerSecond;
	NSTimeInterval bound = (latency + chunkTime + spanTransferTime) * 1.5;
	XCTAssertLessThanOrEqual(elapsed, bound, @"demand read should not wait for more than ~one streamer chunk");

	[streamer cancel];
	[cache invalidate];
}

- (void)testBudgetKeepsBlocksNearFocus
{
	NSString *path = [self buildRandomFileNamed: @"budget.bin" length: 3 * 1024 * 1024];
	NSError *error = nil;
	TSSTFileByteSource *fileSource = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: &error];
	TSSTSimulatedLinkByteSource *link = [TSSTSimulatedLinkByteSource lanLinkWrapping: fileSource];
	link.simulateTime = NO;

	TSSTCachingByteSource *cache = [[TSSTCachingByteSource alloc] initWithUpstream: link];
	uint64_t budget = (uint64_t)(0.3 * (double)fileSource.length);
	cache.maxCacheBytes = budget;
	cache.focusOffset = fileSource.length - 1; // focus near the end

	// Fetch the whole file in order; eviction should keep blocks near focus (the end).
	NSUInteger chunk = 128 * 1024;
	for (uint64_t offset = 0; offset < fileSource.length; offset += chunk)
	{
		NSUInteger len = (NSUInteger)MIN((uint64_t)chunk, fileSource.length - offset);
		cache.focusOffset = offset; // move focus along as we go, ending at the tail
		[cache prefetchAtOffset: offset length: len error: NULL];
	}

	uint64_t maxAllowed = budget + TSSTCachingByteSourceBlockSize;
	XCTAssertLessThanOrEqual(cache.cachedByteCount, maxAllowed);

	// The tail (last focus point) should still be cached.
	XCTAssertTrue([cache isRangeCachedAtOffset: fileSource.length - 4096 length: 4096]);
	[cache invalidate];
}

- (void)testInvalidateRemovesTempDirectory
{
	NSString *path = [self buildRandomFileNamed: @"inval.bin" length: 65536];
	NSError *error = nil;
	TSSTFileByteSource *fileSource = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: &error];
	TSSTCachingByteSource *cache = [[TSSTCachingByteSource alloc] initWithUpstream: fileSource];
	[cache readAtOffset: 0 length: 100 error: &error];

	// Find the cache dir by reading a private path convention -- inspect temp dir listing before/after.
	NSFileManager *fm = [NSFileManager defaultManager];
	NSArray<NSString *> *before = [fm contentsOfDirectoryAtPath: NSTemporaryDirectory() error: NULL];
	NSArray<NSString *> *cacheDirsBefore = [before filteredArrayUsingPredicate: [NSPredicate predicateWithFormat: @"SELF BEGINSWITH 'SimpleComic-cache-'"]];
	XCTAssertGreaterThanOrEqual(cacheDirsBefore.count, (NSUInteger)1);

	[cache invalidate];

	NSArray<NSString *> *after = [fm contentsOfDirectoryAtPath: NSTemporaryDirectory() error: NULL];
	NSArray<NSString *> *cacheDirsAfter = [after filteredArrayUsingPredicate: [NSPredicate predicateWithFormat: @"SELF BEGINSWITH 'SimpleComic-cache-'"]];
	XCTAssertEqual(cacheDirsAfter.count, cacheDirsBefore.count - 1);
}

#pragma mark - Zip end-to-end

- (void)testZipIndexOverCachingSourceMatchesPlainFileSource
{
	NSString *zipPath = [self buildZipNamed: @"streaming.zip" withEntryCount: 12];

	NSError *error = nil;
	TSSTZipIndex *plainIndex = [TSSTZipIndex indexWithFileURL: [NSURL fileURLWithPath: zipPath] error: &error];
	XCTAssertNotNil(plainIndex, @"%@", error);

	TSSTFileByteSource *fileSource = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: zipPath] error: &error];
	TSSTSimulatedLinkByteSource *link = [TSSTSimulatedLinkByteSource smbWifiLinkWrapping: fileSource];
	link.simulateTime = NO;
	TSSTCachingByteSource *cache = [[TSSTCachingByteSource alloc] initWithUpstream: link];
	cache.maxCacheBytes = link.length;

	TSSTZipIndex *cachedIndex = [TSSTZipIndex indexWithByteSource: cache error: &error];
	XCTAssertNotNil(cachedIndex, @"%@", error);
	XCTAssertEqual(cachedIndex.numberOfEntries, plainIndex.numberOfEntries);

	NSMutableArray<NSNumber *> *entryIndices = [NSMutableArray array];
	for (NSUInteger i = 0; i < cachedIndex.numberOfEntries; ++i)
	{
		XCTAssertEqualObjects([cachedIndex nameOfEntry: i], [plainIndex nameOfEntry: i]);
		NSData *plainData = [plainIndex contentsOfEntry: i error: &error];
		NSData *cachedData = [cachedIndex contentsOfEntry: i error: &error];
		XCTAssertEqualObjects(plainData, cachedData, @"entry %lu content mismatch", (unsigned long)i);
		[entryIndices addObject: @(i)];
	}

	NSArray<NSValue *> *spans = [TSSTArchiveStreamer spansForZipIndex: cachedIndex entryIndices: entryIndices];
	TSSTArchiveStreamer *streamer = [[TSSTArchiveStreamer alloc] initWithCachingByteSource: cache spans: spans];
	XCTestExpectation *complete = [self expectationWithDescription: @"streamer completes"];
	streamer.progressHandler = ^(NSIndexSet *cachedSpanIndexes, double cachedFraction, double throughput, BOOL isComplete) {
		if (isComplete) { [complete fulfill]; }
	};
	[streamer start];
	[self waitForExpectations: @[complete] timeout: 20.0];

	uint64_t bytesBefore = link.bytesRead;
	for (NSUInteger i = 0; i < cachedIndex.numberOfEntries; ++i)
	{
		[cachedIndex contentsOfEntry: i error: &error];
	}
	XCTAssertEqual(link.bytesRead, bytesBefore, @"extracting any entry after streamer completion should cost 0 upstream reads");

	[cache invalidate];
}

#pragma mark - Reading simulation

- (void)testReadingSimulationHasNoStallsAfterPageThree
{
	NSString *path = [self buildRandomFileNamed: @"readsim.bin" length: 30 * 150 * 1024];
	NSError *error = nil;
	TSSTFileByteSource *fileSource = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: &error];
	NSTimeInterval latency = 0.010;
	double bytesPerSecond = 5.0 * 1024 * 1024;
	TSSTSimulatedLinkByteSource *link = [[TSSTSimulatedLinkByteSource alloc] initWithByteSource: fileSource latency: latency bytesPerSecond: bytesPerSecond];
	link.simulateTime = YES;

	TSSTCachingByteSource *cache = [[TSSTCachingByteSource alloc] initWithUpstream: link];
	cache.maxCacheBytes = link.length;

	NSMutableArray<NSValue *> *spans = [NSMutableArray array];
	NSUInteger pageSize = 150 * 1024;
	for (uint64_t offset = 0; offset < fileSource.length; offset += pageSize)
	{
		NSUInteger len = (NSUInteger)MIN((uint64_t)pageSize, fileSource.length - offset);
		[spans addObject: [NSValue valueWithRange: NSMakeRange((NSUInteger)offset, len)]];
	}

	TSSTArchiveStreamer *streamer = [[TSSTArchiveStreamer alloc] initWithCachingByteSource: cache spans: spans];
	[streamer start];

	NSUInteger stalls = 0;
	printf("page\tms\tstall\n");
	for (NSUInteger page = 0; page < spans.count; ++page)
	{
		streamer.currentSpanIndex = page;
		NSRange span = spans[page].rangeValue;
		NSDate *start = [NSDate date];
		NSError *readError = nil;
		[cache readAtOffset: span.location length: span.length error: &readError];
		NSTimeInterval ms = -[start timeIntervalSinceNow] * 1000.0;
		BOOL stall = ms > 20.0;
		if (stall && page > 3) { stalls++; }
		printf("%lu\t%.2f\t%s\n", (unsigned long)page, ms, stall ? "STALL" : "");
		usleep(100000); // 1 page / 100ms
	}
	XCTAssertEqual(stalls, (NSUInteger)0, @"expected no stalls after page 3");

	[streamer cancel];
	[cache invalidate];
}

#pragma mark - Jump ahead of the streamer

/// A span hinted past the end of the file (a zip's last entry carries slack
/// for its local header) must count as cached once the real bytes are, or
/// its page reads "uncached" forever and the streamer never finishes.
- (void)testSpanOvershootingEndOfFileCountsAsCachedAndStreamerCompletes
{
	NSString *path = [self buildRandomFileNamed: @"overshoot.bin" length: 100 * 1024 + 123];
	NSError *error = nil;
	TSSTFileByteSource *fileSource = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: &error];
	TSSTCachingByteSource *cache = [[TSSTCachingByteSource alloc] initWithUpstream: fileSource];
	cache.maxCacheBytes = fileSource.length;

	NSUInteger tailStart = 90 * 1024;
	NSArray<NSValue *> *spans = @[[NSValue valueWithRange: NSMakeRange(0, tailStart)],
								  [NSValue valueWithRange: NSMakeRange(tailStart, 50 * 1024)]]; // runs 40 KB past EOF
	XCTAssertFalse([cache isRangeCachedAtOffset: tailStart length: 50 * 1024]);

	TSSTArchiveStreamer *streamer = [[TSSTArchiveStreamer alloc] initWithCachingByteSource: cache spans: spans];
	XCTestExpectation *complete = [self expectationWithDescription: @"streamer completes"];
	streamer.progressHandler = ^(NSIndexSet *cachedSpanIndexes, double cachedFraction, double throughput, BOOL isComplete) {
		if (isComplete) { [complete fulfill]; }
	};
	[streamer start];
	[self waitForExpectations: @[complete] timeout: 10.0];
	XCTAssertTrue(streamer.isComplete);
	XCTAssertTrue([cache isRangeCachedAtOffset: tailStart length: 50 * 1024]);
	XCTAssertTrue([cache isRangeCachedAtOffset: fileSource.length + 10 length: 100], @"nothing past EOF is left to cache");
	[streamer cancel];
	[cache invalidate];
}

/// The reader jumps far ahead of the streamer's front while the streamer is
/// mid-chunk on a slow link: the demanded page arrives within about one
/// chunk, and once the reader is re-targeted there the streamer works
/// outward from the new spot (pages just past it get cached) instead of
/// carrying on from where it was.
- (void)testJumpAheadIsServedPromptlyAndStreamerFollows
{
	NSUInteger pageSize = 150 * 1024, pages = 40;
	NSString *path = [self buildRandomFileNamed: @"jump.bin" length: pages * pageSize];
	NSError *error = nil;
	TSSTFileByteSource *fileSource = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: &error];
	NSTimeInterval latency = 0.010;
	double bytesPerSecond = 1.5 * 1024 * 1024;
	TSSTSimulatedLinkByteSource *link = [[TSSTSimulatedLinkByteSource alloc] initWithByteSource: fileSource latency: latency bytesPerSecond: bytesPerSecond];
	link.simulateTime = YES;
	TSSTCachingByteSource *cache = [[TSSTCachingByteSource alloc] initWithUpstream: link];
	cache.maxCacheBytes = link.length;

	NSMutableArray<NSValue *> *spans = [NSMutableArray array];
	for (NSUInteger i = 0; i < pages; ++i) { [spans addObject: [NSValue valueWithRange: NSMakeRange(i * pageSize, pageSize)]]; }
	TSSTArchiveStreamer *streamer = [[TSSTArchiveStreamer alloc] initWithCachingByteSource: cache spans: spans];
	[streamer start];
	usleep(150000); // streamer is a few pages in

	NSUInteger target = 34;
	NSRange span = spans[target].rangeValue;
	__block NSTimeInterval elapsed = 0;
	__block NSUInteger got = 0;
	XCTestExpectation *demanded = [self expectationWithDescription: @"demand read returns"];
	NSDate *start = [NSDate date];
	// The reader's thread: mark the page as wanted, then read it, as a page load does.
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		streamer.currentSpanIndex = target;
		NSData *d = [cache readAtOffset: span.location length: span.length error: NULL];
		got = d.length;
		elapsed = -[start timeIntervalSinceNow];
		[demanded fulfill];
	});
	[self waitForExpectations: @[demanded] timeout: 15.0];
	XCTAssertEqual(got, span.length);
	NSTimeInterval spanTime = latency + (double)span.length / bytesPerSecond;
	XCTAssertLessThanOrEqual(elapsed, (spanTime + 0.25 + latency) * 2.0 + 0.3, @"a jump must not wait for the streamer to arrive");

	// The streamer follows the reader: the next pages fill in soon after.
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: 3.0];
	while ([deadline timeIntervalSinceNow] > 0 && ![cache isRangeCachedAtOffset: spans[target + 2].rangeValue.location length: pageSize])
	{
		usleep(10000);
	}
	XCTAssertTrue([cache isRangeCachedAtOffset: spans[target + 2].rangeValue.location length: pageSize], @"streamer should carry on from the jumped-to page");
	[streamer cancel];
	[cache invalidate];
}

/// However often the reader is re-targeted mid-stream (jumps, drags), the
/// streamer keeps going until every span is cached, and the progress handler
/// ends with a complete=YES report naming every span -- so a UI driven by
/// those reports can never be left showing a stale, partial set.
- (void)testRepeatedRetargetsStillCompleteAndFinalReportIsComplete
{
	NSUInteger pageSize = 150 * 1024, pages = 120;
	NSString *path = [self buildRandomFileNamed: @"retarget.bin" length: pages * pageSize];
	NSError *error = nil;
	TSSTFileByteSource *fileSource = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: &error];
	TSSTSimulatedLinkByteSource *link = [[TSSTSimulatedLinkByteSource alloc] initWithByteSource: fileSource latency: 0.002 bytesPerSecond: 20.0 * 1024 * 1024];
	link.simulateTime = YES;
	TSSTCachingByteSource *cache = [[TSSTCachingByteSource alloc] initWithUpstream: link];
	cache.maxCacheBytes = link.length;
	NSMutableArray<NSValue *> *spans = [NSMutableArray array];
	for (NSUInteger i = 0; i < pages; ++i) { [spans addObject: [NSValue valueWithRange: NSMakeRange(i * pageSize, pageSize)]]; }

	TSSTArchiveStreamer *streamer = [[TSSTArchiveStreamer alloc] initWithCachingByteSource: cache spans: spans];
	XCTestExpectation *finished = [self expectationWithDescription: @"final complete report"];
	__block NSIndexSet *lastSet = nil;
	__block BOOL lastComplete = NO, sawCompleteTwice = NO;
	streamer.progressHandler = ^(NSIndexSet *cachedSpans, double fraction, double throughput, BOOL complete) {
		// Delivered on the main queue, in order.
		if (lastComplete && complete) { sawCompleteTwice = YES; }
		lastSet = cachedSpans;
		lastComplete = complete;
		if (complete) { [finished fulfill]; }
	};
	[streamer start];

	// A reader who jumps around (including mid-chunk and back to an already
	// cached page) while the streamer works.
	NSUInteger targets[] = { 90, 40, 3, 110, 40, 41, 7, 119, 0, 60 };
	for (NSUInteger i = 0; i < sizeof(targets) / sizeof(targets[0]); ++i)
	{
		streamer.currentSpanIndex = targets[i];
		usleep(20000);
	}

	[self waitForExpectations: @[finished] timeout: 30.0];
	XCTAssertTrue(streamer.isComplete);
	XCTAssertTrue(lastComplete, @"the last report is the complete one");
	XCTAssertFalse(sawCompleteTwice, @"completion is reported once");
	XCTAssertEqual(lastSet.count, pages);
	XCTAssertTrue([lastSet containsIndexesInRange: NSMakeRange(0, pages)], @"the final report names every cached span");
	[streamer cancel];
	[cache invalidate];
}

/// Work for a generation the reader has already left is skipped instead of
/// running (and fetching its page) ahead of the page they stopped on.
- (void)testDecodeQueueSkipsStaleWorkAheadOfCurrentWork
{
	TSSTPageDecodeCache *decodeCache = [TSSTPageDecodeCache new];
	dispatch_semaphore_t release = dispatch_semaphore_create(0);
	// Something slow already on the queue, as a page still on the network would be.
	dispatch_async(decodeCache.decodeQueue, ^{ dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER); });

	__block NSInteger staleRuns = 0, currentRuns = 0;
	__block BOOL staleCompletionRan = YES, currentCompletionRan = NO;
	XCTestExpectation *done = [self expectationWithDescription: @"both completions"];
	done.expectedFulfillmentCount = 2;
	__block BOOL current = YES;
	[decodeCache runOnDecodeQueueWhileCurrent: ^BOOL{ return current; } work: ^{ staleRuns++; } completion: ^(BOOL ran) { staleCompletionRan = ran; [done fulfill]; }];
	[decodeCache runOnDecodeQueueWhileCurrent: ^BOOL{ return YES; } work: ^{ currentRuns++; } completion: ^(BOOL ran) { currentCompletionRan = ran; [done fulfill]; }];
	current = NO; // the reader moves on while the first load is still blocked
	dispatch_semaphore_signal(release);
	[self waitForExpectations: @[done] timeout: 5.0];

	XCTAssertEqual(staleRuns, 0);
	XCTAssertFalse(staleCompletionRan);
	XCTAssertEqual(currentRuns, 1);
	XCTAssertTrue(currentCompletionRan);
}

@end
