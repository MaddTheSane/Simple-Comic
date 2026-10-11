/*
Copyright (c) 2006-2009 Dancing Tortoise Software

	Permission is hereby granted, free of charge, to any person
	obtaining a copy of this software and associated documentation
	files (the "Software"), to deal in the Software without
	restriction, including without limitation the rights to use,
	copy, modify, merge, publish, distribute, sublicense, and/or
	sell copies of the Software, and to permit persons to whom the
	Software is furnished to do so, subject to the following
	conditions:

	The above copyright notice and this permission notice shall be
	included in all copies or substantial portions of the Software.

  TSSTPage.h
*/

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSSTPage : NSManagedObject
{
    NSLock * thumbLock;
    NSLock * loaderLock;
}

@property (class, readonly, copy) NSArray<NSString*> *imageTypes;
@property (class, readonly, copy) NSArray<NSString*> *imageExtensions;
@property (class, readonly, copy) NSArray<NSString*> *textExtensions;
@property (readonly, copy) NSString *name;
@property (readonly) BOOL shouldDisplayAlone;
- (void)setOwnSizeInfoWithData:(NSData *)imageData;

/// Pixel size of encoded image data: the header size if ImageIO can read it,
/// otherwise the size from decoding the image. NSZeroSize if neither works.
+ (NSSize)pixelSizeOfImageData:(NSData *)imageData;
/// The two strategies behind +pixelSizeOfImageData:, exposed so tests can check
/// that they agree. The first is NSZeroSize when ImageIO can't read the header.
+ (NSSize)headerPixelSizeOfImageData:(NSData *)imageData;
+ (NSSize)decodedPixelSizeOfImageData:(NSData *)imageData;
@property (readonly, copy) NSImage *thumbnail;
- (nullable NSData *)prepThumbnail;
@property (readonly, copy, nullable) NSData *pageData;
@property (readonly, copy) NSImage *textPage;
@property (readonly, copy, nullable) NSImage *pageImage;

@end

NS_ASSUME_NONNULL_END

#import "TSSTPage+CoreDataProperties.h"
