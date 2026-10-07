/*
	Simple Comic
	TSSTCachingByteSource.h

  Wraps an upstream TSSTArchiveByteSource with a local disk cache, so
  repeated reads of the same range (typical when re-paging, or when a
  background streamer has already pulled a block) don't cost another
  round trip over a slow link. Demand reads (-readAtOffset:length:error:)
  fetch and cache whatever they need, coalescing missing blocks into as
  few upstream reads as possible; TSSTArchiveStreamer drives background
  prefetch through the same cache.
*/

#import <Foundation/Foundation.h>
#import "TSSTArchiveByteSource.h"

NS_ASSUME_NONNULL_BEGIN

extern const NSUInteger TSSTCachingByteSourceBlockSize; // 256 KB

@interface TSSTCachingByteSource : NSObject <TSSTArchiveByteSource>

- (instancetype)initWithUpstream:(id<TSSTArchiveByteSource>)upstream;

@property (nonatomic, readonly) id<TSSTArchiveByteSource> upstream;

/// Total bytes this source will keep cached. Defaults to
/// min(length, 25% of the temp volume's free space). Blocks are evicted
/// (farthest from -focusOffset first) to stay within budget.
@property (nonatomic) uint64_t maxCacheBytes;

/// Hint for eviction: blocks far from this offset are evicted first.
@property (nonatomic) uint64_t focusOffset;

/// Number of demand reads (from -readAtOffset:length:error:) currently
/// in flight and needing upstream data. TSSTArchiveStreamer checks this
/// before starting its next background chunk, so demand always wins.
@property (atomic, readonly) NSUInteger pendingDemandCount;

- (BOOL)isRangeCachedAtOffset:(uint64_t)offset length:(NSUInteger)length;
@property (nonatomic, readonly) uint64_t cachedByteCount;
@property (nonatomic, readonly) double cachedFraction;

/// Fetches and caches the given range if not already cached, at the
/// given priority; used by the streamer for background prefetch. Same
/// coalescing/wait-for-in-flight behavior as the demand path, but does
/// not count against -pendingDemandCount.
- (BOOL)prefetchAtOffset:(uint64_t)offset length:(NSUInteger)length error:(NSError * _Nullable * _Nullable)error;

/// Closes the backing file and deletes its temp directory. Safe to call
/// more than once. Also called from -dealloc.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
