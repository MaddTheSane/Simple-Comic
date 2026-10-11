//
//  TSSTPageSizingTests.m
//  The ImageIO header-size shortcut for page sizing must agree with the
//  full-decode path it replaces, and bad data must size to zero, not crash.
//

#import <XCTest/XCTest.h>
#import "TSSTPage.h"

@interface TSSTPageSizingTests : XCTestCase
@end

@implementation TSSTPageSizingTests

/// An opaque, non-square, patterned bitmap encoded as `type`.
- (NSData *)imageDataOfType:(NSBitmapImageFileType)type width:(NSInteger)width height:(NSInteger)height
{
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes: NULL
																	pixelsWide: width
																	pixelsHigh: height
																 bitsPerSample: 8
															   samplesPerPixel: 3
																	  hasAlpha: NO
																	  isPlanar: NO
																colorSpaceName: NSDeviceRGBColorSpace
																   bytesPerRow: 0
																  bitsPerPixel: 0];
	for (NSInteger y = 0; y < height; y++) {
		for (NSInteger x = 0; x < width; x++) {
			[rep setColor: [NSColor colorWithDeviceRed: (CGFloat)x / width green: (CGFloat)y / height blue: 0.5 alpha: 1] atX: x y: y];
		}
	}
	return [rep representationUsingType: type properties: @{}];
}

- (void)assertHeaderAndDecodeAgreeForType:(NSBitmapImageFileType)type name:(NSString *)name
{
	NSData *data = [self imageDataOfType: type width: 37 height: 23];
	XCTAssertNotNil(data, @"couldn't build a %@", name);

	NSSize header = [TSSTPage headerPixelSizeOfImageData: data];
	NSSize decoded = [TSSTPage decodedPixelSizeOfImageData: data];

	XCTAssertEqualObjects(NSStringFromSize(header), NSStringFromSize(NSMakeSize(37, 23)), @"%@ header size", name);
	XCTAssertEqualObjects(NSStringFromSize(header), NSStringFromSize(decoded), @"%@ header and decoded sizes differ", name);
	XCTAssertEqualObjects(NSStringFromSize([TSSTPage pixelSizeOfImageData: data]), NSStringFromSize(header));
}

- (void)testHeaderSizeMatchesDecodedSizeForJPEG
{
	[self assertHeaderAndDecodeAgreeForType: NSBitmapImageFileTypeJPEG name: @"JPEG"];
}

- (void)testHeaderSizeMatchesDecodedSizeForPNG
{
	[self assertHeaderAndDecodeAgreeForType: NSBitmapImageFileTypePNG name: @"PNG"];
}

- (void)testHeaderSizeMatchesDecodedSizeForGIF
{
	[self assertHeaderAndDecodeAgreeForType: NSBitmapImageFileTypeGIF name: @"GIF"];
}

// Neither strategy can size these; the fallback must report "unknown" rather than crash.
- (void)testUnreadableDataSizesToZeroWithoutCrashing
{
	NSData *png = [self imageDataOfType: NSBitmapImageFileTypePNG width: 10 height: 10];
	NSMutableData *garbage = [NSMutableData dataWithLength: 64];
	arc4random_buf(garbage.mutableBytes, garbage.length);
	NSArray<NSData *> *cases = @[
		[NSData data],                                  // empty
		garbage,                                        // no recognisable header
		[png subdataWithRange: NSMakeRange(0, 8)],      // PNG signature but no IHDR
	];
	for (NSData *data in cases) {
		XCTAssertTrue(NSEqualSizes([TSSTPage headerPixelSizeOfImageData: data], NSZeroSize));
		XCTAssertTrue(NSEqualSizes([TSSTPage pixelSizeOfImageData: data], NSZeroSize));
	}
}

@end
