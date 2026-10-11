//
//  TSSTFolderStreamingTests.m
//  OCR Unit Tests
//
//  Folder-of-loose-images streaming (Phase C):
//   - TSSTFileSetByteSource: the virtual concatenation behind it, and the
//     shared streamer reading a folder in display order, one link read per
//     file, deterministically (timeless simulated link).
//   - Listing parity: the single-enumeration scan produces the same tree
//     (order, hidden files, subfolders, nested archives, symlinks) as the
//     old per-file-stat nestedFolderContents, whether applied locally or
//     as a streaming folder.
//   - The whole thing through TSSTManagedGroup under SC_SIMULATE_LINK on a
//     folder made from Jessie James pages: read counts, cache state,
//     jumping, and local folders staying untouched.
//

#import <XCTest/XCTest.h>
#import <Cocoa/Cocoa.h>
#import "TSSTTestFixtures.h"
#import "TSSTManagedGroup.h"
#import "TSSTManagedGroup+CoreDataProperties.h"
#import "TSSTPage.h"
#import "TSSTPage+CoreDataProperties.h"
#import "TSSTFileSetByteSource.h"
#import "TSSTArchiveByteSource.h"
#import "TSSTCachingByteSource.h"
#import "TSSTArchiveStreamer.h"

@interface TSSTManagedGroup (FolderStreamingTesting)
- (void)tearDownStreaming;
@end

@interface TSSTFolderStreamingTests : XCTestCase
@property (nonatomic, copy) NSString *tempDir;
@property (nonatomic, strong) NSManagedObjectContext *moc;
@end

@implementation TSSTFolderStreamingTests

- (void)setUp
{
	[super setUp];
	unsetenv("SC_SIMULATE_LINK");
	NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent: [NSString stringWithFormat: @"TSSTFolderStreamingTests-%@", [[NSUUID UUID] UUIDString]]];
	[[NSFileManager defaultManager] createDirectoryAtPath: tempDir withIntermediateDirectories: YES attributes: nil error: NULL];
	// The folder scan reports symlink-resolved paths (/var -> /private/var), and
	// -stringByStandardizingPath would strip that /private, so the tests'
	// expected path prefix must come from realpath().
	char resolved[PATH_MAX];
	self.tempDir = realpath(tempDir.fileSystemRepresentation, resolved) ? [NSString stringWithUTF8String: resolved] : tempDir;

	NSManagedObjectModel *model = [NSManagedObjectModel mergedModelFromBundles: @[[NSBundle mainBundle]]];
	NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel: model];
	NSError *error = nil;
	XCTAssertNotNil([coordinator addPersistentStoreWithType: NSInMemoryStoreType configuration: nil URL: nil options: nil error: &error], @"%@", error);
	self.moc = [[NSManagedObjectContext alloc] initWithConcurrencyType: NSMainQueueConcurrencyType];
	self.moc.persistentStoreCoordinator = coordinator;
}

- (void)tearDown
{
	unsetenv("SC_SIMULATE_LINK");
	self.moc = nil;
	[[NSFileManager defaultManager] removeItemAtPath: self.tempDir error: NULL];
	[super tearDown];
}

#pragma mark - Helpers

- (NSString *)writeFile:(NSString *)relativePath size:(NSUInteger)size seed:(uint8_t)seed
{
	NSString *path = [self.tempDir stringByAppendingPathComponent: relativePath];
	[[NSFileManager defaultManager] createDirectoryAtPath: path.stringByDeletingLastPathComponent withIntermediateDirectories: YES attributes: nil error: NULL];
	NSMutableData *data = [NSMutableData dataWithLength: size];
	uint8_t *bytes = data.mutableBytes;
	for (NSUInteger i = 0; i < size; ++i) { bytes[i] = (uint8_t)(seed + i * 31); }
	XCTAssertTrue([data writeToFile: path atomically: YES]);
	return path;
}

