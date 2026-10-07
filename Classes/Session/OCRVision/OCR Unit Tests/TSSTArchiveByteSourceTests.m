//
//  TSSTArchiveByteSourceTests.m
//  OCR Unit Tests
//
//  Verifies TSSTFileByteSource and TSSTSimulatedLinkByteSource in
//  isolation, then verifies that TSSTZipIndex, read through a timeless
//  simulated link, keeps its read count independent of entry count --
//  the whole point of building the zip index on the central directory
//  instead of walking local headers the way XADZipParser does.
//

#import <XCTest/XCTest.h>
#import "TSSTArchiveByteSource.h"
#import "TSSTZipIndex.h"

@interface TSSTArchiveByteSourceTests : XCTestCase
@property (nonatomic, copy) NSString *tempDir;
@end

@implementation TSSTArchiveByteSourceTests

- (void)setUp
{
	[super setUp];
	NSString *base = NSTemporaryDirectory();
	self.tempDir = [base stringByAppendingPathComponent: [NSString stringWithFormat: @"TSSTArchiveByteSourceTests-%@", [[NSUUID UUID] UUIDString]]];
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

- (int)runTask:(NSString *)launchPath arguments:(NSArray<NSString *> *)args inDirectory:(NSString *)dir
{
	NSTask *task = [[NSTask alloc] init];
	task.launchPath = launchPath;
	task.arguments = args;
	task.currentDirectoryPath = dir;
	task.standardOutput = [NSPipe pipe]; // silence
	[task launch];
	[task waitUntilExit];
	return task.terminationStatus;
}

/// Builds a zip with `count` small text entries in a fresh temp dir and
/// returns its path.
- (NSString *)buildZipNamed:(NSString *)zipName withEntryCount:(NSUInteger)count
{
	NSString *srcDir = [self.tempDir stringByAppendingPathComponent: [zipName stringByAppendingString: @"-src"]];
	[[NSFileManager defaultManager] createDirectoryAtPath: srcDir withIntermediateDirectories: YES attributes: nil error: NULL];
	for (NSUInteger i = 0; i < count; ++i)
	{
		NSString *name = [NSString stringWithFormat: @"entry-%05lu.txt", (unsigned long)i];
		NSString *contents = [NSString stringWithFormat: @"contents of entry %lu\n", (unsigned long)i];
		[contents writeToFile: [srcDir stringByAppendingPathComponent: name] atomically: YES encoding: NSUTF8StringEncoding error: NULL];
	}
	NSString *zipPath = [self pathForName: zipName];
	int status = [self runTask: @"/usr/bin/zip" arguments: @[@"-r", @"-q", zipPath, @"."] inDirectory: srcDir];
	XCTAssertEqual(status, 0);
	return zipPath;
}

#pragma mark - TSSTFileByteSource

- (void)testFileByteSourceReadsBytes
{
	NSString *path = [self pathForName: @"plain.txt"];
	NSData *content = [@"0123456789abcdef" dataUsingEncoding: NSUTF8StringEncoding];
	[content writeToFile: path atomically: YES];

	NSError *error = nil;
	TSSTFileByteSource *source = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: &error];
	XCTAssertNotNil(source, @"%@", error);
	XCTAssertEqual(source.length, (uint64_t)content.length);

	NSData *middle = [source readAtOffset: 4 length: 4 error: &error];
	XCTAssertEqualObjects(middle, [@"4567" dataUsingEncoding: NSUTF8StringEncoding]);
}

- (void)testFileByteSourceShortReadAtEOF
{
	NSString *path = [self pathForName: @"short.txt"];
	NSData *content = [@"abcdefghij" dataUsingEncoding: NSUTF8StringEncoding]; // 10 bytes
	[content writeToFile: path atomically: YES];

	NSError *error = nil;
	TSSTFileByteSource *source = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: &error];
	XCTAssertNotNil(source, @"%@", error);

	// Ask for more than is available starting near the end -- should get
	// only what's there, not an error.
	NSData *tail = [source readAtOffset: 6 length: 100 error: &error];
	XCTAssertEqualObjects(tail, [@"ghij" dataUsingEncoding: NSUTF8StringEncoding]);

	// Exactly at EOF -- zero bytes, not an error.
	NSData *atEOF = [source readAtOffset: 10 length: 5 error: &error];
	XCTAssertNotNil(atEOF);
	XCTAssertEqual(atEOF.length, (NSUInteger)0);
}

- (void)testFileByteSourceOffsetPastEOFIsError
{
	NSString *path = [self pathForName: @"tiny.txt"];
	[@"abc" writeToFile: path atomically: YES encoding: NSUTF8StringEncoding error: NULL];

	NSError *error = nil;
	TSSTFileByteSource *source = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: &error];
	XCTAssertNotNil(source, @"%@", error);

	NSData *result = [source readAtOffset: 100 length: 1 error: &error];
	XCTAssertNil(result);
	XCTAssertNotNil(error);
}

