/*
	Simple Comic
	TSSTArchiveByteSource.h

  A byte-source abstraction that archive readers (TSSTZipIndex today,
  RAR/7z backends later) read through instead of touching a file
  descriptor directly. This lets us:

  (a) count and simulate network reads in tests, and
  (b) simulate a slow link (e.g. SMB over Wi-Fi) inside the app on local
      files, to judge UX before we have real streaming/caching in place.
*/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A thread-safe, random-access source of bytes. A short read at EOF
/// returns the bytes actually available (which may be fewer than
/// requested, including zero at exactly EOF); an offset past EOF is an
/// error.
@protocol TSSTArchiveByteSource <NSObject>

@property (readonly) uint64_t length;

- (nullable NSData *)readAtOffset:(uint64_t)offset length:(NSUInteger)length error:(NSError * _Nullable * _Nullable)error;

@end

extern NSString * const TSSTArchiveByteSourceErrorDomain;

typedef NS_ENUM(NSInteger, TSSTArchiveByteSourceError)
{
	TSSTArchiveByteSourceErrorOffsetPastEOF = 1,
	TSSTArchiveByteSourceErrorIO,
};

/// Reads a local file with pread(2). Owns its own fd, closed on dealloc.
@interface TSSTFileByteSource : NSObject <TSSTArchiveByteSource>

+ (nullable instancetype)sourceWithFileURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;

@end

#if DEBUG
// Debug-only (SC_SIMULATE_LINK and the unit tests); never shipped.
/// Wraps another byte source and models a single shared link with fixed
/// per-request latency and bandwidth. Concurrent reads serialize on a
/// lock, so bandwidth isn't multiplied across threads.
@interface TSSTSimulatedLinkByteSource : NSObject <TSSTArchiveByteSource>

- (instancetype)initWithByteSource:(id<TSSTArchiveByteSource>)source
							latency:(NSTimeInterval)latency
					 bytesPerSecond:(double)bytesPerSecond;

@property (nonatomic, readonly) NSTimeInterval latency;
@property (nonatomic, readonly) double bytesPerSecond; // 0 == unlimited

/// YES (the default) sleeps in real time for each read's latency +
/// transfer time. NO ("timeless mode") skips sleeping and instead
/// accumulates the modeled time into -simulatedElapsed, for fast,
/// deterministic tests.
@property (nonatomic) BOOL simulateTime;

@property (atomic, readonly) NSUInteger readCount;
@property (atomic, readonly) uint64_t bytesRead;
@property (atomic, readonly) NSTimeInterval simulatedElapsed;

/// When YES, every read's (offset, length) is appended to -requestLog.
@property (nonatomic) BOOL logsRequests;
@property (nonatomic, readonly) NSArray<NSValue *> *requestLog; // NSRange-ish {offset, length} boxed as NSValue with NSRange

- (void)resetCounters;

+ (instancetype)lanLinkWrapping:(id<TSSTArchiveByteSource>)source;
+ (instancetype)smbWiredLinkWrapping:(id<TSSTArchiveByteSource>)source;
+ (instancetype)smbWifiLinkWrapping:(id<TSSTArchiveByteSource>)source;

/// name is "lan", "smb" or "wifi" (case-insensitive). Returns nil for any
/// other name.
+ (nullable instancetype)linkWithProfileName:(NSString *)name wrapping:(id<TSSTArchiveByteSource>)source;

@end
#endif

NS_ASSUME_NONNULL_END
