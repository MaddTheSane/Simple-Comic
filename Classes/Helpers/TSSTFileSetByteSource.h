/*
	Simple Comic
	TSSTFileSetByteSource.h

  The folder-of-loose-images backend for the streaming plumbing. A set of
  files is presented as one virtual byte space -- file i occupies its own
  block-aligned range -- so the same TSSTCachingByteSource /
  TSSTArchiveStreamer / simulated-link stack that streams an archive can
  stream a folder: each image is simply one span. Files are opened only for
  the duration of a read (one request per file, like a network volume
  sees), and the padding between files is never read, so a cache block
  never straddles two files.
*/

#import <Foundation/Foundation.h>
#import "TSSTArchiveByteSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface TSSTFileSetByteSource : NSObject <TSSTArchiveByteSource>

/// urls and sizes are parallel; sizes come from the directory listing so
/// no per-file stat is needed to lay the space out.
- (instancetype)initWithFileURLs:(NSArray<NSURL *> *)urls sizes:(NSArray<NSNumber *> *)sizes;

@property (nonatomic, readonly) NSUInteger fileCount;
- (NSURL *)fileURLAtIndex:(NSUInteger)index;

/// The virtual byte range holding file \c index's bytes (length == its
/// size, which may be 0).
- (NSRange)rangeOfFileAtIndex:(NSUInteger)index;

/// One span per file, in the given reading order, plus file index -> span
/// index. Built with the generic span builder every backend shares.
- (NSArray<NSValue *> *)spansForFileIndices:(NSArray<NSNumber *> *)readingOrder spanIndexMap:(NSDictionary<NSNumber *, NSNumber *> * _Nullable * _Nullable)outMap;

@end

NS_ASSUME_NONNULL_END
