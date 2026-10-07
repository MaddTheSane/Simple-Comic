//
//  TSSTPublicDomainStreamingTests.m
//  OCR Unit Tests
//
//  Per-format streaming tests on the public-domain Jessie James comic
//  (zip, RAR4, RAR5, and a 7z built from its pages), so the committed
//  suite exercises every backend without any copyrighted comic. Each test
//  runs the production stack (backend -> caching source -> simulated
//  Wi-Fi link) in timeless mode and asserts:
//    - listing costs a handful of link reads (never one per page), and
//    - once the streamer has filled the cache, reading every page costs
//      zero further link reads (nothing left to stall on).
//  The tests that used SC_TEST_COMICS_DIR remain as optional extras.
//

#import <XCTest/XCTest.h>
#import <XADMaster/XADArchive.h>
#import "TSSTTestFixtures.h"
#import "TSSTZipIndex.h"
#import "TSSTXADArchiveSource.h"
#import "TSSTArchiveByteSource.h"
#import "TSSTCachingByteSource.h"
#import "TSSTArchiveStreamer.h"

@interface TSSTPublicDomainStreamingTests : XCTestCase
@property (nonatomic, copy) NSString *tempDir;
@end

@implementation TSSTPublicDomainStreamingTests

- (void)setUp
{
	[super setUp];
	self.tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent: [NSString stringWithFormat: @"TSSTPublicDomainStreamingTests-%@", [[NSUUID UUID] UUIDString]]];
	[[NSFileManager defaultManager] createDirectoryAtPath: self.tempDir withIntermediateDirectories: YES attributes: nil error: NULL];
}

- (void)tearDown
{
	[[NSFileManager defaultManager] removeItemAtPath: self.tempDir error: NULL];
	[super tearDown];
}

#pragma mark - Helpers

/// file -> timeless Wi-Fi link -> caching source, as the app builds it.
- (TSSTCachingByteSource *)cacheOverWifiLinkForURL:(NSURL *)url link:(TSSTSimulatedLinkByteSource * _Nullable * _Nonnull)linkOut
{
	NSError *error = nil;
	id<TSSTArchiveByteSource> file = [TSSTFileByteSource sourceWithFileURL: url error: &error];
	XCTAssertNotNil(file, @"%@", error);
	TSSTSimulatedLinkByteSource *link = [TSSTSimulatedLinkByteSource smbWifiLinkWrapping: file];
	link.simulateTime = NO;
	*linkOut = link;
	return [[TSSTCachingByteSource alloc] initWithUpstream: link];
}

/// Runs the streamer to completion, then reads every page and asserts the
/// link saw no read while doing so (each page was already cached).
- (void)assertNoStallsAfterStreaming:(TSSTCachingByteSource *)cache
								link:(TSSTSimulatedLinkByteSource *)link
							   spans:(NSArray<NSValue *> *)spans
							   count:(NSUInteger)count
							readPage:(NSData *(^)(NSUInteger))readPage
							   label:(NSString *)label
{
	XCTAssertGreaterThan(spans.count, 0u, @"%@: need spans", label);
	TSSTArchiveStreamer *streamer = [[TSSTArchiveStreamer alloc] initWithCachingByteSource: cache spans: spans];
	[streamer start];
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: 60];
	while (!streamer.isComplete && [deadline timeIntervalSinceNow] > 0) { usleep(10000); }
	XCTAssertTrue(streamer.isComplete, @"%@: streamer should fill the cache", label);
	[streamer cancel];

	NSUInteger readsBefore = link.readCount;
	NSTimeInterval simBefore = link.simulatedElapsed;
	for (NSUInteger i = 0; i < count; ++i)
	{
		NSData *page = readPage(i);
		XCTAssertGreaterThan(page.length, 0u, @"%@: page %lu", label, (unsigned long)i);
	}
	NSLog(@"[fast-open][%@] streamed %lu spans; reading all %lu pages afterwards cost %lu link reads / %.3fs",
		  label, (unsigned long)spans.count, (unsigned long)count, (unsigned long)(link.readCount - readsBefore), link.simulatedElapsed - simBefore);
	XCTAssertEqual(link.readCount, readsBefore, @"%@: reading cached pages must not touch the link (a stall)", label);
	XCTAssertEqual(link.simulatedElapsed, simBefore, @"%@: no simulated wait while paging", label);
}