#pragma mark - TSSTSimulatedLinkByteSource (timeless mode)

- (void)testSimulatedLinkTimelessAccounting
{
	NSString *path = [self pathForName: @"link-source.bin"];
	NSMutableData *content = [NSMutableData dataWithLength: 1024 * 1024]; // 1 MB
	[content writeToFile: path atomically: YES];

	NSError *error = nil;
	TSSTFileByteSource *fileSource = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: &error];
	XCTAssertNotNil(fileSource, @"%@", error);

	TSSTSimulatedLinkByteSource *link = [TSSTSimulatedLinkByteSource lanLinkWrapping: fileSource];
	link.simulateTime = NO; // deterministic, no real sleeping
	XCTAssertEqualWithAccuracy(link.latency, 0.001, 0.0001);
	XCTAssertEqualWithAccuracy(link.bytesPerSecond, 100.0 * 1024 * 1024, 1.0);

	NSUInteger readLength = 512 * 1024; // half a MB
	NSData *data = [link readAtOffset: 0 length: readLength error: &error];
	XCTAssertEqual(data.length, readLength);
	XCTAssertEqual(link.readCount, (NSUInteger)1);
	XCTAssertEqual(link.bytesRead, (uint64_t)readLength);

	NSTimeInterval expected = 0.001 + (NSTimeInterval)readLength / (100.0 * 1024 * 1024);
	XCTAssertEqualWithAccuracy(link.simulatedElapsed, expected, 0.0001);

	[link resetCounters];
	XCTAssertEqual(link.readCount, (NSUInteger)0);
	XCTAssertEqual(link.bytesRead, (uint64_t)0);
	XCTAssertEqual(link.simulatedElapsed, (NSTimeInterval)0);
}

- (void)testSimulatedLinkProfileNames
{
	NSString *path = [self pathForName: @"profile-source.bin"];
	[[NSMutableData dataWithLength: 16] writeToFile: path atomically: YES];
	NSError *error = nil;
	TSSTFileByteSource *fileSource = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: path] error: &error];

	TSSTSimulatedLinkByteSource *lan = [TSSTSimulatedLinkByteSource linkWithProfileName: @"lan" wrapping: fileSource];
	TSSTSimulatedLinkByteSource *smb = [TSSTSimulatedLinkByteSource linkWithProfileName: @"SMB" wrapping: fileSource];
	TSSTSimulatedLinkByteSource *wifi = [TSSTSimulatedLinkByteSource linkWithProfileName: @"wifi" wrapping: fileSource];
	TSSTSimulatedLinkByteSource *bogus = [TSSTSimulatedLinkByteSource linkWithProfileName: @"carrier-pigeon" wrapping: fileSource];

	XCTAssertNotNil(lan);
	XCTAssertNotNil(smb);
	XCTAssertNotNil(wifi);
	XCTAssertNil(bogus);

	XCTAssertEqualWithAccuracy(lan.latency, 0.001, 0.0001);
	XCTAssertEqualWithAccuracy(smb.latency, 0.020, 0.0001);
	XCTAssertEqualWithAccuracy(wifi.latency, 0.040, 0.0001);
}

#pragma mark - Deterministic read counts through TSSTZipIndex

/// The whole point of building the zip index off the central directory:
/// listing cost must not grow with entry count, and reading one small
/// entry must cost exactly one read.
- (void)assertDeterministicReadCountsForEntryCount:(NSUInteger)count
{
	NSString *zipPath = [self buildZipNamed: [NSString stringWithFormat: @"det-%lu.zip", (unsigned long)count] withEntryCount: count];

	NSError *error = nil;
	TSSTFileByteSource *fileSource = [TSSTFileByteSource sourceWithFileURL: [NSURL fileURLWithPath: zipPath] error: &error];
	XCTAssertNotNil(fileSource, @"%@", error);

	TSSTSimulatedLinkByteSource *link = [TSSTSimulatedLinkByteSource lanLinkWrapping: fileSource];
	link.simulateTime = NO;

	TSSTZipIndex *index = [TSSTZipIndex indexWithByteSource: link error: &error];
	XCTAssertNotNil(index, @"%@", error);
	XCTAssertEqual(index.numberOfEntries, count);

	XCTAssertLessThanOrEqual(link.readCount, (NSUInteger)3, @"listing %lu entries took %lu reads", (unsigned long)count, (unsigned long)link.readCount);

	[link resetCounters];
	NSData *data = [index contentsOfEntry: 0 error: &error];
	XCTAssertNotNil(data, @"%@", error);
	XCTAssertEqual(link.readCount, (NSUInteger)1, @"reading one small entry should take exactly one read");
}

