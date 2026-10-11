/*
	Simple Comic
	TSSTCachingByteSource.m
*/

#import "TSSTCachingByteSource.h"
#import <sys/stat.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>

// Small on purpose: RAR4 header walks read a few dozen bytes per entry, each
// in a different place, and every such read fetches a whole block. At 256 KB
// that was ~52 ms of transfer per entry at 5 MB/s; at 16 KB it is ~3 ms.
// Streaming reads span many blocks and are coalesced into single upstream
// requests, so a small block costs them nothing.
const NSUInteger TSSTCachingByteSourceBlockSize = 16 * 1024;

NSErrorDomain const TSSTCachingByteSourceErrorDomain = @"TSSTCachingByteSourceErrorDomain";

static NSError *TSSTByteSourceOffsetPastEOFError(void);

static NSError *TSSTCachingError(NSString *description)
{
	return [NSError errorWithDomain: TSSTArchiveByteSourceErrorDomain code: TSSTArchiveByteSourceErrorIO userInfo: @{ NSLocalizedDescriptionKey: description }];
}

@interface TSSTCachingByteSource ()
{
	id<TSSTArchiveByteSource> _upstream;
	uint64_t _length;
	int _fd;
	NSString *_cacheDir;
	NSString *_cacheFilePath;
	BOOL _invalidated;

	NSCondition *_cond; // guards everything below, _invalidated and closing _fd
	NSMutableIndexSet *_cachedBlocks;
	NSMutableIndexSet *_inFlightBlocks;
	NSUInteger _pendingDemandCount;
	NSMutableArray<NSValue *> *_pinnedRanges; // block ranges being read; never evicted
	NSUInteger _activeIO; // pread/pwrite calls using _fd; -invalidate waits for zero
}
@end

@implementation TSSTCachingByteSource

- (instancetype)initWithUpstream:(id<TSSTArchiveByteSource>)upstream
{
	self = [super init];
	if (self)
	{
		_upstream = upstream;
		_length = upstream.length;
		_cond = [NSCondition new];
		_cachedBlocks = [NSMutableIndexSet indexSet];
		_inFlightBlocks = [NSMutableIndexSet indexSet];
		_pinnedRanges = [NSMutableArray array];
		_fd = -1;

		NSString *dirName = [NSString stringWithFormat: @"SimpleComic-cache-%@", [[NSUUID UUID] UUIDString]];
		_cacheDir = [NSTemporaryDirectory() stringByAppendingPathComponent: dirName];
		[[NSFileManager defaultManager] createDirectoryAtPath: _cacheDir withIntermediateDirectories: YES attributes: nil error: NULL];
		_cacheFilePath = [_cacheDir stringByAppendingPathComponent: @"cache.dat"];

		int fd = open(_cacheFilePath.fileSystemRepresentation, O_RDWR | O_CREAT, 0600);
		if (fd >= 0)
		{
			ftruncate(fd, (off_t)_length);
		}
		_fd = fd;

		_maxCacheBytes = [self defaultMaxCacheBytes];
	}
	return self;
}

- (uint64_t)defaultMaxCacheBytes
{
	uint64_t freeSpace = 0;
	NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath: _cacheDir error: NULL];
	NSNumber *freeSize = attrs[NSFileSystemFreeSize];
	if (freeSize) { freeSpace = freeSize.unsignedLongLongValue; }
	uint64_t quarterFree = freeSpace / 4;
	return MIN(_length, quarterFree);
}

- (uint64_t)length
{
	return _length;
}

- (id<TSSTArchiveByteSource>)upstream
{
	return _upstream;
}

- (NSUInteger)pendingDemandCount
{
	NSUInteger count;
	[_cond lock];
	count = _pendingDemandCount;
	[_cond unlock];
	return count;
}

#pragma mark - Block math

- (NSUInteger)numberOfBlocks
{
	if (_length == 0) { return 0; }
	return (NSUInteger)((_length + TSSTCachingByteSourceBlockSize - 1) / TSSTCachingByteSourceBlockSize);
}

- (NSRange)blockRangeForOffset:(uint64_t)offset length:(NSUInteger)length
{
	if (length == 0) { return NSMakeRange(0, 0); }
	NSUInteger firstBlock = (NSUInteger)(offset / TSSTCachingByteSourceBlockSize);
	uint64_t lastByte = offset + length - 1;
	NSUInteger lastBlock = (NSUInteger)(lastByte / TSSTCachingByteSourceBlockSize);
	return NSMakeRange(firstBlock, lastBlock - firstBlock + 1);
}

- (uint64_t)offsetForBlock:(NSUInteger)block
{
	return (uint64_t)block * TSSTCachingByteSourceBlockSize;
}