- (NSUInteger)imageEntryCountInZipIndex:(TSSTZipIndex *)index
{
	NSUInteger n = 0;
	for (NSUInteger i = 0; i < index.numberOfEntries; ++i) { if (![index entryIsDirectory: i]) ++n; }
	return n;
}

#pragma mark - Zip

- (void)testZipListsInFewReadsAndStreamsWithoutStalls
{
	NSURL *cbz = [TSSTTestFixtures jessieJamesCBZ];
	XCTSkipUnless(cbz != nil, @"Jessie James cbz fixture missing");
	TSSTSimulatedLinkByteSource *link = nil;
	TSSTCachingByteSource *cache = [self cacheOverWifiLinkForURL: cbz link: &link];
	TSSTZipIndex *index = [TSSTZipIndex indexWithByteSource: cache error: NULL];
	XCTAssertNotNil(index);
	XCTAssertEqual(index.numberOfEntries, 36u);
	NSLog(@"[fast-open][zip] listed %lu entries in %lu reads / %.3fs simulated", (unsigned long)index.numberOfEntries, (unsigned long)link.readCount, link.simulatedElapsed);
	XCTAssertLessThanOrEqual(link.readCount, 3u, @"a zip lists with the tail read and the central directory");

	NSMutableArray<NSNumber *> *order = [NSMutableArray array];
	for (NSUInteger i = 0; i < index.numberOfEntries; ++i) { [order addObject: @(i)]; }
	NSArray<NSValue *> *spans = [TSSTArchiveStreamer spansForZipIndex: index entryIndices: order];
	[self assertNoStallsAfterStreaming: cache link: link spans: spans count: index.numberOfEntries
							  readPage: ^NSData *(NSUInteger i) { return [index contentsOfEntry: i error: NULL]; }
								 label: @"zip"];
}

/// The zip index agrees with XADArchive on names, order and bytes.
- (void)testZipMatchesXADOnRealPages
{
	NSURL *cbz = [TSSTTestFixtures jessieJamesCBZ];
	XCTSkipUnless(cbz != nil, @"Jessie James cbz fixture missing");
	TSSTZipIndex *index = [TSSTZipIndex indexWithFileURL: cbz error: NULL];
	XADArchive *xad = [[XADArchive alloc] initWithFileURL: cbz delegate: nil error: NULL];
	XCTAssertNotNil(index);
	XCTAssertNotNil(xad);
	XCTAssertEqual((NSInteger)index.numberOfEntries, [xad numberOfEntries]);
	for (NSUInteger i = 0; i < index.numberOfEntries; i += 7)
	{
		XCTAssertEqualObjects([index nameOfEntry: i], [xad nameOfEntry: (NSInteger)i]);
		XCTAssertEqualObjects([index contentsOfEntry: i error: NULL], [xad contentsOfEntry: (NSInteger)i], @"entry %lu", (unsigned long)i);
	}
}

