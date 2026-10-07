//
//  TSSTPreviewPageSelectionTests.m
//  Guards the Quick Look preview's choice of pages.
//

#import <XCTest/XCTest.h>
#import "TSSTPreviewPageSelection.h"

@interface TSSTPreviewPageSelectionTests : XCTestCase
@end

@implementation TSSTPreviewPageSelectionTests

// The old filter kept only entries from the 26th on (plus the last), so a short comic
// selected just its last page, which was then inserted past the end of an empty PDF
// and crashed the extension. Short comics must keep every page, in order.
- (void)testShortComicKeepsEveryPage {
	XCTAssertEqualObjects(TSSTPreviewPageOffsets(3, 25), (@[@0, @1, @2]));
	XCTAssertEqualObjects(TSSTPreviewPageOffsets(1, 25), @[@0]);
	XCTAssertEqualObjects(TSSTPreviewPageOffsets(0, 25), @[]);
}

// Long comics are capped at maxPages, plus the last page as a user suggested.
- (void)testLongComicIsCappedPlusLastPage {
	NSArray<NSNumber *> *offsets = TSSTPreviewPageOffsets(100, 25);
	XCTAssertEqual(offsets.count, 26u);
	XCTAssertEqualObjects(offsets.firstObject, @0);
	XCTAssertEqualObjects(offsets[24], @24);
	XCTAssertEqualObjects(offsets.lastObject, @99);
	// Exactly at the cap there is no duplicate of the last page.
	XCTAssertEqual(TSSTPreviewPageOffsets(25, 25).count, 25u);
}

@end
