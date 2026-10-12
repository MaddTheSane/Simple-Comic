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

@class TSSTManagedGroup;

NS_ASSUME_NONNULL_BEGIN

/// Immutable plain-value copy of what's needed to read a page's bytes, so
/// background queues never touch the NSManagedObject (whose properties may
/// only be read on its context's queue). Take it with -[TSSTPage dataSnapshot]
/// on that queue, then hand it to any thread.
@interface TSSTPageDataSnapshot : NSObject
@property (nonatomic, readonly) NSManagedObjectID *pageID;
@property (nonatomic, readonly) BOOL isText;
/// The group is only messaged through -requestDataForPageIndex:completionHandler:,
/// which is safe from any thread.
@property (nonatomic, readonly, nullable) TSSTManagedGroup *group;
@property (nonatomic, readonly) NSInteger entryIndex; // NSNotFound for loose files
@property (nonatomic, readonly, copy, nullable) NSString *imagePath;
- (instancetype)initWithPageID:(NSManagedObjectID *)pageID isText:(BOOL)isText group:(nullable TSSTManagedGroup *)group entryIndex:(NSInteger)entryIndex imagePath:(nullable NSString *)imagePath;
/// The page's bytes; blocks while an archive entry is fetched.
- (nullable NSData *)data;
@end

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
@property (readonly, copy) NSImage *thumbnail;
- (nullable NSData *)prepThumbnail;
/// Thread-safe (ImageIO header downscale, no Core Data writes) thumbnail
/// encoding of raw image bytes, max 256px. nil if undecodable.
+ (nullable NSData *)thumbnailDataFromImageData:(nullable NSData *)imageData;
/// Off-main-safe render of a page's thumbnail from the (local) bytes of a
/// snapshot taken on the context's queue (-dataSnapshot). Never touches
/// managed objects; the caller stores the result on main.
+ (nullable NSData *)thumbnailDataForSnapshot:(TSSTPageDataSnapshot *)snapshot;
@property (readonly, copy, nullable) NSData *pageData;
- (TSSTPageDataSnapshot *)dataSnapshot;
/// -dataSnapshot with the group already resolved (`self.group`'s
/// -groupForOffQueueReads), so a batch of pages in one group walks up to
/// the streaming folder once instead of per page.
- (TSSTPageDataSnapshot *)dataSnapshotReadingThrough:(nullable TSSTManagedGroup *)source;
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
