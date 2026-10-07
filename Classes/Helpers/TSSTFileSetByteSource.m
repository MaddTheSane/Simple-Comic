/*
	Simple Comic
	TSSTFileSetByteSource.m
*/

#import "TSSTFileSetByteSource.h"
#import "TSSTCachingByteSource.h"
#import "TSSTArchiveStreamer.h"

@implementation TSSTFileSetByteSource
{
	NSArray<NSURL *> *_urls;
	NSUInteger _count;
	uint64_t *_offsets; // virtual start of each file
	uint64_t *_sizes;
	uint64_t _length;
}

- (instancetype)initWithFileURLs:(NSArray<NSURL *> *)urls sizes:(NSArray<NSNumber *> *)sizes
{
	if ((self = [super init]))
	{
		_urls = [urls copy];
		_count = urls.count;
		_offsets = calloc(MAX(_count, 1), sizeof(uint64_t));
		_sizes = calloc(MAX(_count, 1), sizeof(uint64_t));
		const uint64_t block = TSSTCachingByteSourceBlockSize;
		uint64_t cursor = 0;
		for (NSUInteger i = 0; i < _count; ++i)
		{
			_offsets[i] = cursor;
			_sizes[i] = i < sizes.count ? sizes[i].unsignedLongLongValue : 0;
			// At least one block per file, so every file (even an empty
			// one) owns a distinct, block-aligned range.
			uint64_t blocks = MAX((uint64_t)1, (_sizes[i] + block - 1) / block);
			cursor += blocks * block;
		}
		_length = cursor;
	}
	return self;
}

- (void)dealloc
{
	free(_offsets);
	free(_sizes);
}

- (uint64_t)length { return _length; }
- (NSUInteger)fileCount { return _count; }
- (NSURL *)fileURLAtIndex:(NSUInteger)index { return _urls[index]; }

- (NSRange)rangeOfFileAtIndex:(NSUInteger)index
{
	return NSMakeRange((NSUInteger)_offsets[index], (NSUInteger)_sizes[index]);
}

- (NSArray<NSValue *> *)spansForFileIndices:(NSArray<NSNumber *> *)readingOrder spanIndexMap:(NSDictionary<NSNumber *, NSNumber *> * _Nullable * _Nullable)outMap
{
	return [TSSTArchiveStreamer spansForEntryIndices: readingOrder rangeProvider: ^BOOL(NSUInteger entryIndex, NSRange *outRange) {
		if (entryIndex >= self->_count) { return NO; }
		*outRange = [self rangeOfFileAtIndex: entryIndex];
		return YES;
	} spanIndexMap: outMap];
}

/// Index of the file whose block-aligned slot contains \c offset.
- (NSUInteger)fileIndexForOffset:(uint64_t)offset
{
	NSUInteger lo = 0, hi = _count; // last i with _offsets[i] <= offset
	while (hi - lo > 1)
	{
		NSUInteger mid = lo + (hi - lo) / 2;
		if (_offsets[mid] <= offset) { lo = mid; } else { hi = mid; }
	}
	return lo;
}

- (nullable NSData *)readAtOffset:(uint64_t)offset length:(NSUInteger)length error:(NSError * _Nullable * _Nullable)error
{
	if (offset > _length)
	{
		if (error) { *error = [NSError errorWithDomain: TSSTArchiveByteSourceErrorDomain code: TSSTArchiveByteSourceErrorOffsetPastEOF userInfo: nil]; }
		return nil;
	}
	NSUInteger wanted = (NSUInteger)MIN((uint64_t)length, _length - offset);
	NSMutableData *result = [NSMutableData dataWithLength: wanted]; // padding reads back as zeros
	uint8_t *bytes = result.mutableBytes;
	uint64_t end = offset + wanted;

	NSUInteger i = _count ? [self fileIndexForOffset: offset] : 0;
	for (; i < _count && _offsets[i] < end; ++i)
	{
		uint64_t fileStart = _offsets[i];
		uint64_t fileEnd = fileStart + _sizes[i];
		uint64_t from = MAX(offset, fileStart);
		uint64_t to = MIN(end, fileEnd);
		if (to <= from) { continue; }

		NSError *fileError = nil;
		id<TSSTArchiveByteSource> file = [TSSTFileByteSource sourceWithFileURL: _urls[i] error: &fileError];
		NSData *piece = file ? [file readAtOffset: from - fileStart length: (NSUInteger)(to - from) error: &fileError] : nil;
		if (piece.length != to - from) { piece = nil; fileError = nil; } // a file that shrank since the listing is an error, not zeros
		if (!piece)
		{
			if (error) { *error = fileError ?: [NSError errorWithDomain: TSSTArchiveByteSourceErrorDomain code: TSSTArchiveByteSourceErrorIO userInfo: nil]; }
			return nil;
		}
		memcpy(bytes + (from - offset), piece.bytes, piece.length);
	}
	return result;
}

@end
