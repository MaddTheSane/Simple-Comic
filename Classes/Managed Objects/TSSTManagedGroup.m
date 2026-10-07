//
//  TSSTManagedGroup.m
//  SimpleComic
//
//  Created by Alexander Rauchfuss on 6/2/07.
//  Copyright 2007 Dancing Tortoise Software. All rights reserved.
//

#import "TSSTManagedGroup.h"
#import "TSSTManagedGroup+CoreDataProperties.h"
#import "SimpleComicAppDelegate.h"
#import <XADMaster/XADArchive.h>
#import <Quartz/Quartz.h>
#import "TSSTImageUtilities.h"
#import "TSSTPage.h"
#import "TSSTPage+CoreDataProperties.h"
#import "TSSTZipIndex.h"
#import "TSSTArchiveByteSource.h"
#import "TSSTCachingByteSource.h"
#import "TSSTArchiveStreamer.h"

@interface TSSTManagedArchive () <XADArchiveDelegate>
{
	// Fast-path zip listing/reading, built lazily. Not persisted -- if the
	// managed object is re-fetched (e.g. session restore) this is nil again
	// and gets lazily rebuilt from fileURL, or the code falls back to XAD.
	//
	// The lock is a condition guarding only the state flags: a build (slow
	// I/O on a network volume) runs with no lock held, and concurrent
	// callers wait for its result instead of building a second index.
	TSSTZipIndex *_zipIndex;
	BOOL _zipIndexAttempted;
	BOOL _zipIndexBuilding;
	NSCondition *_zipIndexLock;

	// Set only when the zip index was built on a caching byte source (slow
	// volume, or SC_SIMULATE_LINK). nil on local volumes.
	TSSTCachingByteSource *_cachingSource;
	TSSTArchiveStreamer *_streamer;
	// Reading-order span index for each zip entry index, built alongside
	// the streamer's spans; used by -noteReadingEntryIndex:/-prioritizeEntryIndex:.
	NSDictionary<NSNumber *, NSNumber *> *_entryIndexToSpanIndex;
}
-(void)archiveNeedsPassword:(XADArchive *)archive;

@end

// Kinds of children a scan can produce, mirroring the entity types
// -nestedArchiveContents used to insert directly.
typedef NS_ENUM(NSInteger, TSSTArchiveScanRecordKind)
{
	TSSTArchiveScanRecordKindImage,
	TSSTArchiveScanRecordKindArchive,
	TSSTArchiveScanRecordKindPDF,
};

/*
 * Plain value object describing one archive's worth of scanned entries.
 * Built entirely off values (no NSManagedObject / MOC access) so it can be
 * produced on a background queue; a matching -applyScanRecord: on the main
 * thread walks it and inserts the actual Core Data entities.
 */
@interface TSSTArchiveScanRecord : NSObject

@property (nonatomic) TSSTArchiveScanRecordKind kind;
@property (nonatomic, copy, nullable) NSString *name;      // entry name / archive name
@property (nonatomic, copy, nullable) NSString *imagePath; // image/text kind: entry name used as imagePath
@property (nonatomic, copy, nullable) NSString *path;      // archive/pdf kind: temp file path
@property (nonatomic) NSInteger index;
@property (nonatomic) BOOL text;

// Archive/self-describing fields (used for the top-level record and for
// TSSTArchiveScanRecordKindArchive children):
@property (nonatomic, copy, nullable) NSString *password;
@property (nonatomic, copy, nullable) NSString *solidDirectory;
@property (nonatomic, strong, nullable) id builtInstance; // TSSTZipIndex or XADArchive, pre-built, ready to reuse
@property (nonatomic, strong, nullable) TSSTCachingByteSource *builtCachingSource; // set only when builtInstance's zip index reads through a cache
@property (nonatomic, copy, nullable) NSArray<TSSTArchiveScanRecord *> *children;
@property (nonatomic, copy, nullable) NSString *backendDescription; // "zip-index" / "XAD", for logging

// PDF kind:
@property (nonatomic) NSInteger pdfPageCount;

@end

@implementation TSSTArchiveScanRecord
@end

/*
 * Lightweight XADArchiveDelegate used only while building an XADArchive on
 * a background scan queue. It must never touch a managed object -- the
 * password prompt itself is bounced to the main thread since it's UI.
 */
@interface TSSTScanArchiveDelegate : NSObject <XADArchiveDelegate>
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy, nullable) NSString *password;
@end

@implementation TSSTScanArchiveDelegate

- (void)archiveNeedsPassword:(XADArchive *)archive
{
	NSString *password = self.password;
	if (password)
	{
		archive.password = password;
		return;
	}

	__block NSString *promptedPassword = nil;
	NSString *path = self.path;
	void (^promptBlock)(void) = ^{
		promptedPassword = [(SimpleComicAppDelegate*)[NSApp delegate] passwordForArchiveWithPath: path];
	};

	if ([NSThread isMainThread])
	{
		promptBlock();
	}
	else
	{
		dispatch_sync(dispatch_get_main_queue(), ^{
			promptBlock();
		});
	}
	password = promptedPassword;

	archive.password = password;
	self.password = password;
}

@end

/// Names a scan skips: empty, or whose last component starts with ".".
static BOOL TSSTScanEntryNameIsHidden(NSString *fileName)
{
	return fileName.length == 0 || [fileName.lastPathComponent hasPrefix: @"."];
}

typedef NS_ENUM(NSInteger, TSSTScanEntryClass)
{
	TSSTScanEntryClassIgnored,
	TSSTScanEntryClassImage,
	TSSTScanEntryClassText,
	TSSTScanEntryClassArchive,
	TSSTScanEntryClassPDF,
};

/// What a scan does with an archive entry of this name.
static TSSTScanEntryClass TSSTClassifyScanEntryName(NSString *fileName)
{
	if (TSSTScanEntryNameIsHidden(fileName)) { return TSSTScanEntryClassIgnored; }
	NSString *extension = fileName.pathExtension.lowercaseString;
	if ([[TSSTPage imageExtensions] containsObject: extension]) { return TSSTScanEntryClassImage; }
	if ([[TSSTManagedArchive archiveExtensions] containsObject: extension]) { return TSSTScanEntryClassArchive; }
	if ([[TSSTPage textExtensions] containsObject: extension]) { return TSSTScanEntryClassText; }
	if ([extension isEqualToString: @"pdf"]) { return TSSTScanEntryClassPDF; }
	return TSSTScanEntryClassIgnored;
}

