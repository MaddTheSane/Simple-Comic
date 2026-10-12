/*
	Simple Comic
	TSSTPageDecodeCache.h

  Holds fully-decoded NSImages for pages neighbouring the one currently on
  screen, so paging into them (once their bytes are locally cached) is a
  cache hit instead of a decode. Bounded by total decoded pixel bytes, not
  image count -- large single pages (e.g. 24 MB JPEG XL) must not evict
  each other out from under a size-based cache the way a count limit would.
*/

#import <Cocoa/Cocoa.h>

@class TSSTPage;

NS_ASSUME_NONNULL_BEGIN

@interface TSSTPageDecodeCache : NSObject

+ (instancetype)sharedCache;

/// A single serial background queue for all decode work. TSSTPage is an
/// NSManagedObject and reading its properties (including the -pageData /
/// -setOwnSizeInfoWithData: side effects a decode triggers) from more than
/// one thread at a time races the context's change-notification machinery
/// -- serializing every decode (whether it's the page the reader is
/// waiting on, or a background pre-decode of a neighbour) onto this one
/// queue avoids that without blocking the main thread.
@property (nonatomic, readonly) dispatch_queue_t decodeQueue;

/// Cached, already force-decoded image for `page`, or nil on a miss.
- (nullable NSImage *)imageForPage:(TSSTPage *)page;

/// Decodes `page`'s bytes and caches the result, keyed by objectID, cost =
/// pixelsWide * pixelsHigh * 4. Synchronous -- call from -decodeQueue only.
/// Does nothing (and does not touch the network) unless the caller has
/// already established it's safe to read `page` without blocking, e.g. via
/// -[TSSTManagedArchive isEntryIndexCached:] or a local file.
- (void)decodeAndCachePage:(TSSTPage *)page;

/// Queues `work` on -decodeQueue on behalf of a reader who is waiting for
/// it (a page turn or jump), then calls `completion` on the main queue.
/// `isCurrent` is asked (off-main, so it must be thread-safe) right before
/// `work` would start: if the reader has already moved on it returns NO,
/// `work` is skipped, and `completion` gets `ran` == NO. The queue is
/// serial, so without this every page the reader passed through on the way
/// (dragging the slider, paging quickly, a jump made while an earlier load
/// is still on the network) would still be fetched, one after another,
/// before the page they actually stopped on -- and each stale fetch would
/// also drag the streamer back to the page it was for.
- (void)runOnDecodeQueueWhileCurrent:(BOOL (^)(void))isCurrent
								work:(void (^)(void))work
						  completion:(void (^)(BOOL ran))completion;

/// -runOnDecodeQueueWhileCurrent:work:completion: over -decodeAndCachePage:
/// for each of `pages`, in order.
- (void)decodePages:(NSArray<TSSTPage *> *)pages
		whileCurrent:(BOOL (^)(void))isCurrent
		  completion:(void (^)(BOOL ran))completion;

- (void)removeAllObjects;

@end

NS_ASSUME_NONNULL_END
