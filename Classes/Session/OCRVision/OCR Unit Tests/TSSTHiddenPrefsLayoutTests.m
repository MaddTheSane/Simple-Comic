//
//  TSSTHiddenPrefsLayoutTests.m
//  Checks the Preferences checkboxes for settings that previously had no UI.
//

#import "TSSTUILayoutTestCase.h"

@interface TSSTHiddenPrefsLayoutTests : TSSTUILayoutTestCase
@end

@implementation TSSTHiddenPrefsLayoutTests

- (void)testCheckboxesAreBoundAndNotTruncated
{
	NSDictionary<NSString *, NSString *> *keysByTitle = @{
		@"Enable two-finger swipe to turn pages": @"enableSwipe",
		@"Preserve file modification date": @"preserveModDate",
		@"Unified toolbar and title bar": @"unifiedTitlebar",
	};
	NSView *content = [self loadPreferencesWindow].contentView;
	for (NSString *title in keysByTitle) {
		NSButton *checkbox = [self checkboxWithTitle:title inView:content];
		XCTAssertNotNil(checkbox, @"expected a \"%@\" checkbox in Preferences", title);
		if (!checkbox) continue;
		[self assertControl:checkbox isBoundToDefaultsKey:keysByTitle[title]];
		[self assertControl:checkbox fitsWithinFrame:checkbox.frame];
	}
}

- (void)testNoLayoutProblems
{
	NSView *content = [self loadPreferencesWindow].contentView;
	[self assertNoAmbiguousLayoutInContentView:content];
	[self assertNoClippedSubviewsInContentView:content];
	[self assertNoOverlappingSiblingsInContentView:content];
}

@end
