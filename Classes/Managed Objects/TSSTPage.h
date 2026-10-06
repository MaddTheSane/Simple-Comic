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

/// Pure header-only pixel-size lookup (ImageIO, falling back to
/// NSImageRep), factored out of -setOwnSizeInfoWithData: so background
/// pre-decode can learn an image's size without writing to this managed
/// object's attributes off the main thread. Returns NO (leaving *outSize
/// untouched) if the size couldn't be determined.
+ (BOOL)pixelSizeFromImageData:(NSData *)imageData size:(NSSize *)outSize;
@property (readonly, copy) NSImage *thumbnail;
- (nullable NSData *)prepThumbnail;
@property (readonly, copy, nullable) NSData *pageData;
@property (readonly, copy) NSImage *textPage;
@property (readonly, copy, nullable) NSImage *pageImage;

/// Wraps \c imageData in an \c NSImage sized to \c pixelSize using the same
/// cache-mode dance as \c -pageImage (disable NSImage's own size-keyed
/// cache while setting the size, so it doesn't clash with the size that
/// was just decided from the page's stored width/height, then re-enable
/// it). Returns nil if either input is unusable. Shared with background
/// pre-decode so both paths produce identical images.
+ (nullable NSImage *)imageWithData:(nullable NSData *)imageData pixelSize:(NSSize)pixelSize;

@end

NS_ASSUME_NONNULL_END

#import "TSSTPage+CoreDataProperties.h"
