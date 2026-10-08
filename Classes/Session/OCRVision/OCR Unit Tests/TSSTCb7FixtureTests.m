//
//  TSSTCb7FixtureTests.m
//  Runs the cb7zoo fixtures through the app's archive reader and the Quick Look
//  page selection.
//

#import <XCTest/XCTest.h>
#import <XADMaster/XADArchive.h>
#import "TSSTPreviewPageSelection.h"

@interface TSSTCb7FixtureTests : XCTestCase
@end

@implementation TSSTCb7FixtureTests

- (NSURL *)fixture:(NSString *)name {
	NSURL *url = [[NSBundle bundleForClass:self.class] URLForResource:name.stringByDeletingPathExtension
														withExtension:name.pathExtension
														 subdirectory:@"cb7zoo"];
	XCTAssertNotNil(url, @"%@ is not in the test bundle", name);
	return url;
}

// Entry indexes of the images the preview would list, or nil if the archive won't open.
- (nullable NSArray<NSNumber *> *)imageEntriesIn:(XADArchive *)archive {
	if (!archive) return nil;
	NSMutableArray *entries = [NSMutableArray array];
	for (NSInteger i = 0; i < archive.numberOfEntries; i++) {
		if ([[archive nameOfEntry:i].pathExtension.lowercaseString isEqual:@"jpg"]) [entries addObject:@(i)];
	}
	return entries;
}

// Valid archives list the expected pages and every page the preview selects can be read,
// including the 25-page boundary of jj-30pages (26 selected: 25 plus the last).
- (void)testPreviewSelectionReadsRealPages {
	NSDictionary *expected = @{@"jj-4pages.cb7": @4, @"jj-solid.cb7": @4, @"jj-30pages.cb7": @30};
	for (NSString *name in expected) {
		XADArchive *archive = [[XADArchive alloc] initWithFileURL:[self fixture:name] delegate:nil error:NULL];
		NSArray *entries = [self imageEntriesIn:archive];
		XCTAssertEqual(entries.count, [expected[name] unsignedIntegerValue], @"%@", name);
		NSArray<NSNumber *> *offsets = TSSTPreviewPageOffsets(entries.count, 25);
		XCTAssertEqual(offsets.count, MIN(entries.count, 26u), @"%@", name);
		for (NSNumber *offset in offsets) {
			NSData *data = [archive contentsOfEntry:[entries[offset.integerValue] integerValue]];
			XCTAssertGreaterThan(data.length, 0u, @"%@ page %@", name, offset);
		}
	}
}

// A broken or empty archive gives a short or empty page list, never an offset past the end.
- (void)testTruncatedAndEmptyArchivesStaySafe {
	for (NSString *name in @[@"jj-truncated.cb7", @"jj-empty.cb7"]) {
		XADArchive *archive = [[XADArchive alloc] initWithFileURL:[self fixture:name] delegate:nil error:NULL];
		NSArray *entries = [self imageEntriesIn:archive] ?: @[];
		for (NSNumber *offset in TSSTPreviewPageOffsets(entries.count, 25)) {
			XCTAssertLessThan(offset.unsignedIntegerValue, entries.count, @"%@", name);
		}
		if ([name isEqual:@"jj-empty.cb7"]) XCTAssertEqual(entries.count, 0u);
	}
}

@end