/// A tree exercising everything the old listing handled: natural-order
/// names, a text page, hidden files, an unknown type, subfolders, an empty
/// folder, a nested archive, and a symlink to a folder / a broken symlink.
- (NSURL *)buildMixedTree
{
	NSString *root = [self.tempDir stringByAppendingPathComponent: @"mixed"];
	[[NSFileManager defaultManager] createDirectoryAtPath: root withIntermediateDirectories: YES attributes: nil error: NULL];
	NSString *rel = @"mixed/";
	NSUInteger seed = 1;
	for (NSString *name in @[@"b.jpg", @"a.jpg", @"10.png", @"2.png", @"notes.txt", @".hidden.jpg", @".DS_Store", @"readme.xyz", @"sub/1.jpg", @"sub/2.jpg", @"sub/.secret.jpg", @"sub/deep/x.gif"])
	{
		[self writeFile: [rel stringByAppendingString: name] size: 20000 + seed * 3001 seed: (uint8_t)seed];
		seed++;
	}
	[[NSFileManager defaultManager] createDirectoryAtPath: [root stringByAppendingPathComponent: @"emptydir"] withIntermediateDirectories: YES attributes: nil error: NULL];
	[[NSFileManager defaultManager] createSymbolicLinkAtPath: [root stringByAppendingPathComponent: @"linked"] withDestinationPath: @"sub" error: NULL];
	[[NSFileManager defaultManager] createSymbolicLinkAtPath: [root stringByAppendingPathComponent: @"broken"] withDestinationPath: @"nowhere" error: NULL];

	NSString *inner = [self.tempDir stringByAppendingPathComponent: @"inner-src"];
	[[NSFileManager defaultManager] createDirectoryAtPath: inner withIntermediateDirectories: YES attributes: nil error: NULL];
	[self writeFile: @"inner-src/p1.jpg" size: 30000 seed: 90];
	[self writeFile: @"inner-src/p2.jpg" size: 31000 seed: 91];
	NSArray<NSString *> *zipArguments = @[@"-q", [root stringByAppendingPathComponent: @"inner.cbz"], @"p1.jpg", @"p2.jpg"];
	XCTAssertTrue([TSSTTestFixtures runTool: @"/usr/bin/zip" arguments: zipArguments inDirectory: inner]);
	return [NSURL fileURLWithPath: root isDirectory: YES];
}

- (TSSTManagedGroup *)newFolderGroupForURL:(NSURL *)url
{
	TSSTManagedGroup *group = [NSEntityDescription insertNewObjectForEntityForName: @"ImageGroup" inManagedObjectContext: self.moc];
	group.fileURL = url;
	group.name = url.lastPathComponent;
	return group;
}

/// The old -nestedFolderContents, verbatim (per-file fileExistsAtPath:), as
/// the reference the new single-enumeration scan must match.
- (void)legacyNestedFolderContentsInto:(TSSTManagedGroup *)group
{
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSArray<NSURL *> *nestedFiles = [fileManager contentsOfDirectoryAtURL: group.fileURL includingPropertiesForKeys: nil options: (NSDirectoryEnumerationSkipsSubdirectoryDescendants | NSDirectoryEnumerationSkipsHiddenFiles) error: NULL];
	BOOL isDirectory;
	for (NSURL *path in nestedFiles)
	{
		TSSTManagedGroup *nestedDescription = nil;
		NSString *fileExtension = [[path pathExtension] lowercaseString];
		BOOL exists = [fileManager fileExistsAtPath: path.path isDirectory: &isDirectory];
		if (exists && ![[[path lastPathComponent] substringToIndex: 1] isEqualToString: @"."])
		{
			if (isDirectory)
			{
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"ImageGroup" inManagedObjectContext: self.moc];
				nestedDescription.fileURL = path;
				nestedDescription.name = path.relativePath ?: path.path;
				[self legacyNestedFolderContentsInto: nestedDescription];
			}
			else if ([[TSSTManagedArchive archiveExtensions] containsObject: fileExtension])
			{
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"Archive" inManagedObjectContext: self.moc];
				nestedDescription.fileURL = path;
				nestedDescription.name = path.relativePath ?: path.path;
				[(TSSTManagedArchive *)nestedDescription nestedArchiveContents];
			}
			else if ([[TSSTPage imageExtensions] containsObject: fileExtension])
			{
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"Image" inManagedObjectContext: self.moc];
				[nestedDescription setValue: path.path forKey: @"imagePath"];
			}
			else if ([[TSSTPage textExtensions] containsObject: fileExtension])
			{
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"Image" inManagedObjectContext: self.moc];
				[nestedDescription setValue: path.path forKey: @"imagePath"];
				[nestedDescription setValue: @YES forKey: @"text"];
			}
			if (nestedDescription) { [nestedDescription setValue: group forKey: @"group"]; }
		}
	}
}

