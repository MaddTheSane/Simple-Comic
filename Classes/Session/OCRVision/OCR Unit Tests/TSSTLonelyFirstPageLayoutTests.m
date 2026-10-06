//
//  TSSTLonelyFirstPageLayoutTests.m
//  Checks the "Show first page alone" checkbox in Preferences (#64).
//

#import "TSSTUILayoutTestCase.h"

@interface TSSTLonelyFirstPageLayoutTests : TSSTUILayoutTestCase
@end

@implementation TSSTLonelyFirstPageLayoutTests

- (void)testCheckboxIsBoundAndNotTruncated
{
	NSView *content = [self loadPreferencesWindow].contentView;
	NSButton *checkbox = [self checkboxWithTitle:@"Show first page alone" inView:content];
	XCTAssertNotNil(checkbox);
	if (!checkbox) return;
	[self assertControl:checkbox isBoundToDefaultsKey:@"lonelyFirstPage"];
	[self assertControl:checkbox fitsWithinFrame:checkbox.frame];
}

- (void)testNoLayoutProblems
{
	NSView *content = [self loadPreferencesWindow].contentView;
	[self assertNoAmbiguousLayoutInContentView:content];
	[self assertNoClippedSubviewsInContentView:content];
	[self assertNoOverlappingSiblingsInContentView:content];
}

@end
