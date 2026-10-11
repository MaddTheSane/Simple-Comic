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
@class TSSTXADArchiveEntry;

NS_ASSUME_NONNULL_BEGIN

/// Value-only result of scanning an archive off the main thread (see
/// +[TSSTManagedArchive scanRecordForFileURL:name:password:]); the rest of its
/// state is private to TSSTManagedGroup.m.
@interface TSSTArchiveScanRecord : NSObject
@property (nonatomic, readonly, strong, nullable) NSArray<TSSTArchiveScanRecord *> *children;
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

/**
 Returns a set with all the images found in the key in union with the ones from other groups.
 
 @return NSSet with all images found in context.
 */
@property (readonly, copy) NSSet<TSSTPage*> *nestedImages;

/**
 Goes through various files like pdfs, images, text files
 from the path folder and it's subfolders and add these
 to the Core Data for the managedObjectContext
 with the info needed to deal with the files.
 */
- (void)nestedFolderContents;

/**
  Attempts to resolve the filleURL, but doesn't alter self on failure. Note: If it fails, always call fileURL to truly update the state.
 */
- (nullable NSURL *)probeFileURL;

@end

@interface TSSTManagedArchive : TSSTManagedGroup

//! An `NSArray` with archive file extensions which the software supports.
@property (class, readonly, copy) NSArray<NSString*> *archiveExtensions;
//! An `NSArray` with archive UTIs which the software supports.
@property (class, readonly, copy) NSArray<NSString*> *archiveTypes;
//! An `NSArray` with file extensions for which software support QuickLook for.
@property (class, readonly, copy) NSArray<NSString*> *quicklookExtensions;
/**  Recurses through archives looking for archives and images */
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
 Removes the temp files and directories a scan record (and, recursively, its
 nested archives/PDFs) created. Use when a record is dropped without being
 applied; applied records are cleaned up by their managed objects instead.
 */
+ (void)discardScanRecord:(TSSTArchiveScanRecord *)record;

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
 managed object's attributes.

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
 Main-thread only: inserts the Core Data entities for newChildren (a
 subset of some record's children) and returns the new TSSTPage/-derived
 image pages to union into session.images. Safe to call multiple times
 as more children arrive from -scanArchiveProgressivelyForFileURL:name:password:perBatch:.
 */
- (NSSet<TSSTPage *> *)insertChildRecords:(NSArray<id> *)newChildren;

/**
 Main-thread only: called once the progressive XAD parse (from
 -scanArchiveProgressivelyForFileURL:name:password:perBatch:) has fully finished, with every entry
 it found, in discovery order. Builds the prefetcher's reading-order
 spans. No-op if this archive isn't streaming through a caching byte
 source (local volume, no SC_SIMULATE_LINK).
 */
- (void)startXADStreamerWithAllEntries:(NSArray<TSSTXADArchiveEntry *> *)entries;

#if DEBUG
/**
 The background prefetcher for this archive, when a caching byte source
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
/// the positions within \c entryIndexes (NSNumbers) that are cached.
- (NSIndexSet *)indexesOfCachedEntries:(NSArray<NSNumber *> *)entryIndexes;

/// YES only when this archive actually streams through a caching byte
/// source (non-local volume or SC_SIMULATE_LINK). Unlike
/// -isEntryIndexCached:, this is NO for ordinary local files, so callers
/// can tell "nothing to wait for" apart from "nothing to show progress for".
@property (nonatomic, readonly) BOOL isStreamingArchive;

@end

/// Posted (object = the TSSTManagedArchive) as the streamer's cache fills
/// in, throttled to ~4 Hz. userInfo is currently unused.
extern NSString * const TSSTArchiveCacheProgressNotification;

@interface TSSTManagedPDF : TSSTManagedGroup

/**  Parses PDFs into something Simple Comic can use.
 *  Creates an image `NSManagedObject` for every "page" in a pdf. */
- (void)pdfContents;

@end

NS_ASSUME_NONNULL_END

#import "TSSTManagedGroup+CoreDataProperties.h"
