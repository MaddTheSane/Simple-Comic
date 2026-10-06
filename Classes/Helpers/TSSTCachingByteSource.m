/*
	Simple Comic
	TSSTCachingByteSource.m
*/

#import "TSSTCachingByteSource.h"
#import <sys/stat.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>

const NSUInteger TSSTCachingByteSourceBlockSize = 256 * 1024;

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

	NSCondition *_cond; // guards _cachedBlocks / _inFlightBlocks / _pendingDemandCount
	NSMutableIndexSet *_cachedBlocks;
	NSMutableIndexSet *_inFlightBlocks;
	NSUInteger _pendingDemandCount;
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

#pragma mark - Cached range queries

- (BOOL)isRangeCachedAtOffset:(uint64_t)offset length:(NSUInteger)length
{
	// Bytes past the end of the file don't exist to be cached: a span whose
	// size hint overshoots EOF (a zip's last entry, hinted with slack for
	// its local header) would otherwise never read as cached, leaving the
	// streamer retrying it forever and its page permanently "uncached".
	if (offset >= _length) { return YES; }
	length = (NSUInteger)MIN((uint64_t)length, _length - offset);
	if (length == 0) { return YES; }
	NSRange blockRange = [self blockRangeForOffset: offset length: length];
	BOOL result;
	[_cond lock];
	result = [_cachedBlocks containsIndexesInRange: blockRange];
	[_cond unlock];
	return result;
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
	if (_invalidated || _fd < 0)
	{
		if (error) { *error = TSSTCachingError(@"Cache invalidated."); }
		return NO;
	}
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
		if (_fd >= 0 && data.length > 0)
		{
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

	BOOL ok = [self ensureCachedAtOffset: offset length: wanted error: error];

	[_cond lock];
	_pendingDemandCount--;
	[_cond broadcast];
	[_cond unlock];

	if (!ok) { return nil; }
	return [self readFromCacheAtOffset: offset length: wanted];
}

- (BOOL)prefetchAtOffset:(uint64_t)offset length:(NSUInteger)length error:(NSError * _Nullable * _Nullable)error
{
	if (offset >= _length || length == 0) { return YES; }
	NSUInteger wanted = (NSUInteger)MIN((uint64_t)length, _length - offset);
	self.focusOffset = offset;
	return [self ensureCachedAtOffset: offset length: wanted error: error];
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
			// someone else and is now cached -- verify.
			if ([self isRangeCachedAtOffset: offset length: length]) { return YES; }
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
	if (_fd < 0) { return nil; }
	NSMutableData *buf = [NSMutableData dataWithLength: length];
	uint8_t *bytes = buf.mutableBytes;
	NSUInteger totalRead = 0;
	while (totalRead < length)
	{
		ssize_t got = pread(_fd, bytes + totalRead, length - totalRead, (off_t)(offset + totalRead));
		if (got < 0)
		{
			if (errno == EINTR) { continue; }
			return nil;
		}
		if (got == 0) { break; }
		totalRead += (NSUInteger)got;
	}
	if (totalRead != length) { buf.length = totalRead; }
	return buf;
}

#pragma mark - Budget / eviction

- (void)enforceBudget
{
	uint64_t budget = _maxCacheBytes;
	if (budget == 0 || budget >= _length) { return; }

	[_cond lock];
	NSUInteger maxBlocks = (NSUInteger)(budget / TSSTCachingByteSourceBlockSize) + 1;
	if (_cachedBlocks.count <= maxBlocks) { [_cond unlock]; return; }

	uint64_t focus = _focusOffset;
	NSUInteger focusBlock = (NSUInteger)(focus / TSSTCachingByteSourceBlockSize);

	NSMutableArray<NSNumber *> *blocks = [NSMutableArray array];
	[_cachedBlocks enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL * _Nonnull stop) {
		[blocks addObject: @(idx)];
	}];
	[blocks sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
		NSInteger da = labs((long)a.unsignedIntegerValue - (long)focusBlock);
		NSInteger db = labs((long)b.unsignedIntegerValue - (long)focusBlock);
		return da < db ? NSOrderedDescending : (da > db ? NSOrderedAscending : NSOrderedSame);
	}];

	NSUInteger toEvict = _cachedBlocks.count - maxBlocks;
	NSMutableIndexSet *evicted = [NSMutableIndexSet indexSet];
	for (NSUInteger i = 0; i < toEvict && i < blocks.count; ++i)
	{
		NSUInteger block = blocks[i].unsignedIntegerValue;
		[evicted addIndex: block];
	}
	[_cachedBlocks removeIndexes: evicted];
	[_cond unlock];

	[evicted enumerateRangesUsingBlock:^(NSRange range, BOOL * _Nonnull stop) {
		uint64_t start = [self offsetForBlock: range.location];
		NSUInteger lastBlock = range.location + range.length - 1;
		uint64_t end = [self offsetForBlock: lastBlock] + [self lengthForBlock: lastBlock];
		[self punchHoleAtOffset: start length: (NSUInteger)(end - start)];
	}];
}

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