- (NSUInteger)lengthForBlock:(NSUInteger)block
{
	uint64_t start = [self offsetForBlock: block];
	uint64_t remaining = _length > start ? _length - start : 0;
	return (NSUInteger)MIN((uint64_t)TSSTCachingByteSourceBlockSize, remaining);
}

#pragma mark - Budget / pinning / fd access

/// The most blocks the cache keeps, or NSUIntegerMax when unbudgeted.
- (NSUInteger)maxCachedBlocks
{
	uint64_t budget = _maxCacheBytes;
	if (budget == 0 || budget >= _length) { return NSUIntegerMax; }
	return (NSUInteger)(budget / TSSTCachingByteSourceBlockSize) + 1;
}

/// Protects `blockRange` from eviction until -unpinBlockRange:.
- (NSValue *)pinBlockRange:(NSRange)blockRange
{
	NSValue *pin = [NSValue valueWithRange: blockRange];
	[_cond lock];
	[_pinnedRanges addObject: pin];
	[_cond unlock];
	return pin;
}

- (void)unpinBlockRange:(NSValue *)pin
{
	[_cond lock];
	NSUInteger i = [_pinnedRanges indexOfObjectIdenticalTo: pin];
	if (i != NSNotFound) { [_pinnedRanges removeObjectAtIndex: i]; }
	[_cond unlock];
	[self enforceBudget]; // pinned blocks may have kept the cache over budget
}

/// Runs `work` with `blockRange` pinned, so the pin and its release can't
/// come apart.
- (void)whilePinningBlockRange:(NSRange)blockRange do:(void (^)(void))work
{
	NSValue *pin = [self pinBlockRange: blockRange];
	work();
	[self unpinBlockRange: pin];
}

/// Brackets a pread/pwrite on _fd: -invalidate waits for these to finish
/// before closing. Returns NO (and the fd must not be used) once invalidated.
- (BOOL)beginIO
{
	[_cond lock];
	BOOL ok = !_invalidated && _fd >= 0;
	if (ok) { _activeIO++; }
	[_cond unlock];
	return ok;
}

- (void)endIO
{
	[_cond lock];
	if (--_activeIO == 0) { [_cond broadcast]; }
	[_cond unlock];
}

- (BOOL)isInvalidated
{
	[_cond lock];
	BOOL invalidated = _invalidated;
	[_cond unlock];
	return invalidated;
}

#pragma mark - Cached range queries

- (BOOL)isRangeCachedAtOffset:(uint64_t)offset length:(NSUInteger)length
{
	// Bytes past the end of the file don't exist to be cached: a span whose
	// size hint overshoots EOF (a zip's last entry, hinted with slack for
	// its local header) would otherwise never read as cached, leaving the
	// streamer retrying it forever and its page permanently "uncached".
	BOOL result;
	[_cond lock];
	result = [self isRangeCachedLockedAtOffset: offset length: length];
	[_cond unlock];
	return result;
}

/// -isRangeCachedAtOffset:length: with _cond already held.
- (BOOL)isRangeCachedLockedAtOffset:(uint64_t)offset length:(NSUInteger)length
{
	return [self isRangeAtOffset: offset length: length cachedIn: _cachedBlocks];
}

- (BOOL)isRangeAtOffset:(uint64_t)offset length:(NSUInteger)length cachedIn:(NSIndexSet *)cachedBlocks
{
	if (offset >= _length) { return YES; }
	length = (NSUInteger)MIN((uint64_t)length, _length - offset);
	if (length == 0) { return YES; }
	return [cachedBlocks containsIndexesInRange: [self blockRangeForOffset: offset length: length]];
}

- (NSIndexSet *)indexesOfCachedRanges:(NSArray<NSValue *> *)ranges
{
	// Evaluate against a snapshot so a long list doesn't hold up readers.
	NSIndexSet *cachedBlocks;
	[_cond lock];
	cachedBlocks = [_cachedBlocks copy];
	[_cond unlock];

	NSMutableIndexSet *result = [NSMutableIndexSet indexSet];
	[ranges enumerateObjectsUsingBlock:^(NSValue *v, NSUInteger i, BOOL *stop) {
		NSRange r = v.rangeValue;
		if ([self isRangeAtOffset: r.location length: r.length cachedIn: cachedBlocks]) { [result addIndex: i]; }
	}];
	return result;
}

- (BOOL)canCacheRangeAtOffset:(uint64_t)offset length:(NSUInteger)length
{
	if (offset >= _length || length == 0) { return YES; }
	length = (NSUInteger)MIN((uint64_t)length, _length - offset);
	return [self blockRangeForOffset: offset length: length].length <= [self maxCachedBlocks];
}