/// YES when every entry a scan must read (nested archives/PDFs) can be
/// extracted by the zip index; otherwise the scan falls back to XAD, which
/// also handles non-zip formats and solid archives.
static BOOL TSSTZipIndexCanScan(TSSTZipIndex *zi)
{
	if (!zi) { return NO; }
	for (NSUInteger i = 0; i < zi.numberOfEntries; ++i)
	{
		TSSTScanEntryClass entryClass = TSSTClassifyScanEntryName([zi nameOfEntry: i]);
		if ((entryClass == TSSTScanEntryClassArchive || entryClass == TSSTScanEntryClassPDF) && ![zi canExtractEntry: i])
		{
			return NO;
		}
	}
	return YES;
}

static TSSTArchiveScanRecord *TSSTImageChildRecord(NSString *fileName, NSInteger index, BOOL text)
{
	TSSTArchiveScanRecord *child = [TSSTArchiveScanRecord new];
	child.kind = TSSTArchiveScanRecordKindImage;
	child.imagePath = fileName;
	child.index = index;
	child.text = text;
	return child;
}

/// Writes a nested archive's bytes to a fresh temp file (named
/// "<n>-<fileName>", n bumped until unused) and returns its path.
static NSString *TSSTWriteNestedArchiveTempFile(NSData *fileData, NSString *fileName)
{
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSInteger collision = 0;
	NSString *archivePath = nil;
	do {
		archivePath = [NSString stringWithFormat: @"%li-%@", (long)collision, fileName];
		archivePath = [NSTemporaryDirectory() stringByAppendingPathComponent: archivePath];
		++collision;
	} while ([fileManager fileExistsAtPath: archivePath]);

	[fileManager createDirectoryAtPath: [archivePath stringByDeletingLastPathComponent]
			withIntermediateDirectories: YES
							 attributes: nil
								  error: NULL];
	[fileManager createFileAtPath: archivePath contents: fileData attributes: nil];
	return archivePath;
}

/// Extracts a nested archive to a temp file and scans it, returning its
/// own record as an archive child.
static TSSTArchiveScanRecord *TSSTNestedArchiveChildRecord(NSData *fileData, NSString *fileName, NSMutableArray<NSError *> *errors)
{
	NSString *archivePath = TSSTWriteNestedArchiveTempFile(fileData, fileName);
	TSSTArchiveScanRecord *nestedRecord = [TSSTManagedArchive scanRecordForFileURL: [NSURL fileURLWithPath: archivePath] name: fileName password: nil errors: errors];
	nestedRecord.kind = TSSTArchiveScanRecordKindArchive;
	nestedRecord.path = archivePath;
	return nestedRecord;
}

/// Writes a nested PDF's bytes to the temp directory (under its base name,
/// "<n>-" prefixed until unused) and returns its record, PDFDocument built.
static TSSTArchiveScanRecord *TSSTPDFChildRecord(NSData *fileData, NSString *fileName)
{
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSString *baseName = fileName.lastPathComponent;
	NSString *archivePath = [NSTemporaryDirectory() stringByAppendingPathComponent: baseName];
	NSInteger pdfCollision = 0;
	while ([fileManager fileExistsAtPath: archivePath])
	{
		++pdfCollision;
		baseName = [NSString stringWithFormat: @"%li-%@", (long)pdfCollision, fileName.lastPathComponent];
		archivePath = [NSTemporaryDirectory() stringByAppendingPathComponent: baseName];
	}
	[fileData writeToFile: archivePath atomically: YES];

	TSSTArchiveScanRecord *child = [TSSTArchiveScanRecord new];
	child.kind = TSSTArchiveScanRecordKindPDF;
	child.path = archivePath;
	child.name = fileName;
	PDFDocument *pdfDoc = [[PDFDocument alloc] initWithURL: [NSURL fileURLWithPath: archivePath]];
	child.builtInstance = pdfDoc;
	child.pdfPageCount = pdfDoc.pageCount;
	return child;
}

/*
 * setFileURL:/fileURL used to call -[NSApp presentError:] directly, once per
 * bad file. Scanning a folder or archive with many unreadable entries could
 * therefore pop up dozens or thousands of modal alerts in a row (#147, #123).
 * These helpers let the recursive scan in nestedFolderContents/
 * nestedArchiveContents batch those errors and present a single summary
 * alert once the whole top-level scan finishes, while single top-level
 * file opens (scan depth 0) still present their error immediately.
 *
 * Scans can run on background threads, so the batch is kept per thread (in
 * the thread dictionary) rather than in shared statics: each scan only ever
 * touches its own batch, which needs no locking and keeps concurrent scans'
 * errors from being mixed into one alert.
 */
@interface TSSTURLErrorBatch : NSObject
@property NSInteger depth;
@property (copy) NSString *groupName;
@property (readonly) NSMutableArray<NSError *> *errors;
@end

@implementation TSSTURLErrorBatch
- (instancetype)init
{
	if ((self = [super init]))
	{
		_errors = [NSMutableArray array];
	}
	return self;
}
@end

static NSString *const kURLErrorBatchThreadKey = @"TSSTManagedGroupURLErrorBatch";

static TSSTURLErrorBatch *CurrentURLErrorBatch(void)
{
	return NSThread.currentThread.threadDictionary[kURLErrorBatchThreadKey];
}
NSString * const TSSTArchiveCacheProgressNotification = @"TSSTArchiveCacheProgressNotification";

@implementation TSSTManagedGroup

+ (void)beginURLErrorBatchForGroupName:(NSString *)groupName
{
	TSSTURLErrorBatch *batch = CurrentURLErrorBatch();
	if (batch == nil)
	{
		batch = [[TSSTURLErrorBatch alloc] init];
		batch.groupName = groupName;
		NSThread.currentThread.threadDictionary[kURLErrorBatchThreadKey] = batch;
	}
	batch.depth++;
}

/// Pure summary-message builder, split out of endURLErrorBatch so it can be
/// unit tested without going through NSAlert/-runModal.
+ (nullable NSString *)urlErrorBatchSummaryMessageForErrorCount:(NSUInteger)errorCount groupName:(NSString *)groupName
{
	if (errorCount == 0)
	{
		return nil;
	}
	if (errorCount == 1)
	{
		return [NSString stringWithFormat: NSLocalizedString(@"1 file in “%@” could not be opened.", @"single unreadable file summary"), groupName];
	}
	return [NSString stringWithFormat: NSLocalizedString(@"%lu files in “%@” could not be opened.", @"multiple unreadable files summary"), (unsigned long)errorCount, groupName];
}

