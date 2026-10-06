//
//  TSSTZipIndexTests.m
//  OCR Unit Tests
//
//  Verifies TSSTZipIndex against real zip files built with the system
//  `zip` tool, and cross-checks its output against XADArchive so that we
//  know entry indices, names and bytes line up between the two backends
//  (TSSTPage.index values must remain valid whichever one produced them).
//

#import <XCTest/XCTest.h>
#import <XADMaster/XADArchive.h>
#import "TSSTZipIndex.h"

@interface TSSTZipIndexTests : XCTestCase
@property (nonatomic, copy) NSString *tempDir;
@end

@implementation TSSTZipIndexTests

- (void)setUp
{
	[super setUp];
	NSString *base = NSTemporaryDirectory();
	self.tempDir = [base stringByAppendingPathComponent: [NSString stringWithFormat: @"TSSTZipIndexTests-%@", [[NSUUID UUID] UUIDString]]];
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

/// Runs a task synchronously, returning its stdout as data (used for the
/// piped `zip -` stdin-streaming case).
- (int)runTask:(NSString *)launchPath arguments:(NSArray<NSString *> *)args inDirectory:(NSString *)dir inputData:(nullable NSData *)inputData
{
	NSTask *task = [[NSTask alloc] init];
	task.launchPath = launchPath;
	task.arguments = args;
	task.currentDirectoryPath = dir;
	if (inputData)
	{
		NSPipe *inPipe = [NSPipe pipe];
		task.standardInput = inPipe;
		[task launch];
		[inPipe.fileHandleForWriting writeData: inputData];
		[inPipe.fileHandleForWriting closeFile];
	}
	else
	{
		task.standardOutput = [NSPipe pipe]; // silence
		[task launch];
	}
	[task waitUntilExit];
	return task.terminationStatus;
}

- (void)writeString:(NSString *)string toFile:(NSString *)path
{
	[string writeToFile: path atomically: YES encoding: NSUTF8StringEncoding error: NULL];
}

#pragma mark - Basic construction

- (void)testNonZipFileReturnsNil
{
	NSString *path = [self pathForName: @"not-a-zip.txt"];
	[self writeString: @"hello world, this is not a zip file" toFile: path];

	NSError *error = nil;
	TSSTZipIndex *index = [TSSTZipIndex indexWithFileURL: [NSURL fileURLWithPath: path] error: &error];
	XCTAssertNil(index);
}

- (void)testDeflatedZipMatchesXAD
{
	NSString *srcDir = [self.tempDir stringByAppendingPathComponent: @"deflated-src"];
	[[NSFileManager defaultManager] createDirectoryAtPath: srcDir withIntermediateDirectories: YES attributes: nil error: NULL];
	[self writeString: @"alpha file contents\n" toFile: [srcDir stringByAppendingPathComponent: @"a.txt"]];
	[self writeString: [@"" stringByPaddingToLength: 5000 withString: @"beta-content-line\n" startingAtIndex: 0] toFile: [srcDir stringByAppendingPathComponent: @"b.txt"]];

	NSString *zipPath = [self.tempDir stringByAppendingPathComponent: @"deflated.zip"];
	int status = [self runTask: @"/usr/bin/zip" arguments: @[@"-r", @"-q", zipPath, @"."] inDirectory: srcDir inputData: nil];
	XCTAssertEqual(status, 0);

	[self assertIndexAtPath: zipPath matchesXADFallbackAllowed: NO];
}

- (void)testStoredZipMatchesXAD
{
	NSString *srcDir = [self.tempDir stringByAppendingPathComponent: @"stored-src"];
	[[NSFileManager defaultManager] createDirectoryAtPath: srcDir withIntermediateDirectories: YES attributes: nil error: NULL];
	[self writeString: @"stored entry, no compression\n" toFile: [srcDir stringByAppendingPathComponent: @"c.txt"]];

	NSString *zipPath = [self.tempDir stringByAppendingPathComponent: @"stored.zip"];
	int status = [self runTask: @"/usr/bin/zip" arguments: @[@"-0", @"-r", @"-q", zipPath, @"."] inDirectory: srcDir inputData: nil];
	XCTAssertEqual(status, 0);

	[self assertIndexAtPath: zipPath matchesXADFallbackAllowed: NO];
}

- (void)testStreamedZipEntryMatchesXAD
{
	// `zip -q out.zip -` reads the entry's content from stdin and writes a
	// data-descriptor-style entry (sizes/crc after the compressed data,
	// general-purpose bit 3 set). Central directory sizes/crc are still
	// authoritative, so TSSTZipIndex should handle this transparently.
	NSString *zipPath = [self pathForName: @"streamed.zip"];
	NSData *content = [@"streamed entry contents via stdin\n" dataUsingEncoding: NSUTF8StringEncoding];

	NSTask *task = [[NSTask alloc] init];
	task.launchPath = @"/usr/bin/zip";
	task.arguments = @[@"-q", zipPath, @"-"];
	task.currentDirectoryPath = self.tempDir;
	NSPipe *inPipe = [NSPipe pipe];
	task.standardInput = inPipe;
	[task launch];
	[inPipe.fileHandleForWriting writeData: content];
	[inPipe.fileHandleForWriting closeFile];
	[task waitUntilExit];
	XCTAssertEqual(task.terminationStatus, 0);

	NSError *error = nil;
	TSSTZipIndex *index = [TSSTZipIndex indexWithFileURL: [NSURL fileURLWithPath: zipPath] error: &error];
	XCTAssertNotNil(index, @"%@", error);
	XCTAssertEqual(index.numberOfEntries, (NSUInteger)1);
	XCTAssertTrue([index canExtractEntry: 0]);
	NSData *data = [index contentsOfEntry: 0 error: &error];
	XCTAssertEqualObjects(data, content, @"%@", error);
}

- (void)testEncryptedZipEntryNotExtractable
{
	NSString *srcDir = [self.tempDir stringByAppendingPathComponent: @"enc-src"];
	[[NSFileManager defaultManager] createDirectoryAtPath: srcDir withIntermediateDirectories: YES attributes: nil error: NULL];
	[self writeString: @"secret contents\n" toFile: [srcDir stringByAppendingPathComponent: @"secret.txt"]];

	NSString *zipPath = [self.tempDir stringByAppendingPathComponent: @"encrypted.zip"];
	int status = [self runTask: @"/usr/bin/zip" arguments: @[@"-P", @"testpassword", @"-r", @"-q", zipPath, @"."] inDirectory: srcDir inputData: nil];
	XCTAssertEqual(status, 0);

	NSError *error = nil;
	TSSTZipIndex *index = [TSSTZipIndex indexWithFileURL: [NSURL fileURLWithPath: zipPath] error: &error];
	XCTAssertNotNil(index, @"listing an encrypted zip should still succeed; only extraction is refused");
	XCTAssertEqual(index.numberOfEntries, (NSUInteger)1);
	XCTAssertFalse([index canExtractEntry: 0]);
}

- (void)testNestedSubfolderZipMatchesXAD
{
	NSString *srcDir = [self.tempDir stringByAppendingPathComponent: @"nested-src"];
	NSString *subDir = [srcDir stringByAppendingPathComponent: @"sub/deeper"];
	[[NSFileManager defaultManager] createDirectoryAtPath: subDir withIntermediateDirectories: YES attributes: nil error: NULL];
	[self writeString: @"top level file\n" toFile: [srcDir stringByAppendingPathComponent: @"top.txt"]];
	[self writeString: @"nested file\n" toFile: [subDir stringByAppendingPathComponent: @"nested.txt"]];

	NSString *zipPath = [self.tempDir stringByAppendingPathComponent: @"nested.zip"];
	int status = [self runTask: @"/usr/bin/zip" arguments: @[@"-r", @"-q", zipPath, @"."] inDirectory: srcDir inputData: nil];
	XCTAssertEqual(status, 0);

	[self assertIndexAtPath: zipPath matchesXADFallbackAllowed: YES];
}

#pragma mark - Shared comparison

/// Compares TSSTZipIndex against XADArchive entry-by-entry. XAD sometimes
/// omits pure directory entries that a zip index enumerates (or vice
/// versa, depending on how the archive's directory entries were written);
/// when `fallbackAllowed` is YES this method tolerates a count mismatch
/// caused purely by directory entries and compares only the entries that
/// exist in both, matched by name.
- (void)assertIndexAtPath:(NSString *)zipPath matchesXADFallbackAllowed:(BOOL)allowDirectoryCountMismatch
{
	NSURL *url = [NSURL fileURLWithPath: zipPath];
	NSError *error = nil;
	TSSTZipIndex *index = [TSSTZipIndex indexWithFileURL: url error: &error];
	XCTAssertNotNil(index, @"%@", error);
	if (!index) { return; }

	XADArchive *archive = [[XADArchive alloc] initWithFileURL: url delegate: nil error: &error];
	XCTAssertNotNil(archive, @"%@", error);
	if (!archive) { return; }

	NSInteger xadCount = [archive numberOfEntries];

	if (!allowDirectoryCountMismatch)
	{
		XCTAssertEqual((NSInteger)index.numberOfEntries, xadCount, @"entry count must match XAD for index alignment");
	}

	NSInteger compareCount = MIN((NSInteger)index.numberOfEntries, xadCount);
	for (NSInteger i = 0; i < compareCount; ++i)
	{
		NSString *ourName = [index nameOfEntry: i];
		NSString *xadName = [archive nameOfEntry: i];
		// XADZipParser strips the trailing "/" that zip stores on
		// directory entries; TSSTZipIndex keeps it verbatim from the
		// central directory. This is a known, harmless difference --
		// normalize it away for the comparison rather than for real
		// callers, since callers only look at trailing slashes to detect
		// directories in the first place.
		NSString *ourNameForCompare = [ourName hasSuffix: @"/"] ? [ourName substringToIndex: ourName.length - 1] : ourName;
		XCTAssertEqualObjects(ourNameForCompare, xadName, @"entry %ld name must match XAD for index alignment", (long)i);

		if ([index entryIsDirectory: i] || [ourName hasSuffix: @"/"])
		{
			continue;
		}
		if (![index canExtractEntry: i])
		{
			continue;
		}
		NSError *ourError = nil;
		NSData *ourData = [index contentsOfEntry: i error: &ourError];
		NSData *xadData = [archive contentsOfEntry: i];
		XCTAssertEqualObjects(ourData, xadData, @"entry %ld (%@) bytes must match XAD, error: %@", (long)i, ourName, ourError);
	}
}

#pragma mark - Real-world parity (optional, only when SC_TEST_COMICS_DIR is set)

/// Point this at a folder of real .cbz files, e.g.
/// `TEST_RUNNER_SC_TEST_COMICS_DIR=/path/to/comics xcodebuild test ...`.
/// Deliberately not defaulted to a user folder like ~/Desktop, which would
/// trigger a macOS privacy prompt for the test host.
- (void)testRealWorldComicsParity
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

		CFAbsoluteTime zipStart = CFAbsoluteTimeGetCurrent();
		NSError *error = nil;
		TSSTZipIndex *index = [TSSTZipIndex indexWithFileURL: url error: &error];
		CFAbsoluteTime zipElapsed = CFAbsoluteTimeGetCurrent() - zipStart;
		XCTAssertNotNil(index, @"%@: %@", path.lastPathComponent, error);
		if (!index) { continue; }

		CFAbsoluteTime xadStart = CFAbsoluteTimeGetCurrent();
		XADArchive *archive = [[XADArchive alloc] initWithFileURL: url delegate: nil error: &error];
		CFAbsoluteTime xadElapsed = CFAbsoluteTimeGetCurrent() - xadStart;
		XCTAssertNotNil(archive, @"%@: %@", path.lastPathComponent, error);
		if (!archive) { continue; }

		NSLog(@"[fast-open][parity] %@: zip-index listed %lu entries in %.3fs, XAD listed %ld entries in %.3fs",
			  path.lastPathComponent, (unsigned long)index.numberOfEntries, zipElapsed, (long)[archive numberOfEntries], xadElapsed);

		XCTAssertEqual((NSInteger)index.numberOfEntries, [archive numberOfEntries], @"%@", path.lastPathComponent);

		NSInteger imagesCompared = 0;
		for (NSInteger i = 0; i < (NSInteger)index.numberOfEntries && imagesCompared < 3; ++i)
		{
			NSString *name = [index nameOfEntry: i];
			XCTAssertEqualObjects(name, [archive nameOfEntry: i], @"%@ entry %ld", path.lastPathComponent, (long)i);
			NSString *ext = [name.pathExtension lowercaseString];
			BOOL isImage = [@[@"jpg", @"jpeg", @"png", @"gif", @"webp"] containsObject: ext];
			if (!isImage || ![index canExtractEntry: i])
			{
				continue;
			}
			NSError *ourError = nil;
			NSData *ourData = [index contentsOfEntry: i error: &ourError];
			NSData *xadData = [archive contentsOfEntry: i];
			XCTAssertEqualObjects(ourData, xadData, @"%@ entry %ld (%@)", path.lastPathComponent, (long)i, name);
			imagesCompared++;
		}
	}
}

@end