- (NSUInteger)maxPrefetchLengthAtOffset:(uint64_t)offset
{
	NSUInteger maxBlocks = [self maxCachedBlocks];
	if (maxBlocks == NSUIntegerMax) { return NSUIntegerMax; }
	// Up to the end of the maxBlocks-th block counting from offset's own.
	uint64_t firstBlock = offset / TSSTCachingByteSourceBlockSize;
	return (NSUInteger)(([self offsetForBlock: (NSUInteger)firstBlock] + (uint64_t)maxBlocks * TSSTCachingByteSourceBlockSize) - offset);
}

- (void)waitForNoPendingDemandWhile:(BOOL (^)(void))keepWaiting
{
	[_cond lock];
	while (_pendingDemandCount > 0 && keepWaiting())
	{
		[_cond wait];
	}
	[_cond unlock];
}

- (void)wakeWaiters
{
	[_cond lock];
	[_cond broadcast];
	[_cond unlock];
}

- (uint64_t)cachedByteCount
{
	NSUInteger blocks;
	[_cond lock];
	blocks = _cachedBlocks.count;
	[_cond unlock];
	return (uint64_t)blocks * TSSTCachingByteSourceBlockSize;
}

- (double)cachedFraction
{
	NSUInteger total = self.numberOfBlocks;
	if (total == 0) { return 1.0; }
	NSUInteger cached;
	[_cond lock];
	cached = _cachedBlocks.count;
	[_cond unlock];
	return (double)cached / (double)total;
}

#pragma mark - Fetch / read

/// Claims (marks in-flight) any blocks within blockRange that are neither
/// cached nor already in flight, waiting out blocks claimed by someone
/// else. Returns the set of blocks this call claimed (caller must fetch
/// them and call -commitFetchedBlocks:success:). Must be called with
/// _cond unlocked; locks/unlocks internally, possibly blocking.
- (NSIndexSet *)claimUncachedBlocksInRange:(NSRange)blockRange
{
	NSMutableIndexSet *claimed = [NSMutableIndexSet indexSet];
	[_cond lock];
	while (YES)
	{
		BOOL anyInFlight = NO;
		[claimed removeAllIndexes];
		for (NSUInteger b = blockRange.location; b < NSMaxRange(blockRange); ++b)
		{
			if ([_cachedBlocks containsIndex: b]) { continue; }
			if ([_inFlightBlocks containsIndex: b]) { anyInFlight = YES; continue; }
			[claimed addIndex: b];
		}
		if (_invalidated)
		{
			[claimed removeAllIndexes];
			break;
		}
		if (claimed.count > 0)
		{
			[_inFlightBlocks addIndexes: claimed];
			break;
		}
		if (!anyInFlight)
		{
			break; // everything already cached
		}
		[_cond wait];
	}
	[_cond unlock];
	return claimed;
}

- (void)commitFetchedBlocks:(NSIndexSet *)blocks success:(BOOL)success
{
	[_cond lock];
	[_inFlightBlocks removeIndexes: blocks];
	if (success)
	{
		[_cachedBlocks addIndexes: blocks];
	}
	[_cond broadcast];
	[_cond unlock];

	if (success)
	{
		[self enforceBudget];
	}
}

/// Fetches every block in `claimed` from upstream, coalescing contiguous
/// runs into single upstream reads, and writes them to the temp file.
- (BOOL)fetchClaimedBlocks:(NSIndexSet *)claimed error:(NSError * _Nullable * _Nullable)error
{
	if (claimed.count == 0) { return YES; }
	__block BOOL ok = YES;
	__block NSError *fetchError = nil;

	NSMutableArray<NSValue *> *runs = [NSMutableArray array]; // NSRange of block indices, contiguous
	[claimed enumerateRangesUsingBlock:^(NSRange range, BOOL * _Nonnull stop) {
		[runs addObject: [NSValue valueWithRange: range]];
	}];

	for (NSValue *runValue in runs)
	{
		if (!ok) { break; }
		NSRange run = runValue.rangeValue;
		uint64_t runOffset = [self offsetForBlock: run.location];
		NSUInteger lastBlockOfRun = run.location + run.length - 1;
		uint64_t runEnd = [self offsetForBlock: lastBlockOfRun] + [self lengthForBlock: lastBlockOfRun];
		NSUInteger runLength = (NSUInteger)(runEnd - runOffset);
		if (runLength == 0) { continue; }

		NSError *readError = nil;
		NSData *data = [_upstream readAtOffset: runOffset length: runLength error: &readError];
		if (!data)
		{
			ok = NO;
			fetchError = readError ?: TSSTCachingError(@"Upstream read failed.");
			break;
		}
		if (data.length > 0)
		{
			if (![self beginIO])
			{
				ok = NO;
				fetchError = TSSTCachingError(@"Cache invalidated.");
				break;
			}
			const uint8_t *bytes = data.bytes;
			NSUInteger written = 0;
			while (written < data.length)
			{
				ssize_t n = pwrite(_fd, bytes + written, data.length - written, (off_t)(runOffset + written));
				if (n < 0)
				{
					if (errno == EINTR) { continue; }
					ok = NO;
					fetchError = TSSTCachingError(@"pwrite failed.");
					break;
				}
				written += (NSUInteger)n;
			}
			[self endIO];
		}
	}

	if (!ok && error) { *error = fetchError; }
	return ok;
}