+ (void)endURLErrorBatch
{
	TSSTURLErrorBatch *batch = CurrentURLErrorBatch();
	if (batch == nil || --batch.depth > 0)
	{
		return;
	}
	[NSThread.currentThread.threadDictionary removeObjectForKey: kURLErrorBatchThreadKey];
	NSString *summary = [self urlErrorBatchSummaryMessageForErrorCount: batch.errors.count groupName: batch.groupName];
	if (summary == nil)
	{
		return;
	}
	NSString *detail = batch.errors.firstObject.localizedDescription ?: @"";
	// Alerts belong on the main thread; don't block the scan thread on the user.
	dispatch_block_t present = ^{
		NSAlert *alert = [[NSAlert alloc] init];
		alert.alertStyle = NSAlertStyleWarning;
		alert.messageText = summary;
		alert.informativeText = detail;
		[alert runModal];
	};
	if (NSThread.isMainThread)
	{
		present();
	}
	else
	{
		dispatch_async(dispatch_get_main_queue(), present);
	}
}

+ (void)reportURLError:(NSError *)error
{
	TSSTURLErrorBatch *batch = CurrentURLErrorBatch();
	if (batch != nil)
	{
		[batch.errors addObject: error];
	}
	else
	{
		[NSApp presentError: error];
	}
}

+ (void)batchURLErrorsForGroupName:(NSString *)groupName during:(void (^)(NSMutableArray<NSError *> *errors))during
{
	[self beginURLErrorBatchForGroupName: groupName];
	NSMutableArray<NSError *> *errors = [NSMutableArray array];
	during(errors);
	for (NSError *error in errors)
	{
		[self reportURLError: error];
	}
	[self endURLErrorBatch];
}

#pragma mark - Testing support
// Accessors for the current thread's batch, used only by
// TSSTManagedGroupURLErrorBatchTests so the test target can observe queueing
// behavior without ever triggering the NSAlert/-runModal path.

+ (NSInteger)urlErrorBatchDepthForTesting
{
	return CurrentURLErrorBatch().depth;
}

+ (NSUInteger)pendingURLErrorCountForTesting
{
	return CurrentURLErrorBatch().errors.count;
}

+ (void)resetURLErrorBatchStateForTesting
{
	[NSThread.currentThread.threadDictionary removeObjectForKey: kURLErrorBatchThreadKey];
}

- (void)awakeFromInsert
{
	[super awakeFromInsert];
	groupLock = [NSLock new];
	instance = nil;
}

- (void)awakeFromFetch
{
	[super awakeFromFetch];
	groupLock = [NSLock new];
	instance = nil;
}

- (void)willTurnIntoFault
{
	NSError * error = nil;
	if(self.nested)
	{
		NSURL *fileURL = self.fileURL;
		if(fileURL != nil && ![[NSFileManager defaultManager] removeItemAtURL:fileURL  error: &error])
		{
			NSLog(@"%@",[error localizedDescription]);
		}
	}
	[self.fileURL stopAccessingSecurityScopedResource];
}

- (void)didTurnIntoFault
{
	instance = nil;
	groupLock = nil;
}

@synthesize fileURL=_url;

- (void)setFileURL:(NSURL *)fileURL
{
	if (_url && _url != fileURL) {
		// Balance the access we started on the old URL, not the new one.
		[_url stopAccessingSecurityScopedResource];
	}
	_url = fileURL;
	NSError * urlError = nil;
	[fileURL startAccessingSecurityScopedResource];
	NSData * bookmarkData = [fileURL bookmarkDataWithOptions: NSURLBookmarkCreationWithSecurityScope | NSURLBookmarkCreationSecurityScopeAllowOnlyReadAccess
							  includingResourceValuesForKeys: @[NSURLVolumeURLForRemountingKey, NSURLVolumeUUIDStringKey]
											   relativeToURL: nil
													   error: &urlError];
	if (bookmarkData == nil || urlError != nil)
	{
		bookmarkData = nil;
		[TSSTManagedGroup reportURLError: urlError];
	}
	self.pathData = bookmarkData;
}

/// helper: common code of \c probeFileURL and \c fileURL
- (NSURL *)ResolvingURLWithStale:(BOOL *)stalep error:(NSError **)errorp {
	return self.pathData ? [NSURL URLByResolvingBookmarkData: self.pathData
												options: NSURLBookmarkResolutionWithoutUI | NSURLBookmarkResolutionWithSecurityScope
										  relativeToURL: nil
									bookmarkDataIsStale: stalep
												  error: errorp] : nil;
}

- (NSURL *)probeFileURL {
	if (_url && [_url checkResourceIsReachableAndReturnError:NULL]) {
		return _url;
	}
	NSError * urlError = nil;
	BOOL stale = NO;
	NSURL *fileURL = [self ResolvingURLWithStale:&stale error:&urlError];
	if (stale && fileURL) {
		// regenerate stale bookmark.
		self.fileURL = fileURL;
	} else if (fileURL) {
		//cache fileURL
		_url = fileURL;
	}
	return fileURL;;
}

- (NSURL *)fileURL
{
	if (_url && [_url checkResourceIsReachableAndReturnError:NULL]) {
		return _url;
	}
	NSError * urlError = nil;
	BOOL stale = NO;
	NSURL *fileURL = [self ResolvingURLWithStale:&stale error:&urlError];
	//For backwards compatibility
	if (fileURL == nil || urlError != nil) {
		NSError *othErr = nil;
		fileURL = [NSURL URLByResolvingBookmarkData: self.pathData
											options: 0
									  relativeToURL: nil
								bookmarkDataIsStale: &stale
											  error: &othErr];
		
		if (fileURL && othErr == nil) {
			NSOpenPanel *panel = [NSOpenPanel openPanel];
			panel.canChooseDirectories = YES;
			panel.allowsMultipleSelection = NO;
			//panel.expanded = YES;
			panel.message = [NSString stringWithFormat:NSLocalizedString(@"Please re-select '%@'", @"re-select file request"), fileURL.lastPathComponent];
			panel.directoryURL = [fileURL URLByDeletingLastPathComponent];
			
			if ([panel runModal] == NSModalResponseOK) {
				othErr = nil;
				NSData *bookmarkData = [panel.URL bookmarkDataWithOptions: NSURLBookmarkCreationWithSecurityScope | NSURLBookmarkCreationSecurityScopeAllowOnlyReadAccess
										   includingResourceValuesForKeys: @[NSURLVolumeURLForRemountingKey, NSURLVolumeUUIDStringKey]
															relativeToURL: nil
																	error: &othErr];
				
				if (bookmarkData) {
					self.pathData = bookmarkData;
					fileURL = [NSURL URLByResolvingBookmarkData: bookmarkData
														options: NSURLBookmarkResolutionWithoutUI | NSURLBookmarkResolutionWithSecurityScope
												  relativeToURL: nil
											bookmarkDataIsStale: &stale
														  error: &othErr];
					
				}
			} else {
				fileURL = nil;
			}
			urlError = othErr;
		}
	}
	
	if (fileURL == nil || urlError != nil)
	{
		fileURL = nil;
		[[self managedObjectContext] deleteObject: self];
		if (urlError) {
			[TSSTManagedGroup reportURLError: urlError];
		}
	}
	else if (stale)
	{
		// regenerate stale bookmark.
		self.fileURL = fileURL;
	} else {
		//cache fileURL
		_url = fileURL;
	}
	
	return fileURL;
}