- (void)testDeterministicReadCounts10Entries
{
	[self assertDeterministicReadCountsForEntryCount: 10];
}

- (void)testDeterministicReadCounts200Entries
{
	[self assertDeterministicReadCountsForEntryCount: 200];
}

- (void)testDeterministicReadCounts1000Entries
{
	[self assertDeterministicReadCountsForEntryCount: 1000];
}

#pragma mark - Timed profile test

/// Lists and reads the first entry of a 200-entry zip over each link
/// profile, with real sleeping, and prints a small table. Only the
/// Wi-Fi listing time is asserted on -- the others are informational.
- (void)testTimedProfilesOverWifiListingIsFast
{
	NSString *zipPath = [self buildZipNamed: @"timed-200.zip" withEntryCount: 200];
	NSURL *zipURL = [NSURL fileURLWithPath: zipPath];

	NSArray<NSString *> *profiles = @[@"lan", @"smb", @"wifi"];
	NSMutableString *table = [NSMutableString stringWithString: @"[fast-open][profile] profile  listing-reads  listing-seconds\n"];

	for (NSString *profileName in profiles)
	{
		NSError *error = nil;
		TSSTFileByteSource *fileSource = [TSSTFileByteSource sourceWithFileURL: zipURL error: &error];
		XCTAssertNotNil(fileSource, @"%@", error);
		TSSTSimulatedLinkByteSource *link = [TSSTSimulatedLinkByteSource linkWithProfileName: profileName wrapping: fileSource];
		link.simulateTime = YES; // real sleeping

		CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
		TSSTZipIndex *index = [TSSTZipIndex indexWithByteSource: link error: &error];
		CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - start;
		XCTAssertNotNil(index, @"%@", error);

		[link resetCounters];
		NSData *firstEntry = [index contentsOfEntry: 0 error: &error];
		XCTAssertNotNil(firstEntry, @"%@", error);

		[table appendFormat: @"[fast-open][profile] %-7@ %-13lu %.4f\n", profileName, (unsigned long)link.readCount, elapsed];

		if ([profileName isEqualToString: @"wifi"])
		{
			XCTAssertLessThan(elapsed, 0.5, @"listing over simulated Wi-Fi should stay under 0.5s");
		}
	}

	NSLog(@"%@", table);
}

#pragma mark - Real-world comics (optional, only when SC_TEST_COMICS_DIR is set)

- (void)testRealWorldComicsOverTimelessWifi
{
	NSString *dir = NSProcessInfo.processInfo.environment[@"SC_TEST_COMICS_DIR"];
	XCTSkipUnless(dir.length > 0, @"SC_TEST_COMICS_DIR not set");
	BOOL isDir = NO;
	BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath: dir isDirectory: &isDir] && isDir;
	XCTSkipUnless(exists, @"SC_TEST_COMICS_DIR is not a directory: %@", dir);

	NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath: dir error: NULL];
	NSMutableArray<NSString *> *cbzPaths = [NSMutableArray array];
	for (NSString *name in entries)
	{
		if ([[name.pathExtension lowercaseString] isEqualToString: @"cbz"])
		{
			[cbzPaths addObject: [dir stringByAppendingPathComponent: name]];
		}
	}
	XCTSkipUnless(cbzPaths.count > 0, @"no .cbz files found in the sample library");

	for (NSString *path in cbzPaths)
	{
		NSURL *url = [NSURL fileURLWithPath: path];
		NSError *error = nil;
		TSSTFileByteSource *fileSource = [TSSTFileByteSource sourceWithFileURL: url error: &error];
		if (!fileSource) { continue; }

		TSSTSimulatedLinkByteSource *link = [TSSTSimulatedLinkByteSource smbWifiLinkWrapping: fileSource];
		link.simulateTime = NO;

		TSSTZipIndex *index = [TSSTZipIndex indexWithByteSource: link error: &error];
		if (!index) { continue; }
		NSUInteger listingReads = link.readCount;
		NSTimeInterval listingElapsed = link.simulatedElapsed;

		[link resetCounters];
		NSData *firstPageData = nil;
		for (NSUInteger i = 0; i < index.numberOfEntries; ++i)
		{
			if (![index entryIsDirectory: i] && [index canExtractEntry: i])
			{
				firstPageData = [index contentsOfEntry: i error: NULL];
				break;
			}
		}
		(void)firstPageData;

		NSLog(@"[fast-open][parity] %@: listed %lu entries in %lu reads / %.3fs simulated, first page in %lu reads / %.3fs simulated",
			  path.lastPathComponent, (unsigned long)index.numberOfEntries, (unsigned long)listingReads, listingElapsed,
			  (unsigned long)link.readCount, link.simulatedElapsed);
	}
}

@end