/// Order-independent description of a group tree, paths made relative to
/// \c root; the page index is deliberately left out.
- (NSArray<NSString *> *)describeGroup:(TSSTManagedGroup *)group root:(NSString *)root indent:(NSString *)indent
{
	NSMutableArray<NSString *> *lines = [NSMutableArray array];
	for (TSSTPage *page in group.images)
	{
		[lines addObject: [NSString stringWithFormat: @"%@I %@%@", indent, [page.imagePath stringByReplacingOccurrencesOfString: root withString: @""], page.text ? @" (text)" : @""]];
	}
	for (TSSTManagedGroup *child in group.groups)
	{
		NSString *kind = [child isKindOfClass: [TSSTManagedArchive class]] ? @"A" : @"G";
		[lines addObject: [NSString stringWithFormat: @"%@%@ %@", indent, kind, [child.name stringByReplacingOccurrencesOfString: root withString: @""]]];
		[lines addObjectsFromArray: [self describeGroup: child root: root indent: [indent stringByAppendingString: @"  "]]];
	}
	return [lines sortedArrayUsingSelector: @selector(compare:)];
}

/// Every page under a group, in display order (imagePath, natural sort).
- (NSArray<TSSTPage *> *)pagesInDisplayOrder:(TSSTManagedGroup *)group
{
	return [[group.nestedImages allObjects] sortedArrayUsingComparator: ^NSComparisonResult(TSSTPage *a, TSSTPage *b) {
		return [a.imagePath compare: b.imagePath options: NSCaseInsensitiveSearch | NSNumericSearch | NSWidthInsensitiveSearch | NSForcedOrderingSearch];
	}];
}

- (void)waitForStreamerOf:(TSSTManagedGroup *)group timeout:(NSTimeInterval)timeout
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: timeout];
	while (!group.streamer.isComplete && [deadline timeIntervalSinceNow] > 0) { usleep(10000); }
	XCTAssertTrue(group.streamer.isComplete, @"the streamer should fill the folder's cache");
}

#pragma mark - TSSTFileSetByteSource

- (void)testFileSetLaysFilesOutInAlignedRangesAndReadsThemBack
{
	NSMutableArray<NSURL *> *urls = [NSMutableArray array];
	NSMutableArray<NSNumber *> *sizes = [NSMutableArray array];
	NSMutableArray<NSData *> *contents = [NSMutableArray array];
	NSArray<NSNumber *> *lengths = @[@40000, @0, @16384, @1, @70000];
	for (NSUInteger i = 0; i < lengths.count; ++i)
	{
		NSString *path = [self writeFile: [NSString stringWithFormat: @"set/f%lu.bin", (unsigned long)i] size: lengths[i].unsignedIntegerValue seed: (uint8_t)(i * 17)];
		[urls addObject: [NSURL fileURLWithPath: path]];
		[sizes addObject: lengths[i]];
		[contents addObject: [NSData dataWithContentsOfFile: path]];
	}
	TSSTFileSetByteSource *set = [[TSSTFileSetByteSource alloc] initWithFileURLs: urls sizes: sizes];
	XCTAssertEqual(set.fileCount, 5u);
	for (NSUInteger i = 0; i < 5; ++i)
	{
		NSRange range = [set rangeOfFileAtIndex: i];
		XCTAssertEqual(range.location % TSSTCachingByteSourceBlockSize, 0u, @"file %lu starts on a block boundary", (unsigned long)i);
		XCTAssertEqual(range.length, lengths[i].unsignedIntegerValue);
		if (i > 0) { XCTAssertGreaterThan(range.location, [set rangeOfFileAtIndex: i - 1].location + [set rangeOfFileAtIndex: i - 1].length - 1, @"ranges don't overlap"); }
		NSData *read = [set readAtOffset: range.location length: range.length error: NULL];
		XCTAssertEqualObjects(read, contents[i], @"file %lu bytes", (unsigned long)i);
	}
	// A read across a padding gap and into the next file: zeros, then bytes.
	NSRange first = [set rangeOfFileAtIndex: 0];
	NSRange third = [set rangeOfFileAtIndex: 2];
	NSData *span = [set readAtOffset: first.location + first.length - 4 length: 8 error: NULL];
	XCTAssertEqual(span.length, 8u);
	XCTAssertEqual(memcmp(span.bytes, (const uint8_t *)contents[0].bytes + first.length - 4, 4), 0);
	XCTAssertEqual(third.location % 16384, 0u);
	XCTAssertNil([set readAtOffset: set.length + 1 length: 4 error: NULL], @"past EOF is an error");
	XCTAssertEqual([set readAtOffset: set.length length: 4 error: NULL].length, 0u, @"exactly EOF is empty");
}

