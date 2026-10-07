//
//  TSSTTestFixtures.m
//  OCR Unit Tests
//

#import "TSSTTestFixtures.h"

@implementation TSSTTestFixtures

+ (nullable NSURL *)overrideDirectory
{
	const char *value = getenv("SC_FIXTURES_DIR");
	return (value && *value) ? [NSURL fileURLWithPath: [NSString stringWithUTF8String: value] isDirectory: YES] : nil;
}

+ (NSURL *)sourceFixturesDirectory
{
	NSURL *thisFile = [NSURL fileURLWithPath: [NSString stringWithUTF8String: __FILE__]];
	return [[thisFile URLByDeletingLastPathComponent] URLByAppendingPathComponent: @"Fixtures" isDirectory: YES];
}

+ (NSURL *)fixturesDirectory
{
	return [self overrideDirectory] ?: [self sourceFixturesDirectory];
}

/// The URL if its first byte can actually be read. A hosted test run is
/// sandboxed and can be denied the checkout's folder (macOS "Documents"
/// protection) even though the file exists, in which case the fixture is
/// treated as missing and the test skips; SC_FIXTURES_DIR points at a copy.
+ (nullable NSURL *)existingURL:(NSURL *)url
{
	FILE *file = fopen(url.fileSystemRepresentation, "r");
	if (!file) { return nil; }
	int byte = fgetc(file);
	BOOL failed = (byte == EOF && ferror(file));
	fclose(file);
	return failed ? nil : url;
}

/// Fixtures/<name>, else Fixtures/rarzoo/<name> (SC_FIXTURES_DIR mirrors that layout).
+ (nullable NSURL *)fixtureNamed:(NSString *)name
{
	NSURL *directory = [self fixturesDirectory];
	return [self existingURL: [directory URLByAppendingPathComponent: name]]
		?: [self existingURL: [[directory URLByAppendingPathComponent: @"rarzoo" isDirectory: YES] URLByAppendingPathComponent: name]];
}

@end
