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
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import "TSSTImageUtilities.h"
#import "TSSTPage.h"
#import "TSSTPage+CoreDataProperties.h"

@interface TSSTManagedArchive () <XADArchiveDelegate>
-(void)archiveNeedsPassword:(XADArchive *)archive;

@end

@interface TSSTManagedPDF ()
/// Main-thread only: applies a PDF-kind record built while scanning an
/// enclosing archive, reusing its already-built PDFDocument instead of re-parsing.
- (void)applyPDFScanRecord:(TSSTArchiveScanRecord *)record;
@end

// Kinds of children a scan can produce: one per entity type -applyScanRecord: inserts.
typedef NS_ENUM(NSInteger, TSSTArchiveScanRecordKind)
{
	TSSTArchiveScanRecordKindImage,
	TSSTArchiveScanRecordKindArchive,
	TSSTArchiveScanRecordKindPDF,
};

/*
 * Plain value object describing one archive's worth of scanned entries (the
 * public face, `children`, is declared in the header).
 * Built entirely off values (no NSManagedObject / MOC access) so it can be
 * produced on a background queue; a matching -applyScanRecord: on the main
 * thread walks it and inserts the actual Core Data entities.
 */
@interface TSSTArchiveScanRecord ()

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
@property (nonatomic, strong, nullable) id builtInstance; // XADArchive or PDFDocument, pre-built, ready to reuse
@property (nonatomic, strong, readwrite, nullable) NSArray<TSSTArchiveScanRecord *> *children;

// PDF kind:
@property (nonatomic) NSInteger pdfPageCount;

@end

@implementation TSSTArchiveScanRecord
@end

/// Runs \c block on the main thread: inline when already there, otherwise
/// synchronously if \c wait, else asynchronously.
static void TSSTRunOnMainThread(BOOL wait, dispatch_block_t block)
{
	if (NSThread.isMainThread) { block(); }
	else if (wait) { dispatch_sync(dispatch_get_main_queue(), block); }
	else { dispatch_async(dispatch_get_main_queue(), block); }
}

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
	TSSTRunOnMainThread(YES, ^{
		promptedPassword = [(SimpleComicAppDelegate*)[NSApp delegate] passwordForArchiveWithPath: path];
	});

	archive.password = promptedPassword;
	self.password = promptedPassword;
}

@end

typedef NS_ENUM(NSInteger, TSSTScanEntryClass)
{
	TSSTScanEntryClassIgnored,
	TSSTScanEntryClassImage,
	TSSTScanEntryClassText,
	TSSTScanEntryClassArchive,
	TSSTScanEntryClassPDF,
};

/// What a scan does with an archive entry of this name (empty and dot-prefixed names are skipped).
static TSSTScanEntryClass TSSTClassifyScanEntryName(NSString *fileName)
{
	if (fileName.length == 0 || [fileName.lastPathComponent hasPrefix: @"."]) { return TSSTScanEntryClassIgnored; }
	static NSDictionary<NSString *, NSNumber *> *classByExtension;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		// Later additions win, so images take precedence over archives over text.
		NSMutableDictionary<NSString *, NSNumber *> *classes = [NSMutableDictionary dictionaryWithObject: @(TSSTScanEntryClassPDF) forKey: @"pdf"];
		for (NSString *extension in TSSTPage.textExtensions) { classes[extension] = @(TSSTScanEntryClassText); }
		for (NSString *extension in TSSTManagedArchive.archiveExtensions) { classes[extension] = @(TSSTScanEntryClassArchive); }
		for (NSString *extension in TSSTPage.imageExtensions) { classes[extension] = @(TSSTScanEntryClassImage); }
		classByExtension = [classes copy];
	});
	return (TSSTScanEntryClass)classByExtension[fileName.pathExtension.lowercaseString].integerValue;
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

