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
static const NSUInteger kMaxConsecutiveFailures = 5;
static const NSTimeInterval kMaxRetryDelay = 8.0;

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
	NSUInteger _consecutiveFailures;
	NSError *_failureError;
	NSMutableIndexSet *_overBudgetSpans; // spans a prefetch rejected as too big for the cache; skipped for good (guarded by _wakeCond)
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
		_retryBaseDelay = 0.5;
		_overBudgetSpans = [NSMutableIndexSet indexSet];
		_queue = dispatch_queue_create("com.dancingtortoise.simplecomic.archivestreamer", DISPATCH_QUEUE_SERIAL);
		dispatch_set_target_queue(_queue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
	}
	return self;
}

+ (NSArray<NSValue *> *)spansForEntryIndices:(NSArray<NSNumber *> *)entryIndices
								rangeProvider:(BOOL (^)(NSUInteger entryIndex, NSRange *outRange))rangeProvider
								 spanIndexMap:(NSDictionary<NSNumber *, NSNumber *> * _Nullable * _Nullable)outMap
{
	NSMutableArray<NSValue *> *spans = [NSMutableArray arrayWithCapacity: entryIndices.count];
	NSMutableDictionary<NSNumber *, NSNumber *> *map = [NSMutableDictionary dictionaryWithCapacity: entryIndices.count];
	NSMutableDictionary<NSValue *, NSNumber *> *spanForRange = [NSMutableDictionary dictionary];
	for (NSNumber *n in entryIndices)
	{
		NSRange range;
		if (!rangeProvider(n.unsignedIntegerValue, &range)) { continue; }
		NSValue *key = [NSValue valueWithRange: range];
		NSNumber *spanIndex = spanForRange[key];
		if (!spanIndex)
		{
			// First entry with this range (a solid 7z folder shares one
			// range across all its files): contribute a new span.
			spanIndex = @(spans.count);
			spanForRange[key] = spanIndex;
			[spans addObject: key];
		}
		map[n] = spanIndex;
	}
	if (outMap) { *outMap = map; }
	return spans;
}

+ (NSArray<NSValue *> *)spansForZipIndex:(TSSTZipIndex *)zipIndex entryIndices:(NSArray<NSNumber *> *)entryIndices
{
	return [self spansForZipIndex: zipIndex entryIndices: entryIndices spanIndexMap: NULL];
}

+ (NSArray<NSValue *> *)spansForZipIndex:(TSSTZipIndex *)zipIndex entryIndices:(NSArray<NSNumber *> *)entryIndices spanIndexMap:(NSDictionary<NSNumber *, NSNumber *> * _Nullable * _Nullable)outMap
{
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
	return [self spansForEntryIndices: entryIndices rangeProvider: ^BOOL(NSUInteger idx, NSRange *outRange) {
		uint64_t offset = [zipIndex dataOffsetHintForEntry: idx];
		uint64_t hint = 30 + 512 + [zipIndex compressedSizeOfEntry: idx];
		uint64_t remaining = offset < archiveLength ? archiveLength - offset : 0;
		*outRange = NSMakeRange((NSUInteger)offset, (NSUInteger)MIN(hint, remaining));
		return YES;
	} spanIndexMap: outMap];
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
	[_cache wakeWaiters]; // end a wait for demand reads
}

