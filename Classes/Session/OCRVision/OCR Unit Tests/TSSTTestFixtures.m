//
//  TSSTTestFixtures.m
//  OCR Unit Tests
//

#import "TSSTTestFixtures.h"
#import "TSSTZipIndex.h"

@implementation TSSTTestFixtures

+ (nullable NSURL *)fixtureNamed:(NSString *)name
{
	NSBundle *bundle = [NSBundle bundleForClass: self];
	return [bundle URLForResource: name withExtension: nil]
		?: [bundle URLForResource: name withExtension: nil subdirectory: @"rarzoo"];
}

+ (NSString *)scratchDirectory
{
	static NSString *directory;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		directory = [NSTemporaryDirectory() stringByAppendingPathComponent: [NSString stringWithFormat: @"TSSTTestFixtures-%d", getpid()]];
		[[NSFileManager defaultManager] createDirectoryAtPath: directory withIntermediateDirectories: YES attributes: nil error: NULL];
		static char cleanupPath[PATH_MAX];
		strlcpy(cleanupPath, directory.fileSystemRepresentation, sizeof cleanupPath);
		atexit_b(^{ [[NSFileManager defaultManager] removeItemAtPath: [NSString stringWithUTF8String: cleanupPath] error: NULL]; });
	});
	return directory;
}

+ (nullable NSURL *)jessieJamesCBZ
{
	static NSURL *extracted;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSURL *outer = [self fixtureNamed: @"Public-Domain-Comic-Jessie-James.cbz.zip"];
		if (!outer) { return; }
		TSSTZipIndex *index = [TSSTZipIndex indexWithFileURL: outer error: NULL];
		for (NSUInteger i = 0; index && i < index.numberOfEntries; ++i)
		{
			if (![[index nameOfEntry: i].pathExtension.lowercaseString isEqualToString: @"cbz"]) { continue; }
			NSData *data = [index contentsOfEntry: i error: NULL];
			NSString *path = [[self scratchDirectory] stringByAppendingPathComponent: @"Jessie-James.cbz"];
			if (data && [data writeToFile: path atomically: YES]) { extracted = [NSURL fileURLWithPath: path]; }
			break;
		}
	});
	return extracted;
}

+ (nullable NSArray<NSString *> *)extractJessieJamesPagesInto:(NSString *)directory count:(NSUInteger)count
{
	NSURL *cbz = [self jessieJamesCBZ];
	TSSTZipIndex *index = cbz ? [TSSTZipIndex indexWithFileURL: cbz error: NULL] : nil;
	if (!index) { return nil; }
	[[NSFileManager defaultManager] createDirectoryAtPath: directory withIntermediateDirectories: YES attributes: nil error: NULL];

	NSMutableArray<NSNumber *> *images = [NSMutableArray array];
	for (NSUInteger i = 0; i < index.numberOfEntries; ++i)
	{
		if ([[index nameOfEntry: i].pathExtension.lowercaseString isEqualToString: @"jpg"]) { [images addObject: @(i)]; }
	}
	[images sortUsingComparator: ^NSComparisonResult(NSNumber *a, NSNumber *b) {
		return [[index nameOfEntry: a.unsignedIntegerValue] compare: [index nameOfEntry: b.unsignedIntegerValue] options: NSNumericSearch];
	}];

	NSMutableArray<NSString *> *names = [NSMutableArray array];
	for (NSNumber *entry in images)
	{
		if (names.count >= count) { break; }
		NSString *name = [index nameOfEntry: entry.unsignedIntegerValue].lastPathComponent;
		NSData *data = [index contentsOfEntry: entry.unsignedIntegerValue error: NULL];
		if (!data || ![data writeToFile: [directory stringByAppendingPathComponent: name] atomically: YES]) { return nil; }
		[names addObject: name];
	}
	return names;
}

+ (nullable NSString *)sevenZipPath
{
	NSString *path = @"/opt/homebrew/bin/7zz";
	return [[NSFileManager defaultManager] isExecutableFileAtPath: path] ? path : nil;
}

+ (BOOL)runTool:(NSString *)path arguments:(NSArray<NSString *> *)arguments inDirectory:(NSString *)directory
{
	NSTask *task = [[NSTask alloc] init];
	task.launchPath = path;
	task.arguments = arguments;
	task.currentDirectoryPath = directory;
	task.standardOutput = [NSPipe pipe];
	task.standardError = [NSPipe pipe];
	[task launch];
	[task waitUntilExit];
	return task.terminationStatus == 0;
}

@end
