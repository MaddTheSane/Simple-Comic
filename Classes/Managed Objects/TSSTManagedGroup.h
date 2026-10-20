/*
Copyright (c) 2006-2009 Dancing Tortoise Software

	Permission is hereby granted, free of charge, to any person
	obtaining a copy of this software and associated documentation
	files (the "Software"), to deal in the Software without
	restriction, including without limitation the rights to use,
	copy, modify, merge, publish, distribute, sublicense, and/or
	sell copies of the Software, and to permit persons to whom the
	Software is furnished to do so, subject to the following
	conditions:

	The above copyright notice and this permission notice shall be
	included in all copies or substantial portions of the Software.

  TSSTManagedGroup.h
*/

#import <Cocoa/Cocoa.h>

@class TSSTPage;
@class TSSTArchiveStreamer;
@class TSSTCachingByteSource;
@class TSSTXADArchiveEntry;

NS_ASSUME_NONNULL_BEGIN

/// Value-only result of scanning an archive off the main thread (see
/// `+[TSSTManagedArchive scanRecordForFileURL:name:password:]`); the rest of its
/// state is private to TSSTManagedGroup.m.
@interface TSSTArchiveScanRecord : NSObject
@property (nonatomic, readonly, strong, nullable) NSArray<TSSTArchiveScanRecord *> *children;
/// Set only on the final progressive batch: every entry found, in the
/// order XAD reported them, used to build the streamer's reading-order
/// spans once the whole parse is done.
@property (nonatomic, readonly, copy, nullable) NSArray<TSSTXADArchiveEntry *> *xadAllEntriesForStreamer;
/// Set only on the final batch: every non-fatal error collected across the
/// whole scan (nested-archive/PDF extraction failures), to be reported
/// individually by the caller.
@property (nonatomic, readonly, copy, nullable) NSArray<NSError *> *scanErrors;
@end

/// Asks the user for access to a folder the sandbox hides (see
/// +[TSSTManagedArchive openVolumeSourcesForURLs:error:]). Called on the main
/// thread. Return the granted (security-scoped) folder URL, or nil if declined.
@protocol TSSTFolderAccessProvider <NSObject>
- (nullable NSURL *)folderAccessGrantForFolderURL:(NSURL *)folderURL message:(NSString *)message;
@end

@interface TSSTManagedGroup : NSManagedObject
{
    id instance;
    NSLock * groupLock;
	NSURL *_url;
}

@property (readonly, strong, nullable) id instance;

@property (copy) NSString *path;
@property (copy, nullable) NSURL *fileURL;

/**
 Runs \c during inside a URL-error batch and presents any errors it appends to
 \c errors, plus bookmark errors raised meanwhile, as one summary alert for
 \c groupName. Joins an enclosing batch on this thread if there is one. The
 batch is always closed, even if \c during throws. Call on the main thread.
 */
+ (void)batchURLErrorsForGroupName:(NSString *)groupName during:(void (^)(NSMutableArray<NSError *> *errors))during;

- (void)requestDataForPageIndex:(NSInteger)index completionHandler:(void(^)(NSData *_Nullable pageData, NSError *_Nullable error))callback;
@property (readonly, strong, nullable) NSManagedObject *topLevelGroup;

/// Returns a set with all the images found in the key in union with the ones from other groups.
///
/// @return NSSet with all images found in context.
@property (readonly, copy) NSSet<TSSTPage*> *nestedImages;

/// Goes through various files, like pdfs, images, text files
/// from the path folder and its subfolders and add these
/// to the Core Data for the `managedObjectContext`
/// with the info needed to deal with the files.
- (void)nestedFolderContents;

/// Attempts to resolve the filleURL, but doesn't alter self on failure.
///
/// Note: If it fails, always call fileURL to truly update the state.
- (nullable NSURL *)probeFileURL;

/**
 Main-thread only: inserts the Core Data entities for newChildren (a
 subset of some record's children) and returns the new TSSTPage/-derived
 image pages to union into session.images. Safe to call multiple times
 as more children arrive from -scanArchiveProgressivelyForFileURL:name:password:perBatch:.
 */
- (NSSet<TSSTPage *> *)insertChildRecords:(NSArray<id> *)newChildren;

/**
 Background-safe scan of a folder of loose files: one directory enumeration
 (with the properties needed, so no per-file stat) per folder level, recursing
 into subfolders and building nested archive/PDF records. Returns a scan
 record without touching any \c NSManagedObject. When \c streaming is YES
 (non-local volume, or DEBUG SC_SIMULATE_LINK) every image/text page also gets
 an entry index and the record carries the caching byte source that streams
 the whole tree.
 */