/// A cropped zip (first 12 pages) built with 7zz: a different writer than
/// the comic's own, listed the same way.
- (void)testCroppedZipBuiltWith7zzStreams
{
	NSString *tool = [TSSTTestFixtures sevenZipPath];
	XCTSkipUnless(tool != nil, @"7zz not installed");
	NSString *pages = [self.tempDir stringByAppendingPathComponent: @"pages"];
	NSArray<NSString *> *names = [TSSTTestFixtures extractJessieJamesPagesInto: pages count: 12];
	XCTSkipUnless(names.count == 12, @"Jessie James fixture missing");
	NSString *zipPath = [self.tempDir stringByAppendingPathComponent: @"cropped.zip"];
	NSMutableArray<NSString *> *args = [NSMutableArray arrayWithArray: @[@"a", @"-tzip", zipPath]];
	[args addObjectsFromArray: names];
	XCTAssertTrue([TSSTTestFixtures runTool: tool arguments: args inDirectory: pages]);

	TSSTSimulatedLinkByteSource *link = nil;
	TSSTCachingByteSource *cache = [self cacheOverWifiLinkForURL: [NSURL fileURLWithPath: zipPath] link: &link];
	TSSTZipIndex *index = [TSSTZipIndex indexWithByteSource: cache error: NULL];
	XCTAssertEqual(index.numberOfEntries, 12u);
	XCTAssertLessThanOrEqual(link.readCount, 3u);
	NSMutableArray<NSNumber *> *order = [NSMutableArray array];
	for (NSUInteger i = 0; i < index.numberOfEntries; ++i) { [order addObject: @(i)]; }
	[self assertNoStallsAfterStreaming: cache link: link spans: [TSSTArchiveStreamer spansForZipIndex: index entryIndices: order] count: 12
							  readPage: ^NSData *(NSUInteger i) { return [index contentsOfEntry: i error: NULL]; }
								 label: @"cropped-zip"];
}

#pragma mark - RAR / 7z (TSSTXADArchiveSource)

/// Lists \c url through file -> Wi-Fi link -> cache, returning the source
/// and every entry; read count and time-to-first-image land in the out-params.
- (nullable TSSTXADArchiveSource *)listURL:(NSURL *)url
									 cache:(TSSTCachingByteSource * _Nullable * _Nonnull)cacheOut
									  link:(TSSTSimulatedLinkByteSource * _Nullable * _Nonnull)linkOut
								   entries:(NSMutableArray<TSSTXADArchiveEntry *> *)entries
							 readsAtFirst:(NSUInteger *)readsAtFirst
{
	TSSTSimulatedLinkByteSource *link = nil;
	TSSTCachingByteSource *cache = [self cacheOverWifiLinkForURL: url link: &link];
	NSError *error = nil;
	TSSTXADArchiveSource *source = [[TSSTXADArchiveSource alloc] initWithByteSource: cache name: url.lastPathComponent path: url.path password: nil passwordProvider: nil error: &error];
	XCTAssertNotNil(source, @"%@", error);
	*cacheOut = cache;
	*linkOut = link;
	__block NSUInteger firstReads = NSNotFound;
	[source parseWithEntryBatchHandler: ^(NSArray<TSSTXADArchiveEntry *> *batch, BOOL isFinal, NSError *err) {
		if (firstReads == NSNotFound && batch.count > 0) { firstReads = link.readCount; }
		[entries addObjectsFromArray: batch];
	}];
	*readsAtFirst = firstReads;
	return source;
}

- (void)assertXADFixture:(NSURL *)url label:(NSString *)label expectedPages:(NSUInteger)expected maxListReads:(NSUInteger)maxReads
{
	TSSTCachingByteSource *cache = nil;
	TSSTSimulatedLinkByteSource *link = nil;
	NSMutableArray<TSSTXADArchiveEntry *> *entries = [NSMutableArray array];
	NSUInteger readsAtFirst = 0;
	TSSTXADArchiveSource *source = [self listURL: url cache: &cache link: &link entries: entries readsAtFirst: &readsAtFirst];
	if (!source) { return; }
	NSUInteger listReads = link.readCount;
	NSLog(@"[fast-open][%@] listed %lu entries in %lu reads / %.3fs simulated (first batch after %lu reads)",
		  label, (unsigned long)entries.count, (unsigned long)listReads, link.simulatedElapsed, (unsigned long)readsAtFirst);
	NSMutableArray<TSSTXADArchiveEntry *> *pages = [NSMutableArray array];
	for (TSSTXADArchiveEntry *entry in entries) { if (!entry.isDirectory) [pages addObject: entry]; }
	XCTAssertEqual(pages.count, expected, @"%@ page count", label);
	XCTAssertLessThanOrEqual(listReads, maxReads, @"%@: listing must cost a handful of reads, not one per page", label);
	XCTAssertLessThanOrEqual(readsAtFirst, MIN(maxReads, 3u), @"%@: the first entries arrive early", label);

	NSMutableArray<NSNumber *> *order = [NSMutableArray array];
	NSMutableDictionary<NSNumber *, TSSTXADArchiveEntry *> *byIndex = [NSMutableDictionary dictionary];
	for (TSSTXADArchiveEntry *entry in pages) { [order addObject: @(entry.index)]; byIndex[@(entry.index)] = entry; }
	NSArray<NSValue *> *spans = [TSSTArchiveStreamer spansForEntryIndices: order rangeProvider: ^BOOL(NSUInteger idx, NSRange *out) {
		TSSTXADArchiveEntry *entry = byIndex[@(idx)];
		if (!entry.hasSpanRange) { return NO; }
		*out = entry.spanRange;
		return YES;
	} spanIndexMap: NULL];
	XCTAssertEqual(spans.count, pages.count, @"%@: one byte span per non-solid entry", label);
	[self assertNoStallsAfterStreaming: cache link: link spans: spans count: pages.count
							  readPage: ^NSData *(NSUInteger i) { return [source dataForEntry: pages[i].index error: NULL]; }
								 label: label];
}

