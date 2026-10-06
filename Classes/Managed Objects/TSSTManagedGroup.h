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
 Runs \c during inside a URL-error batch: bookmark errors raised meanwhile are
 presented as one summary alert for \c groupName. Joins an enclosing batch on
 this thread if there is one. The batch is always closed, even if \c during
 throws. Call on the main thread.
 */
+ (void)batchURLErrorsForGroupName:(NSString *)groupName during:(dispatch_block_t)during;

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

@end

@interface TSSTManagedPDF : TSSTManagedGroup

/**  Parses PDFs into something Simple Comic can use.
 *  Creates an image `NSManagedObject` for every "page" in a pdf. */
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