+ (nullable TSSTArchiveScanRecord *)scanRecordForFolderURL:(NSURL *)folderURL name:(nullable NSString *)name streaming:(BOOL)streaming;

/// Main-thread only: applies a folder record's backend (file set, cache and
/// streamer) to this folder, then inserts its children.
- (void)applyFolderScanRecord:(TSSTArchiveScanRecord *)record;

/// YES when the file is worth caching/streaming: a non-local volume (e.g.
/// SMB), or DEBUG SC_SIMULATE_LINK is set.
+ (BOOL)shouldUseCacheForFileURL:(NSURL *)fileURL;

#if DEBUG
/**
 The background prefetcher for this archive or folder, when a caching byte source
 was built for it (non-local volume, or DEBUG SC_SIMULATE_LINK). nil on
 local volumes, where reads go straight to disk.
 */
@property (nonatomic, readonly, nullable) TSSTArchiveStreamer *streamer;
#endif

/// Maps \c entryIndex to its reading-order span and moves the streamer's
/// current position there, without forcing it to the front of the queue.
- (void)noteReadingEntryIndex:(NSInteger)entryIndex;

/// Like -noteReadingEntryIndex:, but also wakes the streamer immediately
/// (used when the user jumps to a page far from the current position).
- (void)prioritizeEntryIndex:(NSInteger)entryIndex;

/// YES when reading this entry's bytes won't have to wait on the network:
/// there's no streaming cache at all (local file, or no zip index), or the
/// entry's whole span is already cached. Used to decide whether displaying
/// a page can happen synchronously on main.
- (BOOL)isEntryIndexCached:(NSInteger)entryIndex;

/// Batch form of -isEntryIndexCached: under one cache lock acquisition:
/// the positions within `entryIndexes` (NSNumbers) that are cached.
- (NSIndexSet *)indexesOfCachedEntries:(NSArray<NSNumber *> *)entryIndexes;

/// The group a page snapshot should read bytes through, resolved on the
/// context's queue so the snapshot can be used from any thread: itself for
/// archives and PDFs, the streaming folder above for a folder's pages, and
/// nil when the page should just read its own file.
- (nullable TSSTManagedGroup *)groupForOffQueueReads;

/// YES only when this archive actually streams through a caching byte
/// source (non-local volume or SC_SIMULATE_LINK). Unlike
/// -isEntryIndexCached:, this is NO for ordinary local files, so callers
/// can tell "nothing to wait for" apart from "nothing to show progress for".
@property (nonatomic, readonly) BOOL isStreamingArchive;

/// The caching byte source serving this group's pages (its own, or the
/// folder above's), for tests that inspect the link underneath.
- (nullable TSSTCachingByteSource *)cachingSourceForTesting;

/// How many times a restored session's file-path map has been built.
- (NSUInteger)restoredPathMapBuildCountForTesting;

@end

@interface TSSTManagedArchive : TSSTManagedGroup

/// An `NSArray` with archive file extensions which the software supports.
@property (class, readonly, copy) NSArray<NSString*> *archiveExtensions;
/// An `NSArray` with archive UTIs which the software supports.
@property (class, readonly, copy) NSArray<NSString*> *archiveTypes;
/// An `NSArray` with file extensions for which software support QuickLook for.
@property (class, readonly, copy) NSArray<NSString*> *quicklookExtensions;
/// Recurses through archives looking for archives and images */
- (void)nestedArchiveContents;
@property (readonly) BOOL quicklookCompatible;

/**
 Name of an entry by index, preferring the fast zip index (when this
 archive is a zip and one has been built) over -instance. Safe to call
 whichever backend is in use.
 */
- (nullable NSString *)nameOfEntryAtIndex:(NSInteger)index;

/**
 Background-safe scan of the archive at `fileURL`. Builds the backend
 (TSSTZipIndex or XADArchive) itself and returns a record describing every
 entry, without touching any `NSManagedObject` / MOC. Safe to call from
 any thread. `password` may be nil; if the archive needs one and none is
 supplied, the password prompt is bounced to the main thread.
 */
+ (nullable TSSTArchiveScanRecord *)scanRecordForFileURL:(NSURL *)fileURL name:(nullable NSString *)name password:(nullable NSString *)password;