/// A file that shrank since the listing is an error, never a zero-padded page.
- (void)testShrunkFileIsAnErrorNotZeros
{
	NSString *path = [self writeFile: @"shrink/a.bin" size: 50000 seed: 3];
	TSSTFileSetByteSource *set = [[TSSTFileSetByteSource alloc] initWithFileURLs: @[[NSURL fileURLWithPath: path]] sizes: @[@50000]];
	[[NSMutableData dataWithLength: 20000] writeToFile: path atomically: YES];
	NSError *error = nil;
	XCTAssertNil([set readAtOffset: 0 length: 50000 error: &error]);
	XCTAssertNotNil(error);
}

/// The shared streamer, over a timeless simulated link, reads a set of
/// files one link read each, in natural display order (2 before 10), and
/// afterwards every file is served with zero further reads.
- (void)testStreamerReadsFilesInDisplayOrderOneReadEach
{
	NSArray<NSString *> *names = @[@"10.jpg", @"2.jpg", @"1.jpg", @"11.jpg", @"3.jpg"]; // enumeration order != display order
	NSMutableArray<NSURL *> *urls = [NSMutableArray array];
	NSMutableArray<NSNumber *> *sizes = [NSMutableArray array];
	NSMutableArray<NSData *> *contents = [NSMutableArray array];
	for (NSUInteger i = 0; i < names.count; ++i)
	{
		NSString *path = [self writeFile: [@"order/" stringByAppendingString: names[i]] size: 100000 + i * 12345 seed: (uint8_t)(i + 5)];
		[urls addObject: [NSURL fileURLWithPath: path]];
		[sizes addObject: @(100000 + i * 12345)];
		[contents addObject: [NSData dataWithContentsOfFile: path]];
	}
	TSSTFileSetByteSource *set = [[TSSTFileSetByteSource alloc] initWithFileURLs: urls sizes: sizes];
	TSSTSimulatedLinkByteSource *link = [TSSTSimulatedLinkByteSource smbWifiLinkWrapping: set];
	link.simulateTime = NO;
	link.logsRequests = YES;
	TSSTCachingByteSource *cache = [[TSSTCachingByteSource alloc] initWithUpstream: link];

	NSArray<NSNumber *> *order = [[@[@0, @1, @2, @3, @4] sortedArrayUsingComparator: ^NSComparisonResult(NSNumber *a, NSNumber *b) {
		return [names[a.unsignedIntegerValue] compare: names[b.unsignedIntegerValue] options: NSNumericSearch];
	}] copy];
	NSDictionary<NSNumber *, NSNumber *> *map = nil;
	NSArray<NSValue *> *spans = [set spansForFileIndices: order spanIndexMap: &map];
	XCTAssertEqual(spans.count, 5u);
	XCTAssertEqualObjects(map[@2], @0, @"1.jpg is the first span");
	XCTAssertEqualObjects(map[@0], @3, @"10.jpg sorts after 3.jpg");

	TSSTArchiveStreamer *streamer = [[TSSTArchiveStreamer alloc] initWithCachingByteSource: cache spans: spans];
	[streamer start];
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: 30];
	while (!streamer.isComplete && [deadline timeIntervalSinceNow] > 0) { usleep(5000); }
	XCTAssertTrue(streamer.isComplete);
	[streamer cancel];

	XCTAssertEqual(link.readCount, 5u, @"one link read per file");
	NSMutableArray<NSNumber *> *fileOrder = [NSMutableArray array];
	for (NSValue *request in link.requestLog)
	{
		NSRange r = request.rangeValue;
		for (NSUInteger f = 0; f < 5; ++f)
		{
			NSRange fr = [set rangeOfFileAtIndex: f];
			if (r.location >= fr.location && r.location < fr.location + fr.length) { [fileOrder addObject: @(f)]; }
		}
	}
	XCTAssertEqualObjects(fileOrder, order, @"files are fetched in display order");
	NSLog(@"[fast-open][folder-set] 5 files: %lu reads, %llu bytes, %.3fs simulated", (unsigned long)link.readCount, link.bytesRead, link.simulatedElapsed);

	NSUInteger reads = link.readCount;
	for (NSUInteger f = 0; f < 5; ++f)
	{
		NSRange r = [set rangeOfFileAtIndex: f];
		XCTAssertEqualObjects([cache readAtOffset: r.location length: r.length error: NULL], contents[f]);
	}
	XCTAssertEqual(link.readCount, reads, @"cached files cost no link reads");
}