- (NSError *)failureError
{
	[_wakeCond lock];
	NSError *e = _failureError;
	[_wakeCond unlock];
	return e;
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
		return ![self->_cache isRangeCachedAtOffset: span.location length: span.length] && ![self spanIsUncacheable: idx];
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

/// YES for a span the cache can never hold whole (bigger than its budget):
/// it is left to demand reads, and doesn't count against completion.
- (BOOL)spanIsUncacheable:(NSUInteger)spanIndex
{
	[_wakeCond lock];
	BOOL rejected = [_overBudgetSpans containsIndex: spanIndex];
	[_wakeCond unlock];
	if (rejected) { return YES; }
	NSRange span = _spans[spanIndex].rangeValue;
	return ![_cache canCacheRangeAtOffset: span.location length: span.length];
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
		if ([_cache isRangeCachedAtOffset: next.location length: next.length] || [self spanIsUncacheable: idx]) { break; }
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
	[_cache waitForNoPendingDemandWhile:^BOOL{ return ![self isCancelled]; }];
}

/// Sleeps out the backoff before retrying a failed chunk (exponential,
/// capped); cancelling or retargeting the reader wakes it early.
- (void)waitBeforeRetry
{
	NSTimeInterval delay = MIN(_retryBaseDelay * pow(2.0, (double)(_consecutiveFailures - 1)), kMaxRetryDelay);
	NSDate *until = [NSDate dateWithTimeIntervalSinceNow: delay];
	[_wakeCond lock];
	if (!_cancelled) { [_wakeCond waitUntilDate: until]; }
	[_wakeCond unlock];
}

- (void)giveUpWithError:(NSError *)error
{
	error = error ?: [NSError errorWithDomain: TSSTArchiveByteSourceErrorDomain code: TSSTArchiveByteSourceErrorIO userInfo: nil];
	[_wakeCond lock];
	_failureError = error;
	[_wakeCond unlock];
	[self reportProgressForce: YES];
	void (^handler)(NSError *) = self.failureHandler;
	if (handler)
	{
		dispatch_async(dispatch_get_main_queue(), ^{ handler(error); });
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
			NSUInteger fittingLen = MIN(remaining, [_cache maxPrefetchLengthAtOffset: offset]); // what the cache budget accepts
			chunkLen = MIN(chunkLen, fittingLen);
			if (_avoidsRuntTailReads && remaining - chunkLen < kMinChunkSize) { chunkLen = fittingLen; }

			NSDate *startTime = [NSDate date];
			uint64_t cachedBefore = _cache.cachedByteCount;
			_cache.focusOffset = offset;
			NSError *err = nil;
			BOOL prefetchOK = [_cache prefetchAtOffset: offset length: chunkLen error: &err];
			if (!prefetchOK)
			{
				if ([err.domain isEqualToString: TSSTCachingByteSourceErrorDomain] && err.code == TSSTCachingByteSourceErrorOverBudget)
				{
					// Not a transient failure: retrying can't help, and it must
					// not count toward giving up on every other span. Skip the
					// span and re-pick.
					[_wakeCond lock];
					[_overBudgetSpans addIndex: nextIndex.unsignedIntegerValue];
					[_wakeCond unlock];
					break;
				}
				// Don't skip the chunk or re-pick it at once (a hot spin on a
				// dead link): back off, retry, and stop after repeated failures.
				if (++_consecutiveFailures >= kMaxConsecutiveFailures)
				{
					[self giveUpWithError: err];
					return;
				}
				[self waitBeforeRetry];
				continue;
			}
			_consecutiveFailures = 0;
			NSTimeInterval elapsed = -[startTime timeIntervalSinceNow];
			// Only bytes that really crossed the link say anything about its
			// speed: an already-cached chunk "downloads" at memory speed and
			// would inflate the estimate, and with it the chunk size and how
			// long a demand read can sit behind an in-flight chunk.
			uint64_t cachedAfter = _cache.cachedByteCount;
			uint64_t fetched = cachedAfter > cachedBefore ? cachedAfter - cachedBefore : 0;
			if (elapsed > 0 && fetched > 0)
			{
				double sample = (double)fetched / elapsed;
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
	for (NSUInteger i = 0; i < _spans.count; ++i)
	{
		NSRange span = _spans[i].rangeValue;
		if (![_cache isRangeCachedAtOffset: span.location length: span.length] && ![self spanIsUncacheable: i]) { return NO; }
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

	NSIndexSet *cachedSpans = [_cache indexesOfCachedRanges: _spans];
	NSUInteger settled = cachedSpans.count; // cached, or never going to be
	for (NSUInteger i = 0; i < _spans.count; ++i)
	{
		if (![cachedSpans containsIndex: i] && [self spanIsUncacheable: i]) { ++settled; }
	}
	double fraction = _spans.count ? (double)settled / (double)_spans.count : 1.0;
	BOOL complete = settled == _spans.count;
	if (complete) { _reportedComplete = YES; }
	double throughput = _ewmaBytesPerSecond;
	void (^handler)(NSIndexSet *, double, double, BOOL) = self.progressHandler;

	dispatch_async(dispatch_get_main_queue(), ^{
		handler(cachedSpans, fraction, throughput, complete);
	});
}

@end
