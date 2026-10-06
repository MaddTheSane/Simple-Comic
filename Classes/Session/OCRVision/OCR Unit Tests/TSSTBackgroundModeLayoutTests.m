//
//  TSSTBackgroundModeLayoutTests.m
//  Checks the "Background style" pop-up in Preferences.
//

#import "TSSTUILayoutTestCase.h"

@interface TSSTBackgroundModeLayoutTests : TSSTUILayoutTestCase
@end

@implementation TSSTBackgroundModeLayoutTests

- (NSPopUpButton *)firstPopUpInView:(NSView *)view
{
	for (NSView *subview in view.subviews) {
		if ([subview isKindOfClass:[NSPopUpButton class]]) return (NSPopUpButton *)subview;
		NSPopUpButton *found = [self firstPopUpInView:subview];
		if (found) return found;
	}
	return nil;
}

- (void)testPopUpHasBothModesAndIsBound
{
	NSPopUpButton *popUp = [self firstPopUpInView:[self loadPreferencesWindow].contentView];
	XCTAssertNotNil(popUp);
	if (!popUp) return;
	XCTAssertEqualObjects([popUp itemTitleAtIndex:0], @"Solid color");
	XCTAssertEqualObjects([popUp itemTitleAtIndex:1], @"Blurred page edges");

	NSDictionary *info = [popUp infoForBinding:NSSelectedIndexBinding];
	XCTAssertEqualObjects(info[NSObservedKeyPathKey], @"values.pageBackgroundMode");
}

- (void)testNoLayoutProblems
{
	NSView *content = [self loadPreferencesWindow].contentView;
	[self assertNoAmbiguousLayoutInContentView:content];
	[self assertNoClippedSubviewsInContentView:content];
	[self assertNoOverlappingSiblingsInContentView:content];
}

@end