#pragma mark - Listing parity

- (void)testStreamingAndLocalListingsMatchTheOldListing
{
	NSURL *root = [self buildMixedTree];
	NSString *prefix = [root.path stringByAppendingString: @"/"];

	TSSTManagedGroup *legacy = [self newFolderGroupForURL: root];
	[self legacyNestedFolderContentsInto: legacy];

	TSSTManagedGroup *local = [self newFolderGroupForURL: root];
	[local nestedFolderContents];

	TSSTManagedGroup *streaming = [self newFolderGroupForURL: root];
	NSMutableArray<NSError *> *errors = [NSMutableArray array];
	id record = [TSSTManagedGroup scanRecordForFolderURL: root name: root.lastPathComponent streaming: YES errors: errors];
	[streaming applyFolderScanRecord: record];
	XCTAssertEqual(errors.count, 0u);

	NSArray<NSString *> *expected = [self describeGroup: legacy root: prefix indent: @""];
	NSLog(@"[fast-open][folder-parity] legacy listing:\n%@", [expected componentsJoinedByString: @"\n"]);
	XCTAssertEqualObjects([self describeGroup: local root: prefix indent: @""], expected, @"local listing matches the old one");
	XCTAssertEqualObjects([self describeGroup: streaming root: prefix indent: @""], expected, @"streaming listing matches the old one");

	// Spot-check the content, so parity can't be two empty trees.
	NSString *joined = [expected componentsJoinedByString: @"\n"];
	XCTAssertTrue([joined containsString: @"I a.jpg"]);
	XCTAssertTrue([joined containsString: @"I notes.txt (text)"]);
	XCTAssertTrue([joined containsString: @"G sub"] || [joined containsString: @"G /"] || [joined containsString: @"sub"], @"subfolder present");
	XCTAssertTrue([joined containsString: @"inner.cbz"], @"nested archive present");
	XCTAssertFalse([joined containsString: @".hidden"], @"hidden files are skipped");
	XCTAssertFalse([joined containsString: @".DS_Store"]);
	XCTAssertFalse([joined containsString: @"readme.xyz"], @"unknown types are skipped");
	XCTAssertFalse([joined containsString: @"nowhere"], @"broken symlinks are skipped");
	XCTAssertTrue([joined containsString: @"linked"], @"a symlink to a folder is followed, as fileExistsAtPath: always did");

	// Same display order.
	NSArray<NSString *> *legacyOrder = [[self pagesInDisplayOrder: legacy] valueForKey: @"imagePath"];
	XCTAssertEqualObjects([[self pagesInDisplayOrder: streaming] valueForKey: @"imagePath"], legacyOrder);
	NSArray<NSString *> *topNames = [[[self pagesInDisplayOrder: streaming] valueForKey: @"imagePath"] filteredArrayUsingPredicate: [NSPredicate predicateWithFormat: @"SELF BEGINSWITH %@ AND NOT SELF CONTAINS '/sub/' AND NOT SELF CONTAINS '/linked/'", prefix]];
	NSMutableArray<NSString *> *topBase = [NSMutableArray array];
	for (NSString *p in topNames) { [topBase addObject: p.lastPathComponent]; }
	XCTAssertEqualObjects(topBase, (@[@"2.png", @"10.png", @"a.jpg", @"b.jpg", @"notes.txt"]), @"natural, case-insensitive display order");

	[streaming.streamer cancel];
}