- (void)setPath:(NSString *)newPath
{
	self.fileURL = [[NSURL alloc] initFileURLWithPath: newPath];
}


- (NSString *)path
{
	return self.fileURL.path;
}


- (id)instance
{
	return nil;
}

- (NSData *)dataForPageIndex:(NSInteger)index
{
	return nil;
}

- (void)requestDataForPageIndex:(NSInteger)index completionHandler:(void(^)(NSData *_Nullable pageData, NSError *_Nullable error))callback
{
	callback(nil, [NSError errorWithDomain:NSOSStatusErrorDomain code:unimpErr userInfo:nil]);
}

- (NSManagedObject *)topLevelGroup
{
	return self;
}

- (nullable NSString *)nameOfEntryAtIndex:(NSInteger)index
{
	return nil;
}

- (void)nestedFolderContents
{
	[TSSTManagedGroup beginURLErrorBatchForGroupName: self.name ?: self.fileURL.lastPathComponent];
	NSURL * folderPath = self.fileURL;
	NSFileManager * fileManager = [NSFileManager defaultManager];
	TSSTManagedGroup * nestedDescription;
	NSError * error = nil;
	NSArray<NSURL*> * nestedFiles = [fileManager contentsOfDirectoryAtURL:folderPath includingPropertiesForKeys:nil options:(NSDirectoryEnumerationSkipsSubdirectoryDescendants | NSDirectoryEnumerationSkipsHiddenFiles) error:&error];
	if (error)
	{
		NSLog(@"%@",[error localizedDescription]);
	}
	BOOL isDirectory;
	
	for (NSURL *path in nestedFiles)
	{
		nestedDescription = nil;
		NSString *fileExtension = [[path pathExtension] lowercaseString];
		BOOL exists = [fileManager fileExistsAtPath: path.path isDirectory: &isDirectory];
		if(exists && ![[[path lastPathComponent] substringToIndex: 1] isEqualToString: @"."])
		{
			if(isDirectory)
			{
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"ImageGroup" inManagedObjectContext: [self managedObjectContext]];
				nestedDescription.fileURL = path;
				nestedDescription.name = path.relativePath ?: path.path;
				[nestedDescription nestedFolderContents];
			}
			else if([[TSSTManagedArchive archiveExtensions] containsObject: fileExtension])
			{
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"Archive" inManagedObjectContext: [self managedObjectContext]];
				nestedDescription.fileURL = path;
				nestedDescription.name = path.relativePath ?: path.path;
				[(TSSTManagedArchive *)nestedDescription nestedArchiveContents];
			}
			else if([fileExtension isEqualToString: @"pdf"])
			{
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"PDF" inManagedObjectContext: [self managedObjectContext]];
				nestedDescription.fileURL = path;
				nestedDescription.name = path.relativePath ?: path.path;
				[(TSSTManagedPDF *)nestedDescription pdfContents];
			}
			else if([[TSSTPage imageExtensions] containsObject: fileExtension])
			{
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"Image" inManagedObjectContext: [self managedObjectContext]];
				[nestedDescription setValue: path.path forKey: @"imagePath"];
			}
			else if ([[TSSTPage textExtensions] containsObject: fileExtension])
			{
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"Image" inManagedObjectContext: [self managedObjectContext]];
				[nestedDescription setValue: path.path forKey: @"imagePath"];
				[nestedDescription setValue: @YES forKey: @"text"];
			}
			
			if(nestedDescription)
			{
				[nestedDescription setValue: self forKey: @"group"];
			}
		}
	}
	[TSSTManagedGroup endURLErrorBatch];
}

- (NSSet *)nestedImages
{
	NSMutableSet * allImages = [self.images mutableCopy];
	NSSet * groups = self.groups;
	for(TSSTManagedGroup * group in groups)
	{
		[allImages unionSet: group.nestedImages];
	}
	
	return allImages;
}

@end


@implementation TSSTManagedArchive

+ (NSArray *)archiveExtensions
{
	static NSArray * extensions = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSArray *archives = self.archiveTypes;
		NSMutableSet<NSString*> *aimageTypes = [[NSMutableSet alloc] initWithCapacity:archives.count];
		for (NSString *uti in archives) {
			NSArray *fileExts =
			CFBridgingRelease(UTTypeCopyAllTagsWithClass((__bridge CFStringRef)uti, kUTTagClassFilenameExtension));
			[aimageTypes addObjectsFromArray:fileExts];
		}
		extensions = [[aimageTypes allObjects] sortedArrayUsingSelector:@selector(compare:)];
	});
	
	return extensions;
}

+ (NSArray*)archiveTypes
{
	static NSArray * extensions = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		// TODO: have this expansive?
		extensions = @[@"com.rarlab.rar-archive", @"cx.c3.cbr-archive",
					   (NSString*)kUTTypeZipArchive, @"cx.c3.cbz-archive",
					   @"org.7-zip.7-zip-archive", @"cx.c3.cb7-archive",
					   @"public.archive.lha", @"cx.c3.lha-archive",
					   @"com.dancingtortoise.simplecomic.cbt", @"public.tar-archive",
					   @"com.yacreader.yacreader.cbr", @"com.yacreader.yacreader.cbz",
					   @"com.simplecomic.cbz-archive", @"com.simplecomic.cbr-archive",
					   @"com.simplecomic.cb7-archive", @"com.simplecomic.cbt-archive"];
	});
	
	return extensions;
}

+ (NSArray *)quicklookExtensions
{
	static NSArray * extensions = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		extensions = @[@"cbr", @"cbz", @"cbt", @"cb7"];
	});
	
	return extensions;
}

- (void)awakeFromInsert
{
	[super awakeFromInsert];
	_zipIndexLock = [NSCondition new];
}

- (void)awakeFromFetch
{
	[super awakeFromFetch];
	_zipIndexLock = [NSCondition new];
}

