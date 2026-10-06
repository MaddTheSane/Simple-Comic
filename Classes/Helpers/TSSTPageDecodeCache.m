/*
	Simple Comic
	TSSTPageDecodeCache.m
*/

#import "TSSTPageDecodeCache.h"
#import "TSSTPage.h"
#import "TSSTPage+CoreDataProperties.h"
#import "TSSTManagedGroup.h"

static const NSUInteger kDecodeCacheCostLimit = 300 * 1024 * 1024; // ~300 MB of decoded pixels

@implementation TSSTPageDecodeCache
{
	NSCache<NSManagedObjectID *, NSImage *> *_cache;
	dispatch_queue_t _decodeQueue;
}

@synthesize decodeQueue = _decodeQueue;

+ (instancetype)sharedCache
{
	static TSSTPageDecodeCache *shared = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		shared = [TSSTPageDecodeCache new];
	});
	return shared;
}

- (instancetype)init
{
	self = [super init];
	if (self)
	{
		_cache = [NSCache new];
		_cache.totalCostLimit = kDecodeCacheCostLimit;
		_decodeQueue = dispatch_queue_create("com.dancingtortoise.simplecomic.pagedecode", DISPATCH_QUEUE_SERIAL);
		dispatch_set_target_queue(_decodeQueue, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
	}
	return self;
}

- (nullable NSImage *)imageForPage:(TSSTPage *)page
{
	if (!page) { return nil; }
	return [_cache objectForKey: page.objectID];
}

- (void)decodeAndCachePage:(TSSTPage *)page
{
	if (!page || page.text) { return; } // text pages stay on the synchronous path

	NSManagedObjectID *key = page.objectID;
	if ([_cache objectForKey: key]) { return; }

	NSData *imageData = [page pageData];
	if (!imageData) { return; }

	// Pure header read -- deliberately not -setOwnSizeInfoWithData:, which
	// writes width/height/aspectRatio onto this NSManagedObject. Those
	// writes must happen on the thread the object's context is confined
	// to (main); -shouldDisplayAlone / -pageImage already do that lazily
	// on their own the first time they're called on this page, reading
	// the same bytes back out of this cache's upstream cache (fast, no
	// second network round trip).
	NSSize pixelSize;
	if (![TSSTPage pixelSizeFromImageData: imageData size: &pixelSize]) { return; }

	NSImage *image = [TSSTPage imageWithData: imageData pixelSize: pixelSize];
	if (!image) { return; }

	// Force the decode now, off-main, instead of leaving it for the first
	// draw on the main thread.
	NSRect proposedRect = NSMakeRect(0, 0, pixelSize.width, pixelSize.height);
	CGImageRef decoded = [image CGImageForProposedRect: &proposedRect context: nil hints: nil];
	if (!decoded) { return; }

	NSUInteger cost = (NSUInteger)pixelSize.width * (NSUInteger)pixelSize.height * 4;
	[_cache setObject: image forKey: key cost: cost];
}

- (void)runOnDecodeQueueWhileCurrent:(BOOL (^)(void))isCurrent
								work:(void (^)(void))work
						  completion:(void (^)(BOOL ran))completion
{
	dispatch_async(_decodeQueue, ^{
		BOOL ran = isCurrent();
		if (ran) { work(); }
		dispatch_async(dispatch_get_main_queue(), ^{ completion(ran); });
	});
}

- (void)decodePages:(NSArray<TSSTPage *> *)pages
		whileCurrent:(BOOL (^)(void))isCurrent
		  completion:(void (^)(BOOL ran))completion
{
	[self runOnDecodeQueueWhileCurrent: isCurrent work: ^{
		for (TSSTPage *page in pages) { [self decodeAndCachePage: page]; }
	} completion: completion];
}

- (void)removeAllObjects
{
	[_cache removeAllObjects];
}

@end
