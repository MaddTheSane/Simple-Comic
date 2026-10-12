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

- (void)decodeAndCacheSnapshot:(TSSTPageDataSnapshot *)snapshot
{
	if (!snapshot || snapshot.isText) { return; } // text pages stay on the synchronous path

	NSManagedObjectID *key = snapshot.pageID;
	if ([_cache objectForKey: key]) { return; }

	NSData *imageData = [snapshot data];
	if (!imageData) { return; }

	// Pure header read -- deliberately not -setOwnSizeInfoWithData:, which
	// writes width/height/aspectRatio onto this NSManagedObject. Those
	// writes must happen on the thread the object's context is confined
	// to (main); -shouldDisplayAlone / -pageImage already do that lazily
	// on their own the first time they're called on this page, reading
	// the same bytes back out of this cache's upstream cache (fast, no
	// second network round trip).
	NSSize pixelSize = [TSSTPage pixelSizeOfImageData: imageData];
	if (NSEqualSizes(pixelSize, NSZeroSize)) { return; }

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

/// Snapshots `pages`' data on the calling thread (a snapshot reads the
/// managed object, which is confined to its context's thread).
- (NSArray<TSSTPageDataSnapshot *> *)snapshotsForPages:(NSArray<TSSTPage *> *)pages
{
	NSMutableArray<TSSTPageDataSnapshot *> *snapshots = [NSMutableArray arrayWithCapacity: pages.count];
	// Pages of a group share the group they read through: resolve it once.
	NSMapTable<TSSTManagedGroup *, id> *sources = [NSMapTable strongToStrongObjectsMapTable];
	for (TSSTPage *page in pages)
	{
		TSSTManagedGroup *group = page.group;
		id source = group ? [sources objectForKey: group] : NSNull.null;
		if (!source) // not resolved yet (NSNull: resolved to "read its own file")
		{
			source = [group groupForOffQueueReads] ?: NSNull.null;
			[sources setObject: source forKey: group];
		}
		[snapshots addObject: [page dataSnapshotReadingThrough: source == NSNull.null ? nil : source]];
	}
	return snapshots;
}

/// Decodes each snapshot in order; call on the decode queue.
- (void)decodeSnapshots:(NSArray<TSSTPageDataSnapshot *> *)snapshots
{
	for (TSSTPageDataSnapshot *snapshot in snapshots) { [self decodeAndCacheSnapshot: snapshot]; }
}

- (void)decodePages:(NSArray<TSSTPage *> *)pages
		whileCurrent:(BOOL (^)(void))isCurrent
		  completion:(void (^)(BOOL ran))completion
{
	NSArray<TSSTPageDataSnapshot *> *snapshots = [self snapshotsForPages: pages];
	[self runOnDecodeQueueWhileCurrent: isCurrent work: ^{
		[self decodeSnapshots: snapshots];
	} completion: completion];
}

- (void)predecodePages:(NSArray<TSSTPage *> *)pages
{
	NSArray<TSSTPageDataSnapshot *> *snapshots = [self snapshotsForPages: pages];
	dispatch_async(_decodeQueue, ^{
		[self decodeSnapshots: snapshots];
	});
}

- (void)removeAllObjects
{
	[_cache removeAllObjects];
}

@end