- (void)willTurnIntoFault
{
	NSError * error;
	[_streamer cancel];
	[_cachingSource invalidate];

	if(self.nested)
	{
		if(![[NSFileManager defaultManager] removeItemAtPath: self.path error: &error])
		{
			NSLog(@"%@",[error localizedDescription]);
		}
	}

	NSString * solid  = self.solidDirectory;
	if(solid)
	{
		if(![[NSFileManager defaultManager] removeItemAtPath: solid error: &error])
		{
			NSLog(@"%@",[error localizedDescription]);
		}
	}
}

/// YES when the given file is worth caching/streaming: a non-local
/// volume (e.g. SMB), or DEBUG SC_SIMULATE_LINK is set (so the app can be
/// exercised against the caching path using a local file).
+ (BOOL)shouldUseCacheForFileURL:(NSURL *)fileURL
{
#if DEBUG
	if ([[NSProcessInfo processInfo].environment[@"SC_SIMULATE_LINK"] length] > 0)
	{
		return YES;
	}
#endif
	NSNumber *isLocal = nil;
	NSError *error = nil;
	if ([fileURL getResourceValue: &isLocal forKey: NSURLVolumeIsLocalKey error: &error] && isLocal)
	{
		return !isLocal.boolValue;
	}
	return NO;
}

/// Builds the zip index (and, when applicable, the caching byte source it
/// reads through) for \c fileURL, or returns nil to make callers use
/// XADArchive (non-zips, unreadable files, unsupported zip features).
/// Shared by the lazy -zipIndex accessor and the background scan so both
/// apply the same policy: file -> [simulated link ->] [caching source ->]
/// zip index. DEBUG builds: SC_FORCE_XAD skips the index, and
/// SC_SIMULATE_LINK=<profile> reads through a simulated slow link so
/// slow-volume behaviour can be checked against a local file.
+ (nullable TSSTZipIndex *)buildZipIndexForFileURL:(NSURL *)fileURL cachingSource:(TSSTCachingByteSource * _Nullable * _Nullable)cachingSourceOut
{
	if (cachingSourceOut) { *cachingSourceOut = nil; }
#if DEBUG
	if (getenv("SC_FORCE_XAD") != NULL) { return nil; }
#endif
	if (![fileURL checkResourceIsReachableAndReturnError: NULL]) { return nil; }

	id<TSSTArchiveByteSource> source = [TSSTFileByteSource sourceWithFileURL: fileURL error: NULL];
	if (!source) { return nil; }
#if DEBUG
	NSString *simulatedLinkName = [[NSProcessInfo processInfo].environment[@"SC_SIMULATE_LINK"] lowercaseString];
	TSSTSimulatedLinkByteSource *linkSource = simulatedLinkName.length > 0 ? [TSSTSimulatedLinkByteSource linkWithProfileName: simulatedLinkName wrapping: source] : nil;
	if (linkSource)
	{
		linkSource.simulateTime = YES;
		source = linkSource;
	}
#endif

	if ([self shouldUseCacheForFileURL: fileURL])
	{
		TSSTCachingByteSource *cachingSource = [[TSSTCachingByteSource alloc] initWithUpstream: source];
		if (cachingSourceOut) { *cachingSourceOut = cachingSource; }
		source = cachingSource;
	}
	TSSTZipIndex *index = [TSSTZipIndex indexWithByteSource: source error: NULL];
	if (!index && cachingSourceOut && *cachingSourceOut)
	{
		// Not a zip we can read: a half-built cache is invalidated, never leaked.
		[*cachingSourceOut invalidate];
		*cachingSourceOut = nil;
	}
	return index;
}

- (id)instance
{
	if (!instance)
	{
		NSURL *aFileURL = self.fileURL;
		if([aFileURL checkResourceIsReachableAndReturnError:NULL])
		{
			[aFileURL startAccessingSecurityScopedResource];
			instance = [[XADArchive alloc] initWithFileURL: aFileURL delegate: self error:NULL];

			// Set the archive delegate so that password and encoding queries can have a modal pop up.

			if(self.password)
			{
				[instance setPassword: self.password];
			}
		}
	}

	return instance;
}

/// The zip index a scan should read through (with the cache it reads
/// through, if any): nil when the file isn't a zip, SC_FORCE_XAD is set, or
/// the index can't extract every entry the scan needs. The caller then lists
/// through XADArchive, and any cache built for the discarded index is
/// invalidated here.
+ (nullable TSSTZipIndex *)scannableZipIndexForFileURL:(NSURL *)fileURL cachingSource:(TSSTCachingByteSource * _Nullable * _Nonnull)cachingSourceOut
{
	TSSTZipIndex *zi = [self buildZipIndexForFileURL: fileURL cachingSource: cachingSourceOut];
	if (!TSSTZipIndexCanScan(zi))
	{
		[*cachingSourceOut invalidate];
		*cachingSourceOut = nil;
		return nil;
	}
	return zi;
}

/// Makes \c cachingSource this archive's cache, shutting down (streamer and
/// temp directory) any different one it replaces.
- (void)adoptCachingSource:(nullable TSSTCachingByteSource *)cachingSource
{
	if (_cachingSource && _cachingSource != cachingSource)
	{
		[_streamer cancel];
		[_cachingSource invalidate];
	}
	_cachingSource = cachingSource;
}

/// Build-once gate for the lazy accessors. Returns YES to exactly one
/// caller (the builder), which must build with NO lock held and then call
/// TSSTFinishBuild. Every other caller waits until the build is done and
/// gets NO.
static BOOL TSSTBeginBuild(NSCondition *lock, BOOL *attempted, BOOL *building)
{
	[lock lock];
	while (*building) { [lock wait]; }
	BOOL shouldBuild = !*attempted;
	if (shouldBuild) { *attempted = YES; *building = YES; }
	[lock unlock];
	return shouldBuild;
}

/// Publishes a build's result (under the lock) and wakes the waiters.
static void TSSTFinishBuild(NSCondition *lock, BOOL *building, void (^publish)(void))
{
	[lock lock];
	publish();
	*building = NO;
	[lock broadcast];
	[lock unlock];
}