/// Creates (and returns the path of) the first item in the temp directory,
/// trying \c candidateName(0), (1), ... in turn, that did not exist yet: a
/// directory if \c isDirectory, otherwise an empty file (with any missing
/// parent folders). Creating it is what claims the name, so scans running on
/// different threads can never be handed the same path.
NSString *TSSTCreateUnusedTempPath(BOOL isDirectory, NSString *(^candidateName)(NSInteger attempt))
{
	for (NSInteger attempt = 0; ; ++attempt)
	{
		NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent: candidateName(attempt)];
		int result;
		if (isDirectory)
		{
			result = mkdir(path.fileSystemRepresentation, 0755);
		}
		else
		{
			// Candidate names may contain folders.
			[[NSFileManager defaultManager] createDirectoryAtPath: path.stringByDeletingLastPathComponent
									  withIntermediateDirectories: YES attributes: nil error: NULL];
			result = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0644);
			if (result >= 0) { close(result); result = 0; }
		}
		// Only "already exists" means try the next name; for any other error
		// hand back the path and let the caller's write report the problem.
		if (result == 0 || errno != EEXIST) { return path; }
	}
}

/// Extracts a nested archive to a temp file ("<n>-<fileName>") and scans it,
/// returning its own record as an archive child.
static TSSTArchiveScanRecord *TSSTNestedArchiveChildRecord(NSData *fileData, NSString *fileName)
{
	NSString *archivePath = TSSTCreateUnusedTempPath(NO, ^NSString *(NSInteger n) {
		return [NSString stringWithFormat: @"%li-%@", (long)n, fileName];
	});
	[fileData writeToFile: archivePath atomically: NO];

	TSSTArchiveScanRecord *nestedRecord = [TSSTManagedArchive scanRecordForFileURL: [NSURL fileURLWithPath: archivePath] name: fileName password: nil];
	nestedRecord.kind = TSSTArchiveScanRecordKindArchive;
	nestedRecord.path = archivePath;
	return nestedRecord;
}

/// Writes a nested PDF's bytes to the temp directory (under its base name,
/// "<n>-" prefixed until unused) and returns its record, PDFDocument built.
static TSSTArchiveScanRecord *TSSTPDFChildRecord(NSData *fileData, NSString *fileName)
{
	NSString *baseName = fileName.lastPathComponent;
	NSString *pdfPath = TSSTCreateUnusedTempPath(NO, ^NSString *(NSInteger n) {
		return n == 0 ? baseName : [NSString stringWithFormat: @"%li-%@", (long)n, baseName];
	});
	[fileData writeToFile: pdfPath atomically: NO];

	TSSTArchiveScanRecord *child = [TSSTArchiveScanRecord new];
	child.kind = TSSTArchiveScanRecordKindPDF;
	child.path = pdfPath;
	child.name = fileName;
	PDFDocument *pdfDoc = [[PDFDocument alloc] initWithURL: [NSURL fileURLWithPath: pdfPath]];
	child.builtInstance = pdfDoc;
	child.pdfPageCount = pdfDoc.pageCount;
	return child;
}

