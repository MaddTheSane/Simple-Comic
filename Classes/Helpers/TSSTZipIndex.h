/*
	Simple Comic
	TSSTZipIndex.h

  A small, self-contained, thread-safe zip reader that lists a zip's
  central directory with a couple of pread(2) calls instead of walking
  every local header the way XADZipParser does. This is much faster
  over slow/high-latency volumes (e.g. SMB) for large archives.

  Only handles the common cases: single-disk zips, deflate/store,
  optional Zip64 fields. Anything else (multi-disk archives, unusual
  compression methods for entries we need to read) causes either
  +indexWithFileURL:error: to return nil (caller should fall back to
  XADArchive) or -canExtractEntry: to return NO for that entry.
*/

#import <Foundation/Foundation.h>
#import "TSSTArchiveByteSource.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const TSSTZipIndexErrorDomain;

typedef NS_ENUM(NSInteger, TSSTZipIndexError)
{
	TSSTZipIndexErrorNotAZip = 1,
	TSSTZipIndexErrorMultiDisk,
	TSSTZipIndexErrorCorrupt,
	TSSTZipIndexErrorUnsupportedCompression,
	TSSTZipIndexErrorEncrypted,
	TSSTZipIndexErrorCRCMismatch,
	TSSTZipIndexErrorIO,
	TSSTZipIndexErrorZlib,
};

/**
 A minimal read-only view of a zip file's central directory, built with
 one pread() of the end-of-central-directory tail and one pread() of the
 whole central directory. Entry indices match central-directory order,
 which is the same order XADArchive enumerates zip entries in, so
 existing TSSTPage.index values stay valid whichever backend produced
 them.
 */
@interface TSSTZipIndex : NSObject

/// Returns nil (with *error left informative but not necessarily set)
/// when the file isn't a zip this class can fully parse -- callers
/// should fall back to XADArchive in that case.
+ (nullable instancetype)indexWithFileURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;

/// Same construction, but reading through an arbitrary byte source
/// instead of opening a file directly. Lets callers substitute a
/// counting/simulated-link source (for tests, or to model a slow link
/// against a local file for UX evaluation).
+ (nullable instancetype)indexWithByteSource:(id<TSSTArchiveByteSource>)source error:(NSError * _Nullable * _Nullable)error;

@property (nonatomic, readonly) NSUInteger numberOfEntries;

- (NSString *)nameOfEntry:(NSUInteger)index;
- (BOOL)entryIsDirectory:(NSUInteger)index;

/// NO for encrypted entries or entries compressed with a method other
/// than store (0) or deflate (8).
- (BOOL)canExtractEntry:(NSUInteger)index;

/// Reads and (if needed) inflates one entry's data, verifying its CRC32.
/// Thread-safe: reads go through the underlying byte source.
- (nullable NSData *)contentsOfEntry:(NSUInteger)index error:(NSError * _Nullable * _Nullable)error;

/// The local file header offset for this entry within the archive. A
/// future streaming cache can use this (plus the sizes below) to
/// coalesce adjacent entries into one large read.
- (uint64_t)dataOffsetHintForEntry:(NSUInteger)index;
- (uint64_t)compressedSizeOfEntry:(NSUInteger)index;

@end

NS_ASSUME_NONNULL_END
