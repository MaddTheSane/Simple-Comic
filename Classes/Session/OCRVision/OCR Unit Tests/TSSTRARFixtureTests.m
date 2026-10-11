//
//  TSSTRARFixtureTests.m
//  OCR Unit Tests
//
//  Opens the public-domain RAR fixtures (Fixtures/, Fixtures/rarzoo/) with a
//  plain XADArchive: listing, extraction, passwords, multi-volume sets and
//  damaged files. Tests skip when a fixture is unreadable and never prompt;
//  passwords come from a delegate, not from the app's dialog.
//

#import <XCTest/XCTest.h>
#import <XADMaster/XADArchive.h>
#import "TSSTTestFixtures.h"
#import "TSSTManagedGroup.h"

static NSString *const kFixturePassword = @"TESTPW"; // password of every encrypted fixture
static const NSUInteger kFixturePageCount = 6;       // pages in each plain fixture

/// Answers XADArchive's password request without any UI.
@interface TSSTFixturePasswordDelegate : NSObject <XADArchiveDelegate>
@property (nonatomic, copy, nullable) NSString *password;
@property (nonatomic) NSUInteger requests;
@end

@implementation TSSTFixturePasswordDelegate
- (void)archiveNeedsPassword:(XADArchive *)archive
{
	self.requests++;
	if (self.password) { archive.password = self.password; }
}
@end

@interface TSSTRARFixtureTests : XCTestCase
@end

@implementation TSSTRARFixtureTests

#pragma mark - Helpers

/// Opens a fixture. The delegate is held by the caller (XADArchive keeps it weakly).
- (nullable XADArchive *)openFixtureURL:(NSURL *)url delegate:(nullable id<XADArchiveDelegate>)delegate
{
	return [[XADArchive alloc] initWithFileURL: url delegate: delegate error: NULL];
}

/// Indexes of entries that are JPEG pages, in archive order.
- (NSArray<NSNumber *> *)pageIndexesInArchive:(XADArchive *)archive
{
	NSMutableArray<NSNumber *> *indexes = [NSMutableArray array];
	for (NSInteger i = 0; i < archive.numberOfEntries; ++i)
	{
		if ([[archive nameOfEntry: i].pathExtension.lowercaseString isEqualToString: @"jpg"]) { [indexes addObject: @(i)]; }
	}
	return indexes;
}

- (BOOL)dataIsJPEG:(nullable NSData *)data
{
	const uint8_t *bytes = data.bytes;
	return data.length > 4 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;
}

/// Asserts the archive lists kFixturePageCount pages and that the last one extracts as a JPEG
/// (the last page is the one that crosses volumes or follows a solid chain).
- (void)assertListsAndExtractsPages:(XADArchive *)archive
{
	XCTAssertNotNil(archive);
	NSArray<NSNumber *> *pages = [self pageIndexesInArchive: archive];
	XCTAssertEqual(pages.count, kFixturePageCount);
	NSInteger last = pages.lastObject.integerValue;
	NSData *data = [archive contentsOfEntry: last];
	XCTAssertTrue([self dataIsJPEG: data], @"%@ is not a JPEG", [archive nameOfEntry: last]);
	XCTAssertEqual((off_t)data.length, [archive uncompressedSizeOfEntry: last]);
}

#pragma mark - Plain archives

- (void)testRAR4ListsAndExtractsPages
{
	TSSTRequireFixture(url, @"jessie-james-rar4.cbr");
	XADArchive *archive = [self openFixtureURL: url delegate: nil];
	[self assertListsAndExtractsPages: archive];
	XCTAssertFalse(archive.isEncrypted);
}

- (void)testRAR5ListsAndExtractsPages
{
	TSSTRequireFixture(url, @"jessie-james-rar5.cbr");
	XADArchive *archive = [self openFixtureURL: url delegate: nil];
	[self assertListsAndExtractsPages: archive];
	XCTAssertFalse(archive.isEncrypted);
}

- (void)testSolidArchivesExtractEveryPage
{
	for (NSString *name in @[@"jj-rar4-solid.cbr", @"jj-rar5-solid.cbr"])
	{
		TSSTRequireFixture(url, name);
		XADArchive *archive = [self openFixtureURL: url delegate: nil];
		XCTAssertTrue(archive.isSolid, @"%@", name);
		for (NSNumber *index in [self pageIndexesInArchive: archive])
		{
			XCTAssertTrue([self dataIsJPEG: [archive contentsOfEntry: index.integerValue]], @"%@ entry %@", name, index);
		}
	}
}

#pragma mark - Multi-volume sets

- (void)testRAR4VolumeSetReadsAsOneArchive
{
	TSSTRequireFixture(url, @"jj-rar4-vol.rar"); // .r00 ... .r04 are found beside it
	[self assertListsAndExtractsPages: [self openFixtureURL: url delegate: nil]];
}

