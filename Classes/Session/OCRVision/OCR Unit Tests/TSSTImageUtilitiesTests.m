//
//  TSSTImageUtilitiesTests.m
//  Regression tests for bugs found in a bug-bash pass.
//

#import <XCTest/XCTest.h>
#import "TSSTImageUtilities.h"

@interface TSSTImageUtilitiesTests : XCTestCase
@end

@implementation TSSTImageUtilitiesTests

// fitSizeInSize used to compare constraint's aspect ratio against size.width/size.width
// (always 1.0, or NaN), so the branch taken never actually depended on the source
// image's own aspect ratio. This case is constructed so the buggy and fixed
// comparisons pick different branches, proving the source aspect ratio is now used.
- (void)testFitSizeInSizeUsesSourceAspectRatio {
	CGSize constraint = CGSizeMake(100, 200); // constraint.height/constraint.width == 2
	CGSize size = CGSizeMake(50, 300);        // size.height/size.width == 6, size.width < constraint.width

	CGSize result = fitSizeInSize(constraint, size);

	// Fixed behavior: 2 > 6 is false, so the else branch scales by size.width/constraint.width.
	CGFloat scale = size.width / constraint.width;
	CGSize expected = CGSizeMake(size.width * scale, size.height * scale);
	XCTAssertEqualWithAccuracy(result.width, expected.width, 0.001);
	XCTAssertEqualWithAccuracy(result.height, expected.height, 0.001);

	// The old bug (comparing size.width/size.width, always 1.0) would have taken
	// the other branch here (2 > 1 is true), producing a different result.
	CGFloat buggyScale = size.height / constraint.height;
	CGSize buggyResult = CGSizeMake(size.width * buggyScale, size.height * buggyScale);
	XCTAssertNotEqual(result.width, buggyResult.width);
}

- (void)testFitSizeInSizeNoScalingWhenNeitherDimensionIsSmaller {
	CGSize constraint = CGSizeMake(50, 50);
	CGSize size = CGSizeMake(100, 100);

	CGSize result = fitSizeInSize(constraint, size);

	XCTAssertEqualWithAccuracy(result.width, size.width, 0.001);
	XCTAssertEqualWithAccuracy(result.height, size.height, 0.001);
}

// imageScaledToSizeFromImage used to draw the (empty) destination image into itself,
// producing a fully transparent result regardless of the source image's contents.
- (void)testImageScaledToSizeFromImageDrawsSourceContent {
	NSSize sourceSize = NSMakeSize(20, 20);
	NSImage *source = [[NSImage alloc] initWithSize:sourceSize];
	[source lockFocus];
	[[NSColor redColor] setFill];
	NSRectFill(NSMakeRect(0, 0, sourceSize.width, sourceSize.height));
	[source unlockFocus];

	NSImage *scaled = imageScaledToSizeFromImage(NSMakeSize(40, 40), source);

	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:[scaled TIFFRepresentation]];
	NSColor *pixel = [rep colorAtX:20 y:20];
	XCTAssertNotNil(pixel);
	// A blank/transparent draw would yield alpha == 0; the fixed version should paint the red source.
	XCTAssertGreaterThan([pixel alphaComponent], 0.0, @"expected the scaled image to contain drawn (non-blank) content");
}

@end