/*
 * Batching of per-file URL errors. setFileURL:/fileURL report failures through
 * +reportURLError:, which queues them while a recursive scan
 * (nestedFolderContents/nestedArchiveContents) is running and presents a single
 * summary alert from +endURLErrorBatch once the whole top-level scan finishes.
 * Outside a scan (depth 0) the error is presented immediately.
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
	return [NSString localizedStringWithFormat: NSLocalizedString(@"%lu files in \"%@\" could not be opened.", @"unreadable files summary"), (unsigned long)errorCount, groupName];
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
	TSSTRunOnMainThread(NO, present);
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

+ (void)batchURLErrorsForGroupName:(NSString *)groupName during:(dispatch_block_t)during
{
	[self beginURLErrorBatchForGroupName: groupName];
	during();
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
					   @"org.7-zip.7-zip-archive",
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

- (void)willTurnIntoFault
{
	NSError * error;
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

- (void)requestDataForPageIndex:(NSInteger)index completionHandler:(void(^)(NSData *_Nullable pageData, NSError *_Nullable error))callback
{
	NSString * solidDirectory = self.solidDirectory;
	NSData * imageData;
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

/// Background-safe: opens the archive at \c fileURL and scans its entries,
/// returning a value-only record tree. Never touches an \c NSManagedObject /
/// the MOC, so it can run on any queue. Recurses into nested archives/PDFs
/// (writing their bytes to temp files) and returns their records as children.
+ (nullable TSSTArchiveScanRecord *)scanRecordForFileURL:(NSURL *)fileURL name:(nullable NSString *)name password:(nullable NSString *)password
{
	TSSTArchiveScanRecord *record = [TSSTArchiveScanRecord new];
	record.name = name ?: fileURL.lastPathComponent;

	TSSTScanArchiveDelegate *passwordDelegate = [TSSTScanArchiveDelegate new];
	passwordDelegate.path = fileURL.path;
	passwordDelegate.password = password;
	[fileURL startAccessingSecurityScopedResource];
	XADArchive *imageArchive = [[XADArchive alloc] initWithFileURL: fileURL delegate: passwordDelegate error: NULL];
	if (imageArchive && passwordDelegate.password)
	{
		[imageArchive setPassword: passwordDelegate.password];
	}

	record.builtInstance = imageArchive;
	record.password = passwordDelegate.password;

	const NSInteger archivedFilesCount = [imageArchive numberOfEntries];
	if ([imageArchive isSolid])
	{
		NSString *solidPath = TSSTCreateUnusedTempPath(YES, ^NSString *(NSInteger n) {
			return [NSString stringWithFormat: @"SC-images-%li", (long)n];
		});
		record.solidDirectory = solidPath;
	}

	NSMutableArray<TSSTArchiveScanRecord *> *children = [NSMutableArray arrayWithCapacity: archivedFilesCount];

	for (NSInteger counter = 0; counter < archivedFilesCount; ++counter)
	{
		NSString *fileName = [imageArchive nameOfEntry: counter];
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
				NSData *fileData = [imageArchive contentsOfEntry: counter];
				child = TSSTNestedArchiveChildRecord(fileData, fileName);
				break;
			}
			case TSSTScanEntryClassPDF:
			{
				NSData *fileData = [imageArchive contentsOfEntry: counter];
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

+ (void)discardScanRecord:(TSSTArchiveScanRecord *)record
{
	NSFileManager *fileManager = [NSFileManager defaultManager];
	// Image children have neither; only top-level and nested archives have a
	// solid directory, only nested archives/PDFs a temp file.
	if (record.solidDirectory) { [fileManager removeItemAtPath: record.solidDirectory error: NULL]; }
	if (record.path) { [fileManager removeItemAtPath: record.path error: NULL]; }
	for (TSSTArchiveScanRecord *child in record.children)
	{
		[self discardScanRecord: child];
	}
}

/// Main-thread only: walks a record produced by
/// +scanRecordForFileURL:name:password: and inserts the corresponding
/// Core Data entities, reusing the already-built backend (no re-parsing).
- (void)applyScanRecord:(TSSTArchiveScanRecord *)record
{
	if (!record)
	{
		return;
	}

	if (record.builtInstance)
	{
		instance = record.builtInstance;
		// The scan's own delegate is gone by now (XADArchive holds it weakly).
		[instance setDelegate: self];
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
		__kindof TSSTManagedGroup *nestedDescription = nil;
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
				[nestedDescription applyScanRecord: child];
				break;
			case TSSTArchiveScanRecordKindPDF:
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"PDF" inManagedObjectContext: [self managedObjectContext]];
				nestedDescription.path = child.path;
				nestedDescription.nested = YES;
				nestedDescription.name = child.name;
				[nestedDescription applyPDFScanRecord: child];
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
	[TSSTManagedGroup batchURLErrorsForGroupName: self.name ?: self.fileURL.lastPathComponent during: ^{
		[self applyScanRecord: [TSSTManagedArchive scanRecordForFileURL: self.fileURL name: self.name password: self.password]];
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
- (void)applyPDFScanRecord:(TSSTArchiveScanRecord *)record
{
	if (record.builtInstance)
	{
		instance = record.builtInstance;
	}
	[self insertImagesForPageCount: record.pdfPageCount];
}

@end
