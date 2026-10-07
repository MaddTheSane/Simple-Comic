#import "TSSTByteSourceHandle.h"
#import <XADMaster/XADException.h>

NSString *const TSSTByteSourceHandleErrorException = @"TSSTByteSourceHandleErrorException";

#if !__has_feature(objc_arc)
#error this file needs to be compiled with Automatic Reference Counting (ARC)
#endif

// A fresh (or just-seeked-away) handle starts with a small read-ahead and
// grows it 16x on each contiguous refill, up to kReadAheadSize. Header walks
// (RAR4) seek to a header, read a few dozen bytes and seek past the file data,
// so a big refill per header is wasted transfer; a sequential reader (file
// extraction) ramps 4 KB -> 64 KB -> 1 MB in three requests and then
// stays there, so on a high-latency link each request moves ~1 MB instead
// of paying a round trip per 64 KB.
static const NSUInteger kReadAheadSize = 1024 * 1024;
static const NSUInteger kInitialReadAheadSize = 4 * 1024;
static const NSUInteger kReadAheadGrowth = 16;

@implementation TSSTByteSourceHandle
{
	id<TSSTArchiveByteSource> _source;
	uint64_t _fileSize;
	NSData *_buffer;		// bytes covering [_bufferStart, _bufferStart + _buffer.length)
	uint64_t _bufferStart;
	NSUInteger _bufferPos;	// next unread index within _buffer
	NSUInteger _nextReadAhead;	// size of the next refill, see kInitialReadAheadSize
}

- (instancetype)initWithByteSource:(id<TSSTArchiveByteSource>)source
{
	if (self = [super init]) {
		_source = source;
		_fileSize = source.length;
		_buffer = nil;
		_bufferStart = 0;
		_bufferPos = 0;
		_nextReadAhead = kInitialReadAheadSize;
	}
	return self;
}

- (instancetype)initAsCopyOf:(TSSTByteSourceHandle *)other
{
	if (self = [super initAsCopyOf:other]) {
		_source = other->_source;
		_fileSize = other->_fileSize;
		// Independent position; buffer state is not shared with the original.
		_buffer = other->_buffer;
		_bufferStart = other->_bufferStart;
		_bufferPos = other->_bufferPos;
		_nextReadAhead = other->_nextReadAhead;
	}
	return self;
}

- (id<TSSTArchiveByteSource>)byteSource
{
	return _source;
}

- (off_t)fileSize
{
	return (off_t)_fileSize;
}

- (off_t)offsetInFile
{
	return (off_t)(_bufferStart + _bufferPos);
}

- (BOOL)atEndOfFile
{
	return self.offsetInFile == self.fileSize;
}

- (void)seekToFileOffset:(off_t)offs
{
	if (offs < 0) [self _raiseEOF];

	uint64_t newOffset = (uint64_t)offs;
	if (_buffer && newOffset >= _bufferStart && newOffset <= _bufferStart + _buffer.length) {
		// Stays inside (or right at the end of) the buffered region: keep it.
		_bufferPos = (NSUInteger)(newOffset - _bufferStart);
		return;
	}

	_buffer = nil;
	_bufferStart = newOffset;
	_bufferPos = 0;
	_nextReadAhead = kInitialReadAheadSize;
}

- (void)seekToEndOfFile
{
	_buffer = nil;
	_bufferStart = _fileSize;
	_bufferPos = 0;
}

- (void)pushBackByte:(int)byte
{
	[self seekToFileOffset:self.offsetInFile - 1];
}

- (NSUInteger)_bufferedBytesAvailable
{
	return _buffer ? _buffer.length - _bufferPos : 0;
}

- (BOOL)_refillBufferWanting:(NSUInteger)wanted
{
	uint64_t offset = self.offsetInFile;
	if (offset >= _fileSize) return NO;

	NSUInteger readAhead = MIN(MAX(_nextReadAhead, wanted), kReadAheadSize);
	NSUInteger length = (NSUInteger)MIN((uint64_t)readAhead, _fileSize - offset);
	NSError *error = nil;
	NSData *data = [_source readAtOffset:offset length:length error:&error];
	if (!data) {
		[self _raiseErrorWithUnderlyingError:error];
		return NO;
	}

	_buffer = data;
	_bufferStart = offset;
	_bufferPos = 0;
	_nextReadAhead = MIN(readAhead * kReadAheadGrowth, kReadAheadSize);
	return data.length > 0;
}

- (int)readAtMost:(int)num toBuffer:(void *)buffer
{
	if (num <= 0) return 0;

	NSUInteger remaining = (NSUInteger)num;
	NSUInteger totalRead = 0;
	uint8_t *dest = (uint8_t *)buffer;

	while (remaining > 0) {
		NSUInteger available = [self _bufferedBytesAvailable];
		if (available == 0) {
			// Large reads bypass the read-ahead buffer entirely.
			if (remaining >= kReadAheadSize) {
				uint64_t offset = self.offsetInFile;
				if (offset >= _fileSize) break;
				NSUInteger want = (NSUInteger)MIN((uint64_t)remaining, _fileSize - offset);
				NSError *error = nil;
				NSData *data = [_source readAtOffset:offset length:want error:&error];
				if (!data) {
					[self _raiseErrorWithUnderlyingError:error];
					break;
				}
				if (data.length == 0) break;
				[data getBytes:dest length:data.length];
				dest += data.length;
				totalRead += data.length;
				remaining -= data.length;
				_bufferStart = offset + data.length;
				_bufferPos = 0;
				_buffer = nil;
				continue;
			}

			if (![self _refillBufferWanting: remaining]) break;
			available = [self _bufferedBytesAvailable];
			if (available == 0) break;
		}

		NSUInteger chunk = MIN(available, remaining);
		[_buffer getBytes:dest range:NSMakeRange(_bufferPos, chunk)];
		dest += chunk;
		_bufferPos += chunk;
		totalRead += chunk;
		remaining -= chunk;
	}

	return (int)totalRead;
}

- (void)writeBytes:(int)num fromBuffer:(const void *)buffer
{
	[self _raiseNotSupported:_cmd];
}

- (void)_raiseErrorWithUnderlyingError:(NSError *)error
{
	[[NSException exceptionWithName:TSSTByteSourceHandleErrorException
							  reason:[NSString stringWithFormat:@"Error reading archive byte source: %@", error.localizedDescription ?: @"unknown error"]
							userInfo:error ? @{NSUnderlyingErrorKey: error} : nil] raise];
}

@end
