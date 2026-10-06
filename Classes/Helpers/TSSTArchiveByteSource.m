/*
	Simple Comic
	TSSTArchiveByteSource.m
*/

#import "TSSTArchiveByteSource.h"
#import <sys/stat.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <time.h>

NSString * const TSSTArchiveByteSourceErrorDomain = @"TSSTArchiveByteSourceErrorDomain";

static NSError *TSSTByteSourceError(TSSTArchiveByteSourceError code, NSString *description)
{
	return [NSError errorWithDomain: TSSTArchiveByteSourceErrorDomain code: code userInfo: @{ NSLocalizedDescriptionKey: description }];
}

#pragma mark - TSSTFileByteSource

@interface TSSTFileByteSource ()
{
	int _fd;
	uint64_t _length;
}
@end

@implementation TSSTFileByteSource

+ (nullable instancetype)sourceWithFileURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error
{
	NSString *path = url.path;
	if (!path)
	{
		if (error) { *error = TSSTByteSourceError(TSSTArchiveByteSourceErrorIO, @"No file path."); }
		return nil;
	}

	int fd = open(path.fileSystemRepresentation, O_RDONLY);
	if (fd < 0)
	{
		if (error) { *error = TSSTByteSourceError(TSSTArchiveByteSourceErrorIO, @"Could not open file."); }
		return nil;
	}

	struct stat st;
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode))
	{
		close(fd);
		if (error) { *error = TSSTByteSourceError(TSSTArchiveByteSourceErrorIO, @"Not a regular file."); }
		return nil;
	}

	TSSTFileByteSource *source = [[self alloc] init];
	source->_fd = fd;
	source->_length = (uint64_t)st.st_size;
	return source;
}

- (uint64_t)length
{
	return _length;
}

- (nullable NSData *)readAtOffset:(uint64_t)offset length:(NSUInteger)length error:(NSError * _Nullable * _Nullable)error
{
	if (offset > _length)
	{
		if (error) { *error = TSSTByteSourceError(TSSTArchiveByteSourceErrorOffsetPastEOF, @"Read offset is past end of file."); }
		return nil;
	}

	uint64_t available = _length - offset;
	NSUInteger wanted = (NSUInteger)MIN((uint64_t)length, available);
	if (wanted == 0)
	{
		return [NSData data];
	}

	NSMutableData *buf = [NSMutableData dataWithLength: wanted];
	uint8_t *bytes = buf.mutableBytes;
	NSUInteger totalRead = 0;

	while (totalRead < wanted)
	{
		ssize_t got = pread(_fd, bytes + totalRead, wanted - totalRead, (off_t)(offset + totalRead));
		if (got < 0)
		{
			if (errno == EINTR)
			{
				continue;
			}
			if (error) { *error = TSSTByteSourceError(TSSTArchiveByteSourceErrorIO, @"pread failed."); }
			return nil;
		}
		if (got == 0)
		{
			break; // short read at EOF -- return what we have.
		}
		totalRead += (NSUInteger)got;
	}

	if (totalRead != wanted)
	{
		buf.length = totalRead;
	}
	return buf;
}

- (void)dealloc
{
	if (_fd >= 0)
	{
		close(_fd);
		_fd = -1;
	}
}

@end

#if DEBUG
#pragma mark - TSSTSimulatedLinkByteSource

@interface TSSTSimulatedLinkByteSource ()
{
	id<TSSTArchiveByteSource> _source;
	NSLock *_linkLock; // serializes reads -- models a single shared link.
	NSMutableArray<NSValue *> *_requestLog;
}
@end

@implementation TSSTSimulatedLinkByteSource

- (instancetype)initWithByteSource:(id<TSSTArchiveByteSource>)source
							latency:(NSTimeInterval)latency
					 bytesPerSecond:(double)bytesPerSecond
{
	self = [super init];
	if (self)
	{
		_source = source;
		_latency = latency;
		_bytesPerSecond = bytesPerSecond;
		_simulateTime = YES;
		_linkLock = [NSLock new];
		_requestLog = [NSMutableArray array];
	}
	return self;
}

- (uint64_t)length
{
	return _source.length;
}

- (NSTimeInterval)transferTimeForLength:(NSUInteger)length
{
	NSTimeInterval time = _latency;
	if (_bytesPerSecond > 0)
	{
		time += (NSTimeInterval)length / _bytesPerSecond;
	}
	return time;
}

- (nullable NSData *)readAtOffset:(uint64_t)offset length:(NSUInteger)length error:(NSError * _Nullable * _Nullable)error
{
	[_linkLock lock];

	_readCount += 1;
	_bytesRead += length;
	NSTimeInterval time = [self transferTimeForLength: length];
	_simulatedElapsed += time;

	if (_logsRequests)
	{
		NSRange range = NSMakeRange((NSUInteger)offset, length);
		[_requestLog addObject: [NSValue valueWithRange: range]];
	}

	BOOL shouldSleep = _simulateTime;

	[_linkLock unlock];

	if (shouldSleep && time > 0)
	{
		useconds_t microseconds = (useconds_t)MIN(time * 1000000.0, (NSTimeInterval)UINT32_MAX);
		usleep(microseconds);
	}

	return [_source readAtOffset: offset length: length error: error];
}

- (void)resetCounters
{
	[_linkLock lock];
	_readCount = 0;
	_bytesRead = 0;
	_simulatedElapsed = 0;
	[_requestLog removeAllObjects];
	[_linkLock unlock];
}

- (NSArray<NSValue *> *)requestLog
{
	NSArray<NSValue *> *snapshot;
	[_linkLock lock];
	snapshot = [_requestLog copy];
	[_linkLock unlock];
	return snapshot;
}

+ (instancetype)lanLinkWrapping:(id<TSSTArchiveByteSource>)source
{
	return [[self alloc] initWithByteSource: source latency: 0.001 bytesPerSecond: 100.0 * 1024 * 1024];
}

+ (instancetype)smbWiredLinkWrapping:(id<TSSTArchiveByteSource>)source
{
	return [[self alloc] initWithByteSource: source latency: 0.020 bytesPerSecond: 40.0 * 1024 * 1024];
}

+ (instancetype)smbWifiLinkWrapping:(id<TSSTArchiveByteSource>)source
{
	return [[self alloc] initWithByteSource: source latency: 0.040 bytesPerSecond: 5.0 * 1024 * 1024];
}

+ (nullable instancetype)linkWithProfileName:(NSString *)name wrapping:(id<TSSTArchiveByteSource>)source
{
	NSString *lower = name.lowercaseString;
	if ([lower isEqualToString: @"lan"]) { return [self lanLinkWrapping: source]; }
	if ([lower isEqualToString: @"smb"]) { return [self smbWiredLinkWrapping: source]; }
	if ([lower isEqualToString: @"wifi"]) { return [self smbWifiLinkWrapping: source]; }
	return nil;
}

@end
#endif
