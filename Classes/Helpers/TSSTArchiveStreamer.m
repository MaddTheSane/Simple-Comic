/*
	Simple Comic
	TSSTArchiveStreamer.m
*/

#import "TSSTArchiveStreamer.h"
#import "TSSTZipIndex.h"

static const NSUInteger kMinChunkSize = 256 * 1024;
static const NSUInteger kMaxChunkSize = 8 * 1024 * 1024;
static const NSTimeInterval kTargetChunkSeconds = 0.25;
static const NSTimeInterval kProgressInterval = 0.25; // 4 Hz

@interface TSSTArchiveStreamer ()
{
	TSSTCachingByteSource *_cache;
	NSArray<NSValue *> *_spans;
	dispatch_queue_t _queue;
	NSCondition *_wakeCond;
	BOOL _started;
	BOOL _cancelled;
	double _ewmaBytesPerSecond;
	NSDate *_lastProgressDate;
	BOOL _reportedComplete;
}
@end

@implementation TSSTArchiveStreamer

- (instancetype)initWithCachingByteSource:(TSSTCachingByteSource *)cachingSource spans:(NSArray<NSValue *> *)spans
{
	self = [super init];
	if (self)
	{
		_cache = cachingSource;
		_spans = [spans copy];
		_wakeCond = [NSCondition new];
		_queue = dispatch_queue_create("com.dancingtortoise.simplecomic.archivestreamer", DISPATCH_QUEUE_SERIAL);
		dispatch_set_target_queue(_queue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
	}
	return self;
}

+ (NSArray<NSValue *> *)spansForZipIndex:(TSSTZipIndex *)zipIndex entryIndices:(NSArray<NSNumber *> *)entryIndices
{
	NSMutableArray<NSValue *> *spans = [NSMutableArray arrayWithCapacity: entryIndices.count];
	uint64_t archiveLength = 0;
	// TSSTZipIndex has no direct -length; derive an upper bound from the
	// largest entry's offset + size hints so clamping below is safe even
	// without a dedicated accessor.
	for (NSNumber *n in entryIndices)
	{
		NSUInteger idx = n.unsignedIntegerValue;
		uint64_t end = [zipIndex dataOffsetHintForEntry: idx] + 30 + 512 + [zipIndex compressedSizeOfEntry: idx];
		if (end > archiveLength) { archiveLength = end; }
	}
	for (NSNumber *n in entryIndices)
	{
		NSUInteger idx = n.unsignedIntegerValue;
		uint64_t offset = [zipIndex dataOffsetHintForEntry: idx];
		uint64_t hint = 30 + 512 + [zipIndex compressedSizeOfEntry: idx];
		uint64_t remaining = offset < archiveLength ? archiveLength - offset : 0;
		NSUInteger len = (NSUInteger)MIN(hint, remaining);
		[spans addObject: [NSValue valueWithRange: NSMakeRange((NSUInteger)offset, len)]];
	}
	return spans;
}

- (NSArray<NSValue *> *)spans { return _spans; }

- (void)setCurrentSpanIndex:(NSUInteger)currentSpanIndex
{
	[_wakeCond lock];
	_currentSpanIndex = currentSpanIndex;
	[_wakeCond signal];
	[_wakeCond unlock];
}

- (void)prioritizeSpanIndex:(NSUInteger)spanIndex
{
	self.currentSpanIndex = spanIndex;
}

- (void)start
{
	[_wakeCond lock];
	if (_started) { [_wakeCond unlock]; return; }
	_started = YES;
	[_wakeCond unlock];

	__weak typeof(self) weakSelf = self;
	dispatch_async(_queue, ^{
		[weakSelf runLoop];
	});
}

- (void)cancel
{
	[_wakeCond lock];
	_cancelled = YES;
	[_wakeCond signal];
	[_wakeCond unlock];
}

- (BOOL)isCancelled
{
	BOOL c;
	[_wakeCond lock];
	c = _cancelled;
	[_wakeCond unlock];
	return c;
}

#pragma mark - Worker

- (nullable NSNumber *)nextUncachedSpanIndex
{
	NSUInteger count = _spans.count;
	if (count == 0) { return nil; }
	NSUInteger start = self.currentSpanIndex % count;
	/* Priority order: a few pages ahead of the reader, then a few behind
	 (so paging back after a jump doesn't wait), then everything else
	 forward, wrapping to the start. */
	static const NSUInteger kAheadPriority = 8, kBehindPriority = 3;
	BOOL (^uncached)(NSUInteger) = ^BOOL(NSUInteger idx) {
		NSRange span = self->_spans[idx].rangeValue;
		return ![self->_cache isRangeCachedAtOffset: span.location length: span.length];
	};
	for (NSUInteger i = 0; i < MIN(kAheadPriority, count); ++i)
	{
		NSUInteger idx = (start + i) % count;
		if (start + i < count && uncached(idx)) { return @(idx); }
	}
	for (NSUInteger i = 1; i <= kBehindPriority && i <= start; ++i)
	{
		if (uncached(start - i)) { return @(start - i); }
	}
	for (NSUInteger i = 0; i < count; ++i)
	{
		NSUInteger idx = (start + i) % count;
		if (uncached(idx)) { return @(idx); }
	}
	return nil;
}

/// Extends forward from startIndex (no wraparound) while spans are
/// uncached and file-adjacent, returning the merged file range.
- (NSRange)mergedRunStartingAtSpanIndex:(NSUInteger)startIndex
{
	NSRange run = _spans[startIndex].rangeValue;
	uint64_t runEnd = run.location + run.length;
	NSUInteger idx = startIndex + 1;
	while (idx < _spans.count)
	{
		NSRange next = _spans[idx].rangeValue;
		if (next.location != runEnd) { break; }
		if ([_cache isRangeCachedAtOffset: next.location length: next.length]) { break; }
		runEnd += next.length;
		++idx;
	}
	return NSMakeRange(run.location, (NSUInteger)(runEnd - run.location));
}

- (NSUInteger)adaptiveChunkSizeForRemaining:(NSUInteger)remaining
{
	double target = _ewmaBytesPerSecond > 0 ? _ewmaBytesPerSecond * kTargetChunkSeconds : kMinChunkSize;
	NSUInteger size = (NSUInteger)MAX((double)kMinChunkSize, MIN((double)kMaxChunkSize, target));
	return MIN(size, MAX(remaining, kMinChunkSize));
}

- (void)waitForPendingDemand
{
	while (_cache.pendingDemandCount > 0 && ![self isCancelled])
	{
		usleep(1000);
	}
}

- (void)runLoop
{
	while (![self isCancelled])
	{
		NSNumber *nextIndex = [self nextUncachedSpanIndex];
		if (!nextIndex)
		{
			[self reportProgressForce: YES];
			return; // complete
		}

		NSRange run = [self mergedRunStartingAtSpanIndex: nextIndex.unsignedIntegerValue];
		uint64_t offset = run.location;
		uint64_t runEnd = run.location + run.length;
		NSUInteger runTarget = self.currentSpanIndex;

		while (offset < runEnd && ![self isCancelled])
		{
			// The reader jumped: re-pick the next span around the new position.
			if (self.currentSpanIndex != runTarget) { break; }
			[self waitForPendingDemand];
			if ([self isCancelled]) { break; }

			NSUInteger remaining = (NSUInteger)(runEnd - offset);
			NSUInteger chunkLen = [self adaptiveChunkSizeForRemaining: remaining];
			chunkLen = MIN(chunkLen, remaining);

			NSDate *startTime = [NSDate date];
			_cache.focusOffset = offset;
			NSError *err = nil;
			[_cache prefetchAtOffset: offset length: chunkLen error: &err];
			NSTimeInterval elapsed = -[startTime timeIntervalSinceNow];
			if (elapsed > 0)
			{
				double sample = (double)chunkLen / elapsed;
				_ewmaBytesPerSecond = _ewmaBytesPerSecond > 0 ? (0.3 * sample + 0.7 * _ewmaBytesPerSecond) : sample;
			}

			offset += chunkLen;
			[self reportProgressForce: NO];
		}
		// A throttled chunk report may have been the last word before a
		// retarget or a long wait for demand reads: always end a run with a
		// report so the UI never keeps showing a stale set.
		[self reportProgressForce: YES];
	}
}

#pragma mark - Progress / completion

- (BOOL)isComplete
{
	for (NSValue *v in _spans)
	{
		NSRange span = v.rangeValue;
		if (![_cache isRangeCachedAtOffset: span.location length: span.length]) { return NO; }
	}
	return YES;
}

- (double)throughputBytesPerSecond
{
	return _ewmaBytesPerSecond;
}


- (void)reportProgressForce:(BOOL)force
{
	if (!self.progressHandler) { return; }
	if (_reportedComplete) { return; }
	NSDate *now = [NSDate date];
	if (!force && _lastProgressDate && -[_lastProgressDate timeIntervalSinceNow] < kProgressInterval) { return; }
	_lastProgressDate = now;

	NSMutableIndexSet *cachedSpans = [NSMutableIndexSet indexSet];
	for (NSUInteger i = 0; i < _spans.count; ++i)
	{
		NSRange span = _spans[i].rangeValue;
		if ([_cache isRangeCachedAtOffset: span.location length: span.length]) { [cachedSpans addIndex: i]; }
	}
	double fraction = _spans.count ? (double)cachedSpans.count / (double)_spans.count : 1.0;
	BOOL complete = cachedSpans.count == _spans.count;
	if (complete) { _reportedComplete = YES; }
	double throughput = _ewmaBytesPerSecond;
	void (^handler)(NSIndexSet *, double, double, BOOL) = self.progressHandler;

	dispatch_async(dispatch_get_main_queue(), ^{
		handler(cachedSpans, fraction, throughput, complete);
	});
}

@end