- (void)testRAR5VolumeSetReadsAsOneArchive
{
	TSSTRequireFixture(url, @"jj-rar5-vol.part1.rar");
	[self assertListsAndExtractsPages: [self openFixtureURL: url delegate: nil]];
}

#pragma mark - Encryption

- (void)testEncryptedContentListsWithoutPasswordButNeedsOneToExtract
{
	for (NSString *name in @[@"jj-rar4-enccontent.cbr", @"jj-rar5-enccontent.cbr"])
	{
		TSSTRequireFixture(url, name);
		TSSTFixturePasswordDelegate *noPassword = [TSSTFixturePasswordDelegate new];
		XADArchive *archive = [self openFixtureURL: url delegate: noPassword];
		NSArray<NSNumber *> *pages = [self pageIndexesInArchive: archive];
		XCTAssertEqual(pages.count, kFixturePageCount, @"%@ lists its names without a password", name);
		XCTAssertTrue(archive.isEncrypted, @"%@", name);
		XCTAssertFalse([self dataIsJPEG: [archive contentsOfEntry: pages.firstObject.integerValue]], @"%@ extracted without a password", name);

		archive.password = kFixturePassword;
		[archive clearLastError];
		XCTAssertTrue([self dataIsJPEG: [archive contentsOfEntry: pages.firstObject.integerValue]], @"%@ with the password", name);
	}
}

- (void)testEncryptedHeadersNeedThePasswordToList
{
	for (NSString *name in @[@"jj-rar4-encheaders.cbr", @"jj-rar5-encheaders.cbr"])
	{
		TSSTRequireFixture(url, name);

		// Without a password the archive cannot be listed (and must not hang or crash).
		TSSTFixturePasswordDelegate *noPassword = [TSSTFixturePasswordDelegate new];
		XADArchive *locked = [self openFixtureURL: url delegate: noPassword];
		XCTAssertEqual([self pageIndexesInArchive: locked].count, 0u, @"%@", name);
		XCTAssertGreaterThan(noPassword.requests, 0u, @"%@ should ask for a password", name);

		TSSTFixturePasswordDelegate *withPassword = [TSSTFixturePasswordDelegate new];
		withPassword.password = kFixturePassword;
		XADArchive *unlocked = [self openFixtureURL: url delegate: withPassword];
		[self assertListsAndExtractsPages: unlocked];
	}
}

#pragma mark - Damaged archives

- (void)testTruncatedArchivesDoNotCrash
{
	for (NSString *name in @[@"jj-rar4-truncated.cbr", @"jj-rar5-truncated.cbr", @"jj-rar5-nonsolid-truncated.cbr"])
	{
		TSSTRequireFixture(url, name);
		XADArchive *archive = [self openFixtureURL: url delegate: nil];
		// Whatever survives the cut may be listed; reading every entry must simply not crash.
		for (NSInteger i = 0; archive && i < archive.numberOfEntries; ++i)
		{
			(void)[archive contentsOfEntry: i];
		}
		XCTAssertTrue(archive == nil || archive.numberOfEntries <= (NSInteger)kFixturePageCount, @"%@", name);
	}
}

- (void)testTruncatedNonSolidArchiveKeepsItsEarlyPages
{
	TSSTRequireFixture(url, @"jj-rar5-nonsolid-truncated.cbr");
	XADArchive *archive = [self openFixtureURL: url delegate: nil];
	NSArray<NSNumber *> *pages = [self pageIndexesInArchive: archive];
	XCTAssertGreaterThan(pages.count, 0u);
	XCTAssertTrue([self dataIsJPEG: [archive contentsOfEntry: pages.firstObject.integerValue]]);
}

#pragma mark - App scan path

// +scanRecordForFileURL: is what the app opens archives with; its record
// carries one child per page here (the fixtures hold nothing else).
- (NSUInteger)scannedChildCountForFixture:(NSURL *)url password:(nullable NSString *)password
{
	NSMutableArray<NSError *> *errors = [NSMutableArray array];
	id record = [TSSTManagedArchive scanRecordForFileURL: url name: nil password: password errors: errors];
	XCTAssertEqual(errors.count, 0u);
	return [[record valueForKey: @"children"] count];
}

- (void)testScanRecordListsRARPages
{
	TSSTRequireFixture(rar4, @"jessie-james-rar4.cbr");
	TSSTRequireFixture(rar5, @"jessie-james-rar5.cbr");
	XCTAssertEqual([self scannedChildCountForFixture: rar4 password: nil], kFixturePageCount);
	XCTAssertEqual([self scannedChildCountForFixture: rar5 password: nil], kFixturePageCount);
}

- (void)testScanRecordUsesSuppliedPasswordForEncryptedHeaders
{
	TSSTRequireFixture(url, @"jj-rar5-encheaders.cbr");
	XCTAssertEqual([self scannedChildCountForFixture: url password: kFixturePassword], kFixturePageCount);
}

@end