- (void)testRAR5UsesQuickOpenAndStreamsWithoutStalls
{
	TSSTRequireFixture(url, @"jessie-james-rar5.cbr");
	[self assertXADFixture: url label: @"rar5" expectedPages: 6 maxListReads: 4];
}

- (void)testRAR4ListsCheaplyAndStreamsWithoutStalls
{
	TSSTRequireFixture(url, @"jessie-james-rar4.cbr");
	// RAR4 has no Quick Open: the header walk costs about one read per entry at
	// worst (6 pages here), never a round trip per page plus its data.
	[self assertXADFixture: url label: @"rar4" expectedPages: 6 maxListReads: 10];
}

- (void)testRARBytesMatchXAD
{
	for (NSString *name in @[@"jessie-james-rar4.cbr", @"jessie-james-rar5.cbr"])
	{
		TSSTRequireFixture(url, name);
		TSSTCachingByteSource *cache = nil;
		TSSTSimulatedLinkByteSource *link = nil;
		NSMutableArray<TSSTXADArchiveEntry *> *entries = [NSMutableArray array];
		NSUInteger first = 0;
		TSSTXADArchiveSource *source = [self listURL: url cache: &cache link: &link entries: entries readsAtFirst: &first];
		XADArchive *xad = [[XADArchive alloc] initWithFileURL: url delegate: nil error: NULL];
		XCTAssertEqual((NSInteger)entries.count, [xad numberOfEntries], @"%@", url.lastPathComponent);
		for (NSUInteger i = 0; i < entries.count; i += 2)
		{
			XCTAssertEqualObjects(entries[i].name, [xad nameOfEntry: (NSInteger)i]);
			XCTAssertEqualObjects([source dataForEntry: i error: NULL], [xad contentsOfEntry: (NSInteger)i], @"%@ entry %lu", url.lastPathComponent, (unsigned long)i);
		}
	}
}

/// Non-solid 7z built from the first 12 pages: entries get byte spans, so
/// the streamer can prefetch them and paging never stalls.
- (void)test7zBuiltFromPagesGivesSpansAndStreamsWithoutStalls
{
	NSString *tool = [TSSTTestFixtures sevenZipPath];
	XCTSkipUnless(tool != nil, @"7zz not installed");
	NSString *pages = [self.tempDir stringByAppendingPathComponent: @"pages"];
	NSArray<NSString *> *names = [TSSTTestFixtures extractJessieJamesPagesInto: pages count: 12];
	XCTSkipUnless(names.count == 12, @"Jessie James fixture missing");
	NSString *archive = [self.tempDir stringByAppendingPathComponent: @"cropped.7z"];
	NSMutableArray<NSString *> *args = [NSMutableArray arrayWithArray: @[@"a", @"-t7z", @"-ms=off", @"-mx0", archive]];
	[args addObjectsFromArray: names];
	XCTAssertTrue([TSSTTestFixtures runTool: tool arguments: args inDirectory: pages]);
	[self assertXADFixture: [NSURL fileURLWithPath: archive] label: @"7z" expectedPages: 12 maxListReads: 6];
}

@end