/// Lazily builds (or rebuilds, e.g. after the managed object was re-fetched
/// and the ivar reset) the fast zip index for this archive's fileURL. Returns
/// nil for non-zips, unreadable files, or zip features this class can't
/// fully handle -- callers should fall back to -instance / XADArchive.
/// Thread-safe: background page reads may call this off-main while the
/// window's main thread also reads pages. The build runs outside the lock
/// (see TSSTBeginBuild).
- (nullable TSSTZipIndex *)zipIndex
{
	if (TSSTBeginBuild(_zipIndexLock, &_zipIndexAttempted, &_zipIndexBuilding))
	{
		TSSTCachingByteSource *cachingSource = nil;
		TSSTZipIndex *built = [TSSTManagedArchive buildZipIndexForFileURL: self.fileURL cachingSource: &cachingSource];
		TSSTFinishBuild(_zipIndexLock, &_zipIndexBuilding, ^{
			if (built && !self->_zipIndex)
			{
				self->_zipIndex = built;
				[self adoptCachingSource: cachingSource];
			}
			else
			{
				[cachingSource invalidate];
			}
		});
	}
	[_zipIndexLock lock];
	TSSTZipIndex *result = _zipIndex;
	[_zipIndexLock unlock];
	return result;
}

- (nullable NSString *)nameOfEntryAtIndex:(NSInteger)index
{
	TSSTZipIndex *zi = self.zipIndex;
	if (zi && index >= 0 && (NSUInteger)index < zi.numberOfEntries)
	{
		return [zi nameOfEntry: (NSUInteger)index];
	}
	return [(XADArchive *)self.instance nameOfEntry: index];
}

/// Starts a background prefetcher over \c zi's extractable entries, in
/// the same order pages are displayed in (TSSTSortDescriptor's
/// comparison on imagePath). Only called when a caching byte source was
/// built for this archive (see +buildZipIndexForFileURL:cachingSource:).
- (void)startStreamerForZipIndex:(TSSTZipIndex *)zi
{
	NSMutableArray<NSNumber *> *extractable = [NSMutableArray array];
	for (NSUInteger i = 0; i < zi.numberOfEntries; ++i)
	{
		if ([zi canExtractEntry: i]) { [extractable addObject: @(i)]; }
	}

	const NSStringCompareOptions comparisonOptions = NSCaseInsensitiveSearch | NSNumericSearch | NSWidthInsensitiveSearch | NSForcedOrderingSearch;
	NSArray<NSNumber *> *sorted = [extractable sortedArrayUsingComparator: ^NSComparisonResult(NSNumber *a, NSNumber *b) {
		NSString *nameA = [zi nameOfEntry: a.unsignedIntegerValue];
		NSString *nameB = [zi nameOfEntry: b.unsignedIntegerValue];
		return [nameA compare: nameB options: comparisonOptions];
	}];

	NSArray<NSValue *> *spans = [TSSTArchiveStreamer spansForZipIndex: zi entryIndices: sorted];
	NSMutableDictionary<NSNumber *, NSNumber *> *map = [NSMutableDictionary dictionaryWithCapacity: sorted.count];
	for (NSUInteger i = 0; i < sorted.count; ++i)
	{
		map[sorted[i]] = @(i);
	}
	[self startStreamerWithSpans: spans entryIndexMap: map];
}

/// The one place a streamer is built. \c map takes an entry index to its
/// span index (see -noteReadingEntryIndex:). Replaces any running streamer.
- (void)startStreamerWithSpans:(NSArray<NSValue *> *)spans entryIndexMap:(nullable NSDictionary<NSNumber *, NSNumber *> *)map
{
	[_streamer cancel];
	_entryIndexToSpanIndex = map;
	_streamer = [[TSSTArchiveStreamer alloc] initWithCachingByteSource: _cachingSource spans: spans];
	// Lets the timeline bar redraw as spans land in the cache.
	__weak typeof(self) weakSelf = self;
	_streamer.progressHandler = ^(NSIndexSet *cachedSpanIndexes, double cachedFraction, double throughputBytesPerSecond, BOOL isComplete) {
		TSSTManagedArchive *strongSelf = weakSelf;
		if (strongSelf)
		{
			[[NSNotificationCenter defaultCenter] postNotificationName: TSSTArchiveCacheProgressNotification object: strongSelf];
		}
	};
	[_streamer start];
}

#if DEBUG
- (nullable TSSTArchiveStreamer *)streamer
{
	return _streamer;
}
#endif

/// Retargets the streamer at the page the reader is on. Called only from
/// the session's display path (-changeViewImages), never from the byte-read
/// path: hover thumbnails, pre-decoding and the exposé all read pages the
/// reader is not on, and each such read would drag the streamer's target
/// away from the reader's own neighbourhood.
- (void)noteReadingEntryIndex:(NSInteger)entryIndex
{
	NSNumber *spanIndex = _entryIndexToSpanIndex[@(entryIndex)];
	if (spanIndex) { _streamer.currentSpanIndex = spanIndex.unsignedIntegerValue; }
}

- (void)prioritizeEntryIndex:(NSInteger)entryIndex
{
	NSNumber *spanIndex = _entryIndexToSpanIndex[@(entryIndex)];
	if (spanIndex) { [_streamer prioritizeSpanIndex: spanIndex.unsignedIntegerValue]; }
}

- (BOOL)isStreamingArchive
{
	return _cachingSource != nil;
}

- (BOOL)isEntryIndexCached:(NSInteger)entryIndex
{
	if (!_cachingSource || !_streamer)
	{
		// No streaming cache -- local file, reads are already fast.
		return YES;
	}
	NSNumber *spanIndex = _entryIndexToSpanIndex[@(entryIndex)];
	if (!spanIndex)
	{
		// Not a span we know about (out of range, or non-zip fallback):
		// treat conservatively as not-cached.
		return NO;
	}
	NSArray<NSValue *> *spans = _streamer.spans;
	NSUInteger idx = spanIndex.unsignedIntegerValue;
	if (idx >= spans.count) { return NO; }
	NSRange span = spans[idx].rangeValue;
	return [_cachingSource isRangeCachedAtOffset: span.location length: span.length];
}

- (void)didTurnIntoFault
{
	[super didTurnIntoFault];
	[_streamer cancel];
	[_cachingSource invalidate];
	_streamer = nil;
	_cachingSource = nil;
	_zipIndex = nil;
	_zipIndexAttempted = NO;
}


