//
//  TSSTPageSizingTests.m
//  Page sizing (ImageIO header shortcut, decode fallback) must report the
//  encoded dimensions, and bad data must size to zero, not crash.
//

#import <XCTest/XCTest.h>
#import "TSSTPage.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface TSSTPage (SizingTesting)
+ (NSSize)headerPixelSizeOfImageData:(NSData *)imageData;
+ (NSSize)decodedPixelSizeOfImageData:(NSData *)imageData;
@end

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

- (void)assertSizeOfType:(NSBitmapImageFileType)type name:(NSString *)name
{
	NSData *data = [self imageDataOfType: type width: 37 height: 23];
	XCTAssertNotNil(data, @"couldn't build a %@", name);
	XCTAssertEqualObjects(NSStringFromSize([TSSTPage pixelSizeOfImageData: data]), NSStringFromSize(NSMakeSize(37, 23)), @"%@ size", name);
}

- (void)testSizesJPEG
{
	[self assertSizeOfType: NSBitmapImageFileTypeJPEG name: @"JPEG"];
}

- (void)testSizesPNG
{
	[self assertSizeOfType: NSBitmapImageFileTypePNG name: @"PNG"];
}

- (void)testSizesGIF
{
	[self assertSizeOfType: NSBitmapImageFileTypeGIF name: @"GIF"];
}

// The header shortcut must agree with what NSBitmapImageRep reports (what the
// page used before) for an image whose EXIF orientation rotates it 90 degrees.
- (void)testHeaderSizeMatchesDecodedSizeForRotatedJPEG
{
	NSData *plain = [self imageDataOfType: NSBitmapImageFileTypeJPEG width: 37 height: 23];
	CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)plain, NULL);
	CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
	NSMutableData *rotated = [NSMutableData data];
	CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)rotated, (__bridge CFStringRef)UTTypeJPEG.identifier, 1, NULL);
	CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)@{(id)kCGImagePropertyOrientation: @6});
	XCTAssertTrue(CGImageDestinationFinalize(destination));
	CFRelease(destination);
	CGImageRelease(image);
	CFRelease(source);

	NSSize header = [TSSTPage headerPixelSizeOfImageData: rotated];
	NSSize decoded = [TSSTPage decodedPixelSizeOfImageData: rotated];
	XCTAssertEqualObjects(NSStringFromSize(header), NSStringFromSize(decoded));
}

// Neither the header nor the decode path can size these; report "unknown" rather than crash.
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
		XCTAssertTrue(NSEqualSizes([TSSTPage pixelSizeOfImageData: data], NSZeroSize));
	}
}

@end