- (void)testStreamingPagesCarryFileIndexesAndReadTheirBytes
{
	NSURL *root = [self buildMixedTree];
	TSSTManagedGroup *folder = [self newFolderGroupForURL: root];
	NSMutableArray<NSError *> *errors = [NSMutableArray array];
	[folder applyFolderScanRecord: [TSSTManagedGroup scanRecordForFolderURL: root name: @"mixed" streaming: YES errors: errors]];

	NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
	NSUInteger streamingSubfolderPages = 0;
	for (TSSTPage *page in folder.nestedImages)
	{
		if (![page.group isKindOfClass: [TSSTManagedArchive class]])
		{
			XCTAssertNotNil(page.index, @"%@ carries its file index", page.imagePath);
			[seen addObject: page.index];
			XCTAssertEqualObjects(page.pageData, [NSData dataWithContentsOfFile: page.imagePath], @"%@ reads its own bytes", page.imagePath);
			XCTAssertTrue(page.group.isStreamingArchive, @"subfolder pages route to the folder that owns the cache");
			if (page.group != folder) { streamingSubfolderPages++; }
		}
	}
	XCTAssertGreaterThan(streamingSubfolderPages, 0u);

	// A nested archive inside a streaming folder keeps its own backend.
	NSUInteger archivePages = 0;
	for (TSSTPage *page in folder.nestedImages)
	{
		if (![page.group isKindOfClass: [TSSTManagedArchive class]]) { continue; }
		XCTAssertNotNil(page.pageData, @"%@ (in a nested archive) loads", page.imagePath);
		archivePages++;
	}
	XCTAssertEqual(archivePages, 2u, @"inner.cbz has two pages");
	NSMutableSet<NSNumber *> *expected = [NSMutableSet set];
	for (NSUInteger i = 0; i < seen.count; ++i) { [expected addObject: @(i)]; }
	XCTAssertEqualObjects(seen, expected, @"indices are 0..n-1, each once");
	[folder.streamer cancel];
}

/// A restored session has page indexes but no file set (it isn't
/// persisted): pages fall back to reading their own file from disk.
- (void)testPagesStillReadAfterTheStreamingStateIsGone
{
	NSURL *root = [self buildMixedTree];
	TSSTManagedGroup *folder = [self newFolderGroupForURL: root];
	NSMutableArray<NSError *> *errors = [NSMutableArray array];
	[folder applyFolderScanRecord: [TSSTManagedGroup scanRecordForFolderURL: root name: @"mixed" streaming: YES errors: errors]];
	[folder tearDownStreaming];
	XCTAssertFalse(folder.isStreamingArchive);
	NSUInteger read = 0;
	for (TSSTPage *page in folder.nestedImages)
	{
		if ([page.group isKindOfClass: [TSSTManagedArchive class]]) { continue; }
		XCTAssertNotNil(page.index);
		XCTAssertEqualObjects(page.pageData, [NSData dataWithContentsOfFile: page.imagePath], @"%@", page.imagePath);
		read++;
	}
	XCTAssertGreaterThan(read, 5u);
}

- (void)testLocalFolderIsUntouched
{
	NSURL *root = [self buildMixedTree];
	TSSTManagedGroup *folder = [self newFolderGroupForURL: root];
	[folder nestedFolderContents];
	XCTAssertGreaterThan(folder.nestedImages.count, 0u);
	XCTAssertFalse(folder.isStreamingArchive);
	XCTAssertNil(folder.streamer);
	for (TSSTPage *page in folder.nestedImages)
	{
		if ([page.group isKindOfClass: [TSSTManagedArchive class]]) { continue; }
		XCTAssertNil(page.index, @"local folder pages keep reading from imagePath");
		XCTAssertTrue([page.group isEntryIndexCached: 0]);
		XCTAssertEqualObjects(page.pageData, [NSData dataWithContentsOfFile: page.imagePath]);
	}
	XCTAssertFalse([TSSTManagedGroup shouldUseCacheForFileURL: root], @"a local folder is not streamed");
}

#pragma mark - Through the simulated link (Jessie James pages)

- (NSURL *)jessieJamesFolderWithPages:(NSUInteger)count
{
	NSString *dir = [self.tempDir stringByAppendingPathComponent: @"jessie"];
	NSArray<NSString *> *names = [TSSTTestFixtures extractJessieJamesPagesInto: dir count: count];
	if (names.count != count) { return nil; }
	return [NSURL fileURLWithPath: dir isDirectory: YES];
}