- (void)requestDataForPageIndex:(NSInteger)index completionHandler:(void(^)(NSData *_Nullable pageData, NSError *_Nullable error))callback
{
	NSString * solidDirectory = self.solidDirectory;
	NSData * imageData;
	// Zip archives are never solid, so if we have a fast zip index for this
	// archive we can read straight from it -- pread() is safe for
	// concurrent callers, so no groupLock is needed on this path.
	TSSTZipIndex *zi = solidDirectory ? nil : self.zipIndex;
	if (zi && index >= 0 && (NSUInteger)index < zi.numberOfEntries && [zi canExtractEntry: (NSUInteger)index])
	{
		NSError *err;
		imageData = [zi contentsOfEntry: (NSUInteger)index error: &err];
		callback(imageData, err);
		return;
	}
	if(!solidDirectory)
	{
		[groupLock lock];
		NSError *err;
		imageData = [[self instance] contentsOfEntry: index error: &err];
		[groupLock unlock];
		callback(imageData, err);
	}
	else
	{
		NSString * name = [[self instance] nameOfEntry: index];
		NSString * fileName = [NSString stringWithFormat:@"%li.%@", (long)index, [name pathExtension]];
		fileName = [solidDirectory stringByAppendingPathComponent: fileName];
		if(![[NSFileManager defaultManager] fileExistsAtPath: fileName])
		{
			[groupLock lock];
			NSError *err;
			imageData = [[self instance] contentsOfEntry: index error: &err];
			[groupLock unlock];
			[imageData writeToFile: fileName options: 0 error: nil];
			callback(imageData, err);
		}
		else
		{
			NSError *err = nil;
			imageData = [NSData dataWithContentsOfFile: fileName options:0 error:&err];
			callback(imageData, err);
			return;
		}
	}
}


- (NSManagedObject *)topLevelGroup
{
	NSManagedObject * group = self;
	NSManagedObject * parentGroup = group;
	
	while(group)
	{
		group = [group valueForKeyPath: @"group"];
		parentGroup = group && [group isMemberOfClass:[TSSTManagedArchive class]] ? group : parentGroup;
	}
	
	return parentGroup;
}

/// Background-safe: builds the backend and scans entries for the archive at
/// \c fileURL, returning a value-only record tree. Never touches an
/// \c NSManagedObject / the MOC, so it can run on any queue. Recurses into
/// nested archives/PDFs (writing their bytes to temp files exactly as
/// before) and returns their own fully-built records as children.
+ (nullable TSSTArchiveScanRecord *)scanRecordForFileURL:(NSURL *)fileURL name:(nullable NSString *)name password:(nullable NSString *)password errors:(NSMutableArray<NSError *> *)errors
{
	// Try the fast zip-index path first: it only needs one pread() of the
	// central directory instead of XADArchive walking every local header
	// (slow on high-latency volumes like SMB).
	TSSTCachingByteSource *cachingSource = nil;
	TSSTZipIndex *zi = [self scannableZipIndexForFileURL: fileURL cachingSource: &cachingSource];
	return [self scanRecordForFileURL: fileURL name: name password: password zipIndex: zi cachingSource: cachingSource errors: errors];
}

/// The scan proper. \c zi (with its cache, if any) is an already-built index
/// that can extract everything the scan needs, or nil to list through
/// XADArchive (non-zips, solid archives, zips the index can't fully read).
+ (nullable TSSTArchiveScanRecord *)scanRecordForFileURL:(NSURL *)fileURL name:(nullable NSString *)name password:(nullable NSString *)password zipIndex:(nullable TSSTZipIndex *)zi cachingSource:(nullable TSSTCachingByteSource *)cachingSource errors:(NSMutableArray<NSError *> *)errors
{
	TSSTArchiveScanRecord *record = [TSSTArchiveScanRecord new];
	record.name = name ?: fileURL.lastPathComponent;

	const BOOL zipIndexUsable = (zi != nil);
	XADArchive *imageArchive = nil;
	TSSTScanArchiveDelegate *passwordDelegate = nil;
	if (!zipIndexUsable)
	{
		passwordDelegate = [TSSTScanArchiveDelegate new];
		passwordDelegate.path = fileURL.path;
		passwordDelegate.password = password;
		[fileURL startAccessingSecurityScopedResource];
		imageArchive = [[XADArchive alloc] initWithFileURL: fileURL delegate: passwordDelegate error: NULL];
		if (imageArchive && passwordDelegate.password)
		{
			[imageArchive setPassword: passwordDelegate.password];
		}
	}

	record.builtInstance = zipIndexUsable ? zi : imageArchive;
	record.builtCachingSource = zipIndexUsable ? cachingSource : nil;
	record.password = passwordDelegate.password;
	record.backendDescription = zipIndexUsable ? @"zip-index" : @"XAD";

	const NSInteger archivedFilesCount = zipIndexUsable ? (NSInteger)zi.numberOfEntries : [imageArchive numberOfEntries];
	if (!zipIndexUsable && [imageArchive isSolid])
	{
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSInteger collision = 0;
		NSString *archivePath = nil;
		NSError *error = nil;
		do {
			archivePath = [NSString stringWithFormat: @"SC-images-%li", (long)collision];
			archivePath = [NSTemporaryDirectory() stringByAppendingPathComponent: archivePath];
			++collision;
		} while (![fileManager createDirectoryAtPath: archivePath withIntermediateDirectories: YES attributes: nil error: &error]);
		record.solidDirectory = archivePath;
	}

	NSMutableArray<TSSTArchiveScanRecord *> *children = [NSMutableArray arrayWithCapacity: archivedFilesCount];

	for (NSInteger counter = 0; counter < archivedFilesCount; ++counter)
	{
		NSString *fileName = zipIndexUsable ? [zi nameOfEntry: (NSUInteger)counter] : [imageArchive nameOfEntry: counter];
		TSSTArchiveScanRecord *child = nil;

		switch (TSSTClassifyScanEntryName(fileName))
		{
			case TSSTScanEntryClassImage:
				child = TSSTImageChildRecord(fileName, counter, NO);
				break;
			case TSSTScanEntryClassText:
				child = TSSTImageChildRecord(fileName, counter, YES);
				break;
			case TSSTScanEntryClassArchive:
			{
				NSData *fileData = zipIndexUsable ? [zi contentsOfEntry: (NSUInteger)counter error: NULL] : [imageArchive contentsOfEntry: counter];
				child = TSSTNestedArchiveChildRecord(fileData, fileName, errors);
				break;
			}
			case TSSTScanEntryClassPDF:
			{
				NSData *fileData = zipIndexUsable ? [zi contentsOfEntry: (NSUInteger)counter error: NULL] : [imageArchive contentsOfEntry: counter];
				child = TSSTPDFChildRecord(fileData, fileName);
				break;
			}
			case TSSTScanEntryClassIgnored:
				break;
		}
		if (child) { [children addObject: child]; }
	}

	record.children = children;
	return record;
}

