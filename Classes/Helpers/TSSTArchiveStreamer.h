/*
	Simple Comic
	TSSTArchiveStreamer.h

  Background prefetcher that walks an ordered list of byte ranges
  ("spans", one per page in reading order) into a TSSTCachingByteSource
  on a single utility-QoS thread, so paging never has to wait on the
  network once the streamer gets ahead of the reader. Demand reads
  (UI paging) go straight to the caching source and always take
  priority: see TSSTCachingByteSource's -pendingDemandCount.
*/

#import <Foundation/Foundation.h>
#import "TSSTCachingByteSource.h"

@class TSSTZipIndex;

NS_ASSUME_NONNULL_BEGIN

@interface TSSTArchiveStreamer : NSObject

- (instancetype)initWithCachingByteSource:(TSSTCachingByteSource *)cachingSource spans:(NSArray<NSValue *> *)spans; // NSValue-boxed NSRange, one per page, offset/length within the archive

/// Convenience: builds spans (local-header-offset, size-hint) for the
/// given zip entry indices, in the given (reading) order, from a
/// TSSTZipIndex. Each span is clamped to the archive length.
+ (NSArray<NSValue *> *)spansForZipIndex:(TSSTZipIndex *)zipIndex entryIndices:(NSArray<NSNumber *> *)entryIndices;

/// As above, also returning entry index -> span index.
+ (NSArray<NSValue *> *)spansForZipIndex:(TSSTZipIndex *)zipIndex entryIndices:(NSArray<NSNumber *> *)entryIndices spanIndexMap:(NSDictionary<NSNumber *, NSNumber *> * _Nullable * _Nullable)outMap;

/// Generic span builder shared by every backend. Walks \c entryIndices in
/// reading order; \c rangeProvider yields each entry's byte range in the
/// archive (NO: the entry has no known range and stays unmapped). Entries
/// with an identical range share one span (a solid folder), so the result
/// has one span per distinct range. \c outMap receives entry index -> span
/// index for the mapped entries.
+ (NSArray<NSValue *> *)spansForEntryIndices:(NSArray<NSNumber *> *)entryIndices
								rangeProvider:(BOOL (^)(NSUInteger entryIndex, NSRange *outRange))rangeProvider
								 spanIndexMap:(NSDictionary<NSNumber *, NSNumber *> * _Nullable * _Nullable)outMap;

@property (nonatomic, readonly) NSArray<NSValue *> *spans;
@property (atomic) NSUInteger currentSpanIndex;

- (void)start;
- (void)cancel;

/// Jumps the reading position and wakes the worker immediately.
- (void)prioritizeSpanIndex:(NSUInteger)spanIndex;

/// When YES, a span's last chunk is never smaller than the minimum chunk:
/// the tail is folded into the previous request. For sets of page-sized
/// spans (loose image files), where a tail read costs a full round trip.
/// Off by default, so archive streaming keeps its exact chunking.
@property (nonatomic) BOOL avoidsRuntTailReads;

@property (atomic, readonly) BOOL isComplete;
@property (atomic, readonly) double throughputBytesPerSecond;

/// Called on the main thread, throttled to ~4 Hz.
@property (nonatomic, copy, nullable) void (^progressHandler)(NSIndexSet *cachedSpanIndexes, double cachedFraction, double throughputBytesPerSecond, BOOL isComplete);

@end

NS_ASSUME_NONNULL_END