/**
 Applies a scan record produced by `+scanRecordForFileURL:name:password:`
 to this (already-inserted) managed object: inserts the child entities,
 reuses the record's already-built backend (no re-parsing), and sets
 password / solidDirectory as needed. Must be called on the MOC's queue.
 */
- (void)applyScanRecord:(TSSTArchiveScanRecord *)record;

/**
 Removes the temp files and directories that scan records (and, recursively,
 their nested archives/PDFs) created. \c records are either top-level records
 or the children of an archive record. Use when a scan result is dropped
 without being applied; applied records are cleaned up by their managed
 objects instead. Never touches a folder scan's own source files.
 */
+ (void)discardScanRecords:(NSArray<TSSTArchiveScanRecord *> *)records;

/**
 Progressive counterpart to +scanRecordForFileURL:.../-applyScanRecord:,
 used for top-level RAR/7z archives (and zips under SC_FORCE_XAD). Runs on
 the calling thread (background); calls perBatch possibly many times as
 entries are discovered, so pages can be inserted while the header walk
 is still running. Zip archives still take the single-batch fast
 path internally (one call, isFinal YES) since building the zip index is
 already fast and synchronous.

 \c fileURL, \c name and \c password are plain values captured by the
 caller on the main thread: the scan runs off-main and never reads the
 managed object's attributes. A multi-volume RAR set with an unreadable
 volume is listed through XADArchive from the file itself, and a
 missing-volume error is delivered in the final record's scanErrors.

 On the first call, the caller must apply the returned record's header
 (backend/password/streamer) via -applyScanRecordHeader: on the MOC's
 queue before inserting children. Every call's newChildren (a subset of
 the eventual full child list, not cumulative) should be applied via
 -insertChildRecords:, also on the MOC's queue.
 */
- (void)scanArchiveProgressivelyForFileURL:(NSURL *)fileURL name:(nullable NSString *)name password:(nullable NSString *)password perBatch:(void (^)(id _Nullable recordSoFar, NSArray<id> *newChildren, BOOL isFinal, NSError * _Nullable error))perBatch;

/**
 Main-thread only: applies just the header fields of a scan record
 (backend/password/solidDirectory, starts the streamer for a zip's
 caching source) without touching children. Called once, on the first
 batch/call.
 */
- (void)applyScanRecordHeader:(id)record;

/**
 Main-thread only: called once the progressive XAD parse (from
 -scanArchiveProgressivelyForFileURL:name:password:perBatch:) has fully finished, with every entry
 it found, in discovery order. Builds the prefetcher's reading-order
 spans. No-op if this archive isn't streaming through a caching byte
 source (local volume, no SC_SIMULATE_LINK).
 */
- (void)startXADStreamerWithAllEntries:(NSArray<TSSTXADArchiveEntry *> *)entries;

#pragma mark Folder access (sandbox)

/// nil (the default) uses the open panel.
+ (nullable id<TSSTFolderAccessProvider>)folderAccessProvider;
+ (void)setFolderAccessProvider:(nullable id<TSSTFolderAccessProvider>)provider;
+ (void)setFolderBookmarkDefaults:(nullable NSUserDefaults *)defaults;
+ (void)resetFolderAccessSessionState;
+ (BOOL)storeAccessBookmarkForFolderURL:(NSURL *)folderURL;
+ (nullable NSURL *)resolvedAccessBookmarkForFolderURL:(NSURL *)folderURL;
@end

/// Posted (object = the TSSTManagedGroup) as the streamer's cache fills
/// in, throttled to ~4 Hz. userInfo is currently unused.
extern NSString * const TSSTArchiveCacheProgressNotification;

@interface TSSTManagedPDF : TSSTManagedGroup

/// Parses PDFs into something Simple Comic can use.
///
/// Creates an image `NSManagedObject` for every "page" in a pdf.
- (void)pdfContents;

@end

/// Creates (and returns the path of) the first item in the temp directory,
/// trying "candidateName(0)", "(1)", ... in turn, that did not exist yet: a
/// directory if `isDirectory`, otherwise an empty file (with any missing
/// parent folders). Creating it is what claims the name, so scans running on
/// different threads can never be handed the same path.
extern NSString *TSSTCreateUnusedTempPath(BOOL isDirectory, NSString *NS_NOESCAPE (^candidateName)(NSInteger attempt));

NS_ASSUME_NONNULL_END

#import "TSSTManagedGroup+CoreDataProperties.h"
