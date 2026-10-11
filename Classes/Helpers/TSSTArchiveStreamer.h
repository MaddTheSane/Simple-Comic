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

@property (nonatomic, readonly) NSArray<NSValue *> *spans;
@property (atomic) NSUInteger currentSpanIndex;

- (void)start;
- (void)cancel;

/// Jumps the reading position and wakes the worker immediately.
- (void)prioritizeSpanIndex:(NSUInteger)spanIndex;

@property (atomic, readonly) BOOL isComplete;
@property (atomic, readonly) double throughputBytesPerSecond;

/// Called on the main thread, throttled to ~4 Hz.
@property (nonatomic, copy, nullable) void (^progressHandler)(NSIndexSet *cachedSpanIndexes, double cachedFraction, double throughputBytesPerSecond, BOOL isComplete);

@end

NS_ASSUME_NONNULL_END