/// Main-thread only: walks a record produced by
/// +scanRecordForFileURL:name:password:errors: and inserts the corresponding
/// Core Data entities, reusing the already-built backend (no re-parsing).
- (void)applyScanRecord:(id)recordObject
{
	TSSTArchiveScanRecord *record = (TSSTArchiveScanRecord *)recordObject;
	if (!record)
	{
		return;
	}

	if ([record.builtInstance isKindOfClass: [TSSTZipIndex class]])
	{
		_zipIndex = record.builtInstance;
		_zipIndexAttempted = YES;
		[self adoptCachingSource: record.builtCachingSource];
		if (_cachingSource)
		{
			[self startStreamerForZipIndex: _zipIndex];
		}
	}
	else if (record.builtInstance)
	{
		instance = record.builtInstance;
	}

	if (record.password)
	{
		self.password = record.password;
	}
	if (record.solidDirectory)
	{
		self.solidDirectory = record.solidDirectory;
	}

	for (TSSTArchiveScanRecord *child in record.children)
	{
		TSSTManagedGroup *nestedDescription = nil;
		switch (child.kind)
		{
			case TSSTArchiveScanRecordKindImage:
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"Image" inManagedObjectContext: [self managedObjectContext]];
				[nestedDescription setValue: child.imagePath forKey: @"imagePath"];
				[nestedDescription setValue: @(child.index) forKey: @"index"];
				if (child.text)
				{
					[nestedDescription setValue: @YES forKey: @"text"];
				}
				break;
			case TSSTArchiveScanRecordKindArchive:
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"Archive" inManagedObjectContext: [self managedObjectContext]];
				nestedDescription.name = child.name;
				nestedDescription.nested = YES;
				nestedDescription.path = child.path;
				[(TSSTManagedArchive *)nestedDescription applyScanRecord: child];
				break;
			case TSSTArchiveScanRecordKindPDF:
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"PDF" inManagedObjectContext: [self managedObjectContext]];
				nestedDescription.path = child.path;
				nestedDescription.nested = YES;
				nestedDescription.name = child.name;
				[(TSSTManagedPDF *)nestedDescription applyPDFScanRecord: child];
				break;
		}

		if (nestedDescription)
		{
			nestedDescription.group = self;
		}
	}
}

- (void)nestedArchiveContents
{
	[TSSTManagedGroup batchURLErrorsForGroupName: self.name ?: self.fileURL.lastPathComponent during: ^(NSMutableArray<NSError *> *errors) {
		[self applyScanRecord: [TSSTManagedArchive scanRecordForFileURL: self.fileURL name: self.name password: self.password errors: errors]];
	}];
}


- (BOOL)quicklookCompatible
{	
	NSString * extension = [[self.name pathExtension] lowercaseString];
	return [TSSTManagedArchive.quicklookExtensions containsObject: extension];
}


/* Delegates */

/**  Called when Simple Comic encounters a password protected
 archive.  Brings a password dialog forward. */
- (void)archiveNeedsPassword:(XADArchive *)archive
{
	NSString * password = self.password;
	
	if(password)
	{
		archive.password = password;
		return;
	}
	
	password = [(SimpleComicAppDelegate*)[NSApp delegate] passwordForArchiveWithPath: self.path];
	archive.password = password;
	
	self.password = password;
}

@end


@implementation TSSTManagedPDF

- (id)instance
{
	if (!instance)
	{
		NSURL *aURL = self.fileURL;
		[aURL startAccessingSecurityScopedResource];
		instance = [[PDFDocument alloc] initWithURL: aURL];
	}
	
	return instance;
}

- (void)requestDataForPageIndex:(NSInteger)index completionHandler:(void(^)(NSData *_Nullable pageData, NSError *_Nullable error))callback
{
	[groupLock lock];
	PDFPage * page = [(PDFDocument*)[self instance] pageAtIndex: index];
	[groupLock unlock];
	
	NSRect bounds = [page boundsForBox: kPDFDisplayBoxMediaBox];
	CGFloat dimension = 1400;
	CGFloat scale = 1 > (NSHeight(bounds) / NSWidth(bounds)) ? dimension / NSWidth(bounds) :  dimension / NSHeight(bounds);
	bounds.size = scaleSize(bounds.size, scale);
	if (NSEqualRects(bounds, NSZeroRect)) {
		// Prevent zero size exception for images
		bounds.size = NSMakeSize(50, 50);
	}
	if (isinf(scale) || scale == 0) {
		scale = 1;
	}
	
	NSImage * pageImage = [[NSImage alloc] initWithSize: bounds.size];
	[pageImage lockFocus];
		[[NSColor whiteColor] set];
		NSRectFill(bounds);
		NSAffineTransform * scaleTransform = [NSAffineTransform transform];
		[scaleTransform scaleBy: scale];
		[scaleTransform concat];
		[page drawWithBox: kPDFDisplayBoxMediaBox toContext:[[NSGraphicsContext currentContext] CGContext]];
	[pageImage unlockFocus];
	
	NSData * imageData = [pageImage TIFFRepresentation];
	
	callback(imageData, nil);
}

- (void)pdfContents
{
	PDFDocument * rep = [self instance];
	[self insertImagesForPageCount: rep.pageCount];
}

/// Main-thread only: shared by -pdfContents (top-level/synchronous PDFs) and
/// -applyPDFScanRecord: (PDFs found nested inside a background-scanned
/// archive) -- inserts one Image entity per page.
- (void)insertImagesForPageCount:(NSInteger)imageCount
{
	TSSTPage * imageDescription;
	NSMutableSet<TSSTPage*> * pageSet = [NSMutableSet set];
	for (NSInteger pageNumber = 0; pageNumber < imageCount; ++pageNumber)
	{
		imageDescription = [NSEntityDescription insertNewObjectForEntityForName: @"Image" inManagedObjectContext: [self managedObjectContext]];
		imageDescription.imagePath = [NSString stringWithFormat: NSLocalizedString(@"PDF page %li", @"PDF page number"), (long)(pageNumber + 1)];
		imageDescription.index = @(pageNumber);
		[pageSet addObject: imageDescription];
	}
	self.images = pageSet;
}

/// Main-thread only: applies a TSSTArchiveScanRecord (kind PDF) built by
/// +[TSSTManagedArchive scanRecordForFileURL:...] for a PDF found nested
/// inside an archive during a background scan. Reuses the already-built
/// PDFDocument instead of re-parsing it.
- (void)applyPDFScanRecord:(id)recordObject
{
	TSSTArchiveScanRecord *record = (TSSTArchiveScanRecord *)recordObject;
	if (record.builtInstance)
	{
		instance = record.builtInstance;
	}
	[self insertImagesForPageCount: record.pdfPageCount];
}

@end