- (void)testFolderStreamsThroughSimulatedWifiLink
{
	NSURL *folderURL = [self jessieJamesFolderWithPages: 12];
	XCTSkipUnless(folderURL != nil, @"Jessie James fixture missing");
	setenv("SC_SIMULATE_LINK", "wifi", 1);
	XCTAssertTrue([TSSTManagedGroup shouldUseCacheForFileURL: folderURL], @"SC_SIMULATE_LINK streams even a local folder");

	TSSTManagedGroup *folder = [self newFolderGroupForURL: folderURL];
	NSMutableArray<NSError *> *errors = [NSMutableArray array];
	NSDate *scanStart = [NSDate date];
	id record = [TSSTManagedGroup scanRecordForFolderURL: folderURL name: @"jessie" streaming: YES errors: errors];
	NSTimeInterval listing = -[scanStart timeIntervalSinceNow];
	[folder applyFolderScanRecord: record];
	NSLog(@"[fast-open][folder-wifi] listed 12 files in %.3fs (one simulated directory read)", listing);
	XCTAssertLessThan(listing, 0.5, @"listing is one directory read, not a read per file");

	NSArray<TSSTPage *> *pages = [self pagesInDisplayOrder: folder];
	XCTAssertEqual(pages.count, 12u);
	XCTAssertTrue(folder.isStreamingArchive);
	TSSTSimulatedLinkByteSource *link = (TSSTSimulatedLinkByteSource *)folder.cachingSourceForTesting.upstream;
	XCTAssertTrue([link isKindOfClass: [TSSTSimulatedLinkByteSource class]]);

	[self waitForStreamerOf: folder timeout: 30];
	unsigned long long total = 0;
	for (TSSTPage *page in pages) { total += [NSData dataWithContentsOfFile: page.imagePath].length; }
	NSLog(@"[fast-open][folder-wifi] streamed 12 files: %lu link reads, %llu bytes (files total %llu), %.2fs simulated", (unsigned long)link.readCount, link.bytesRead, total, link.simulatedElapsed);
	XCTAssertEqual(link.readCount, 12u, @"one link read per page file");
	XCTAssertGreaterThanOrEqual(link.bytesRead, total);
	XCTAssertLessThanOrEqual(link.bytesRead, total + 12 * TSSTCachingByteSourceBlockSize, @"only per-file block padding on top of the pages");

	NSUInteger reads = link.readCount;
	for (TSSTPage *page in pages)
	{
		XCTAssertTrue([page.group isEntryIndexCached: page.index.integerValue], @"page %@ cached", page.imagePath.lastPathComponent);
		XCTAssertEqualObjects(page.pageData, [NSData dataWithContentsOfFile: page.imagePath]);
	}
	XCTAssertEqual(link.readCount, reads, @"paging a fully streamed folder never touches the link");
}

- (void)testJumpingPrioritizesTheTargetPageAndUncachedPagesReportIt
{
	NSURL *folderURL = [self jessieJamesFolderWithPages: 12];
	XCTSkipUnless(folderURL != nil, @"Jessie James fixture missing");
	setenv("SC_SIMULATE_LINK", "wifi", 1);
	TSSTManagedGroup *folder = [self newFolderGroupForURL: folderURL];
	NSMutableArray<NSError *> *errors = [NSMutableArray array];
	[folder applyFolderScanRecord: [TSSTManagedGroup scanRecordForFolderURL: folderURL name: @"jessie" streaming: YES errors: errors]];
	NSArray<TSSTPage *> *pages = [self pagesInDisplayOrder: folder];
	TSSTPage *last = pages.lastObject;

	XCTAssertFalse([folder isEntryIndexCached: last.index.integerValue], @"the last page isn't there yet (pages arrive in reading order)");
	[folder prioritizeEntryIndex: last.index.integerValue];
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: 2.0];
	while (![folder isEntryIndexCached: last.index.integerValue] && [deadline timeIntervalSinceNow] > 0) { usleep(10000); }
	XCTAssertTrue([folder isEntryIndexCached: last.index.integerValue], @"a jump re-targets the streamer");
	XCTAssertFalse(folder.streamer.isComplete, @"and does so without finishing the whole folder first");

	// Demand-reading an uncached page still works (and moves the streamer).
	TSSTPage *middle = pages[6];
	[folder noteReadingEntryIndex: middle.index.integerValue];
	XCTAssertEqualObjects(middle.pageData, [NSData dataWithContentsOfFile: middle.imagePath]);
	[folder.streamer cancel];
}

@end
