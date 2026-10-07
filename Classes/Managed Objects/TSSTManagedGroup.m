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

@interface TSSTManagedArchive () <XADArchiveDelegate>
-(void)archiveNeedsPassword:(XADArchive *)archive;

@end

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

- (void)nestedArchiveContents
{
	[TSSTManagedGroup beginURLErrorBatchForGroupName: self.name ?: self.fileURL.lastPathComponent];
	XADArchive * imageArchive = self.instance;
	
	NSFileManager * fileManager = [NSFileManager defaultManager];
	NSData * fileData;
	NSInteger collision = 0;
	NSString * archivePath = nil;
	const NSInteger archivedFilesCount = [imageArchive numberOfEntries];
	NSError * error;
	if([imageArchive isSolid])
	{
		do {
			archivePath = [NSString stringWithFormat: @"SC-images-%li", (long)collision];
			archivePath = [NSTemporaryDirectory() stringByAppendingPathComponent: archivePath];
			++collision;
		} while (![fileManager createDirectoryAtPath: archivePath withIntermediateDirectories: YES attributes: nil error: &error]);
		self.solidDirectory = archivePath;
	}
	
	for (NSInteger counter = 0; counter < archivedFilesCount; ++counter)
	{
		NSString *fileName = [imageArchive nameOfEntry: counter];
		TSSTManagedGroup *nestedDescription = nil;
		
		if(!([fileName isEqualToString: @""] || [[[fileName lastPathComponent] substringToIndex: 1] isEqualToString: @"."]))
		{
			NSString *extension = [[fileName pathExtension] lowercaseString];
			if([[TSSTPage imageExtensions] containsObject: extension])
			{
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"Image" inManagedObjectContext: [self managedObjectContext]];
				[nestedDescription setValue: fileName forKey: @"imagePath"];
				[nestedDescription setValue: @(counter) forKey: @"index"];
			}
			else if([[TSSTManagedArchive archiveExtensions] containsObject: extension])
			{
				fileData = [imageArchive contentsOfEntry: counter];
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"Archive" inManagedObjectContext: [self managedObjectContext]];
				nestedDescription.name = fileName;
				nestedDescription.nested = YES;
				
				collision = 0;
				do {
					archivePath = [NSString stringWithFormat: @"%li-%@", (long)collision, fileName];
					archivePath = [NSTemporaryDirectory() stringByAppendingPathComponent: archivePath];
					++collision;
				} while ([fileManager fileExistsAtPath: archivePath]);
				
				[[NSFileManager defaultManager] createDirectoryAtPath: [archivePath stringByDeletingLastPathComponent]
										  withIntermediateDirectories: YES
														   attributes: nil
																error: NULL];
				[[NSFileManager defaultManager] createFileAtPath: archivePath contents: fileData attributes: nil];
				
				nestedDescription.path = archivePath;
				[(TSSTManagedArchive *)nestedDescription nestedArchiveContents];
			}
			else if([[TSSTPage textExtensions] containsObject: extension])
			{
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"Image" inManagedObjectContext: [self managedObjectContext]];
				[nestedDescription setValue: fileName forKey: @"imagePath"];
				[nestedDescription setValue: @(counter) forKey: @"index"];
				[nestedDescription setValue: @YES forKey: @"text"];
			}
			else if([extension isEqualToString: @"pdf"])
			{
				NSString *fullFileName = fileName;
				fileName = [fileName lastPathComponent];
				nestedDescription = [NSEntityDescription insertNewObjectForEntityForName: @"PDF" inManagedObjectContext: [self managedObjectContext]];
				archivePath = [NSTemporaryDirectory() stringByAppendingPathComponent: fileName];
				NSInteger collision = 0;
				while([fileManager fileExistsAtPath: archivePath])
				{
					++collision;
					fileName = [NSString stringWithFormat: @"%li-%@", (long)collision, fileName];
					archivePath = [NSTemporaryDirectory() stringByAppendingPathComponent: fileName];
				}
				fileData = [imageArchive contentsOfEntry: counter];
				[fileData writeToFile: archivePath atomically: YES];
				
				nestedDescription.path = archivePath;
				nestedDescription.nested = YES;
				nestedDescription.name = fullFileName;
				[(TSSTManagedPDF *)nestedDescription pdfContents];
			}
			
			if(nestedDescription)
			{
				nestedDescription.group = self;
			}
		}
	}
	[TSSTManagedGroup endURLErrorBatch];
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
	TSSTPage * imageDescription;
	NSMutableSet<TSSTPage*> * pageSet = [NSMutableSet set];
	NSInteger imageCount = [rep pageCount];
	for (NSInteger pageNumber = 0; pageNumber < imageCount; ++pageNumber)
	{
		imageDescription = [NSEntityDescription insertNewObjectForEntityForName: @"Image" inManagedObjectContext: [self managedObjectContext]];
		imageDescription.imagePath = [NSString stringWithFormat: NSLocalizedString(@"PDF page %li", @"PDF page number"), (long)(pageNumber + 1)];
		imageDescription.index = @(pageNumber);
		[pageSet addObject: imageDescription];
	}
	self.images = pageSet;
}

@end