- (nullable NSData *)readAtOffset:(uint64_t)offset length:(NSUInteger)length error:(NSError * _Nullable * _Nullable)error
{
	if (offset > _length)
	{
		if (error) { *error = TSSTByteSourceOffsetPastEOFError(); }
		return nil;
	}
	NSUInteger wanted = (NSUInteger)MIN((uint64_t)length, _length - offset);
	if (wanted == 0) { return [NSData data]; }

	[_cond lock];
	_pendingDemandCount++;
	[_cond unlock];

	__block NSData *result = nil;
	NSRange blockRange = [self blockRangeForOffset: offset length: wanted];
	if (blockRange.length > [self maxCachedBlocks])
	{
		// Bigger than the whole budget: it could never be cached at once
		// (fetching it would just evict its own head), so read it straight
		// through.
		result = [_upstream readAtOffset: offset length: wanted error: error];
	}
	else
	{
		// Pinned so a concurrent commit's eviction can't punch a hole in
		// the range between fetching it and reading it back.
		__block NSError *readError = nil;
		[self whilePinningBlockRange: blockRange do:^{
			if ([self ensureCachedAtOffset: offset length: wanted error: &readError])
			{
				result = [self readFromCacheAtOffset: offset length: wanted];
				if (!result) { readError = TSSTCachingError(@"Cache read failed."); }
			}
		}];
		if (!result && error) { *error = readError; }
	}

	[_cond lock];
	_pendingDemandCount--;
	[_cond broadcast];
	[_cond unlock];

	return result;
}

- (BOOL)prefetchAtOffset:(uint64_t)offset length:(NSUInteger)length error:(NSError * _Nullable * _Nullable)error
{
	if (offset >= _length || length == 0) { return YES; }
	NSUInteger wanted = (NSUInteger)MIN((uint64_t)length, _length - offset);
	self.focusOffset = offset;
	NSRange blockRange = [self blockRangeForOffset: offset length: wanted];
	if (blockRange.length > [self maxCachedBlocks])
	{
		if (error) { *error = [NSError errorWithDomain: TSSTCachingByteSourceErrorDomain code: TSSTCachingByteSourceErrorOverBudget userInfo: @{ NSLocalizedDescriptionKey: @"Range is larger than the cache budget." }]; }
		return NO;
	}
	__block BOOL ok = NO;
	__block NSError *fetchError = nil;
	[self whilePinningBlockRange: blockRange do:^{
		ok = [self ensureCachedAtOffset: offset length: wanted error: &fetchError];
	}];
	if (!ok && error) { *error = fetchError; }
	return ok;
}

- (BOOL)ensureCachedAtOffset:(uint64_t)offset length:(NSUInteger)length error:(NSError * _Nullable * _Nullable)error
{
	NSRange blockRange = [self blockRangeForOffset: offset length: length];
	while (YES)
	{
		NSIndexSet *claimed = [self claimUncachedBlocksInRange: blockRange];
		if (claimed.count == 0)
		{
			// Either fully cached, or everything left was claimed by
			// someone else and is now cached -- verify. (An invalidated
			// cache claims nothing and caches nothing: stop there.)
			if ([self isRangeCachedAtOffset: offset length: length]) { return YES; }
			if ([self isInvalidated])
			{
				if (error) { *error = TSSTCachingError(@"Cache invalidated."); }
				return NO;
			}
			continue;
		}
		NSError *fetchError = nil;
		BOOL ok = [self fetchClaimedBlocks: claimed error: &fetchError];
		[self commitFetchedBlocks: claimed success: ok];
		if (!ok)
		{
			if (error) { *error = fetchError; }
			return NO;
		}
	}
}

