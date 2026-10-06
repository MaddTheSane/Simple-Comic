//
//  TSSTPreferencesLayoutTests.m
//  Baseline layout checks for Preferences.xib; later nib changes must not regress them.
//

#import "TSSTUILayoutTestCase.h"

@interface TSSTPreferencesLayoutTests : TSSTUILayoutTestCase
@end

@implementation TSSTPreferencesLayoutTests

- (void)testNoAmbiguousLayout
{
	[self assertNoAmbiguousLayoutInContentView:[self loadPreferencesWindow].contentView];
}

- (void)testNoClippedSubviews
{
	[self assertNoClippedSubviewsInContentView:[self loadPreferencesWindow].contentView];
}

- (void)testNoOverlappingSiblings
{
	[self assertNoOverlappingSiblingsInContentView:[self loadPreferencesWindow].contentView];
}

@end
