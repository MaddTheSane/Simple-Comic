/*
	Simple Comic
	TSSTXADArchiveSource.h

  A streaming archive backend on XADArchiveParser, the RAR/7z counterpart
  to TSSTZipIndex. Unlike XADArchive (path-based, fully synchronous), this
  parses on a caller-supplied thread and delivers entries in small batches
  as they're found, so a window can show early pages while a slow header
  walk (e.g. RAR4 over SMB) is still running. Entry bytes can also be
  requested while the parse is still in flight; the parse thread services
  those requests itself between entries, since XADArchiveParser's handle
  isn't safe to touch from a second thread concurrently.
*/

#import <Foundation/Foundation.h>

#import "TSSTArchiveByteSource.h"

NS_ASSUME_NONNULL_BEGIN

/// One archive entry, as delivered by a batch. A plain value record -- no
/// XADMaster types leak past this class.
@interface TSSTXADArchiveEntry : NSObject

@property (nonatomic, readonly) NSUInteger index;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) BOOL isDirectory;
@property (nonatomic, readonly) unsigned long long size;

/// YES when -spanRange is meaningful: the byte range in the archive file
/// covering this entry's input (min offset to max end of its input
/// parts). NO for entries whose file span can't be determined this way
/// (e.g. a 7z solid folder without a computable range) -- callers should
/// fall back to a single whole-file span in reading order.
@property (nonatomic, readonly) BOOL hasSpanRange;
@property (nonatomic, readonly) NSRange spanRange;

@property (nonatomic, readonly) BOOL solid;
@property (nonatomic, readonly) BOOL encrypted;

@end

extern NSString * const TSSTXADArchiveSourceErrorDomain;

typedef NS_ENUM(NSInteger, TSSTXADArchiveSourceError)
{
	TSSTXADArchiveSourceErrorCannotOpen = 1,
	TSSTXADArchiveSourceErrorPasswordRequired,
	TSSTXADArchiveSourceErrorEntryNotFound,
	TSSTXADArchiveSourceErrorExtraction,
	/// A volume of a multi-volume set could not be opened (see +[TSSTManagedArchive openVolumeSourcesForURLs:error:]).
	TSSTXADArchiveSourceErrorMissingVolume,
};

/// Called on the parsing thread as entries are discovered: roughly every
/// 16 entries or 100ms, whichever comes first, and once more (possibly
/// with an empty array) when parsing finishes. isFinal is YES only on
/// that last call; error is set there if the parse failed.
typedef void (^TSSTXADArchiveSourceBatchHandler)(NSArray<TSSTXADArchiveEntry *> *batch, BOOL isFinal, NSError * _Nullable error);

/// Returns the already-known password for an archive at the given path,
/// prompting the user (on the main thread, synchronously) if necessary.
/// Mirrors TSSTScanArchiveDelegate's behavior so both backends prompt the
/// same way. Return nil to indicate no password is available.
typedef NSString * _Nullable (^TSSTXADArchiveSourcePasswordProvider)(NSString *archivePath, NSString * _Nullable knownPassword);

/// The volumes of a multi-volume RAR set laid end to end as one byte space
/// (volume i starts at the sum of the earlier lengths), which is also how
/// XADMultiHandle numbers offsets, so every entry span the parser reports
/// is a real range of this source and the shared cache / streamer / link
/// simulation treat the whole set like a single file.
@interface TSSTVolumeSetByteSource : NSObject <TSSTArchiveByteSource>
- (instancetype)initWithVolumeSources:(NSArray<id<TSSTArchiveByteSource>> *)volumes;
@property (nonatomic, readonly) NSArray<NSNumber *> *volumeLengths;
@end

@interface TSSTXADArchiveSource : NSObject

/// The volume files of the multi-volume RAR set that \c fileURL belongs to
/// (in reading order), or nil when it is a single archive or the set can't
/// be found. Uses XADMaster's own volume detection and naming rules.
+ (nullable NSArray<NSURL *> *)volumeURLsForFileURL:(NSURL *)fileURL;

/// As below, for a multi-volume set: \c source is the concatenated byte
/// space (see TSSTVolumeSetByteSource) and \c volumeLengths splits it back
/// into volumes for the parser.
- (nullable instancetype)initWithByteSource:(id<TSSTArchiveByteSource>)source
								volumeLengths:(nullable NSArray<NSNumber *> *)volumeLengths
										name:(NSString *)name
										path:(NSString *)path
									password:(nullable NSString *)password
								   passwordProvider:(nullable TSSTXADArchiveSourcePasswordProvider)passwordProvider
									   error:(NSError **)error;

/// Builds a parser over the given byte source. name is used for format
/// sniffing by extension/heuristics the same way XADArchive uses it.
/// Returns nil (with an error) when the byte source isn't a recognized
/// archive format at all.
- (nullable instancetype)initWithByteSource:(id<TSSTArchiveByteSource>)source
										name:(NSString *)name
										path:(NSString *)path
									password:(nullable NSString *)password
								   passwordProvider:(nullable TSSTXADArchiveSourcePasswordProvider)passwordProvider
									   error:(NSError **)error;

/// Runs the parse on the calling thread (synchronous, potentially slow --
/// call this off-main). Delivers entries via handler as described above.
/// Returns YES on success (even if some individual entries were skipped);
/// NO if the whole parse failed, in which case the final batch call's
/// error is also set.
- (BOOL)parseWithEntryBatchHandler:(TSSTXADArchiveSourceBatchHandler)handler;

/// The password ultimately used (nil if none was needed/available), valid
/// after -parseWithEntryBatchHandler: has started.
@property (atomic, copy, nullable, readonly) NSString *password;

/// Number of entries found so far (thread-safe; grows during the parse).
@property (atomic, readonly) NSUInteger entryCount;

/// YES once the parse has finished (successfully or not).
@property (atomic, readonly) BOOL parseFinished;

/// Thread-safe: usable both while the parse is still running (the request
/// is serviced by the parsing thread) and after it completes (serialized
/// with a lock, since the underlying parser isn't reentrant). Blocks the
/// calling thread until the entry is found (or the parse ends without it,
/// which is an error).
- (nullable NSData *)dataForEntry:(NSUInteger)index error:(NSError **)error;

/// Like -dataForEntry:error:, but only waits for the entry to be found --
/// no extraction. Returns nil if the parse ends without ever finding it.
- (nullable NSString *)nameForEntryAtIndex:(NSUInteger)index;

@end

NS_ASSUME_NONNULL_END