- (nullable NSData *)readFromCacheAtOffset:(uint64_t)offset length:(NSUInteger)length
{
	if (![self beginIO]) { return nil; }
	NSMutableData *buf = [NSMutableData dataWithLength: length];
	uint8_t *bytes = buf.mutableBytes;
	NSUInteger totalRead = 0;
	BOOL failed = NO;
	while (totalRead < length)
	{
		ssize_t got = pread(_fd, bytes + totalRead, length - totalRead, (off_t)(offset + totalRead));
		if (got < 0)
		{
			if (errno == EINTR) { continue; }
			failed = YES;
			break;
		}
		if (got == 0) { break; }
		totalRead += (NSUInteger)got;
	}
	[self endIO];
	if (failed) { return nil; }
	if (totalRead != length) { buf.length = totalRead; }
	return buf;
}

#pragma mark - Budget / eviction

- (void)enforceBudget
{
	NSUInteger maxBlocks = [self maxCachedBlocks];
	if (maxBlocks == NSUIntegerMax) { return; }

	// Eviction and the hole punch happen under the lock so a block is never
	// both forgotten and still being read; pinned blocks are never evicted.
	[_cond lock];
	if (_cachedBlocks.count <= maxBlocks) { [_cond unlock]; return; }

	// Eviction candidates: everything cached that isn't pinned.
	NSMutableIndexSet *candidates = [_cachedBlocks mutableCopy];
	for (NSValue *pin in _pinnedRanges) { [candidates removeIndexesInRange: pin.rangeValue]; }

	// The block farthest from the focus is always the first or last of the
	// candidates, so take whichever end is farther, toEvict times.
	NSUInteger focusBlock = (NSUInteger)(_focusOffset / TSSTCachingByteSourceBlockSize);
	NSUInteger toEvict = _cachedBlocks.count - maxBlocks;
	NSMutableIndexSet *evicted = [NSMutableIndexSet indexSet];
	for (NSUInteger i = 0; i < toEvict && candidates.count > 0; ++i)
	{
		NSUInteger first = candidates.firstIndex, last = candidates.lastIndex;
		NSUInteger firstDistance = first > focusBlock ? first - focusBlock : focusBlock - first;
		NSUInteger lastDistance = last > focusBlock ? last - focusBlock : focusBlock - last;
		NSUInteger victim = firstDistance >= lastDistance ? first : last;
		[candidates removeIndex: victim];
		[evicted addIndex: victim];
	}
	[_cachedBlocks removeIndexes: evicted];

	[evicted enumerateRangesUsingBlock:^(NSRange range, BOOL * _Nonnull stop) {
		uint64_t start = [self offsetForBlock: range.location];
		NSUInteger lastBlock = range.location + range.length - 1;
		uint64_t end = [self offsetForBlock: lastBlock] + [self lengthForBlock: lastBlock];
		[self punchHoleAtOffset: start length: (NSUInteger)(end - start)];
	}];
	[_cond unlock];
}

/// Called with _cond held (so _fd can't be closed underneath it).
- (void)punchHoleAtOffset:(uint64_t)offset length:(NSUInteger)length
{
	if (_fd < 0 || length == 0) { return; }
#ifdef F_PUNCHHOLE
	fpunchhole_t hole = { .fp_flags = 0, .reserved = 0, .fp_offset = (off_t)offset, .fp_length = (off_t)length };
	fcntl(_fd, F_PUNCHHOLE, &hole);
#endif
	// If F_PUNCHHOLE isn't available we simply forget the blocks (already
	// done by the caller removing them from _cachedBlocks); disk space
	// isn't reclaimed but correctness is unaffected since a forgotten
	// block will be re-fetched before being read.
}

#pragma mark - Lifecycle

- (void)invalidate
{
	NSString *dirToRemove = nil;
	[_cond lock];
	if (!_invalidated)
	{
		_invalidated = YES;
		[_cond broadcast]; // wake anyone waiting on in-flight blocks
		while (_activeIO > 0) { [_cond wait]; } // let in-flight pread/pwrite finish
		if (_fd >= 0) { close(_fd); _fd = -1; }
		dirToRemove = _cacheDir;
	}
	[_cond unlock];
	if (dirToRemove)
	{
		[[NSFileManager defaultManager] removeItemAtPath: dirToRemove error: NULL];
	}
}

- (void)dealloc
{
	[self invalidate];
}

@end

static NSError *TSSTByteSourceOffsetPastEOFError(void)
{
	return [NSError errorWithDomain: TSSTArchiveByteSourceErrorDomain code: TSSTArchiveByteSourceErrorOffsetPastEOF userInfo: @{ NSLocalizedDescriptionKey: @"Read offset is past end of file." }];
}
