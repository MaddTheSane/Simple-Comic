//
//  TSSTTestFixtures.h
//  OCR Unit Tests
//
//  Locates test fixture files in the test bundle (Copy Bundle Resources), so
//  committed tests never depend on a machine-specific directory. Fixtures live
//  in Fixtures/ (RAR structure variants in Fixtures/rarzoo/).
//

#import <Foundation/Foundation.h>
#import <XCTest/XCTest.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSSTTestFixtures : NSObject

/// A bundled fixture by file name (loose in Fixtures/, else in Fixtures/rarzoo/), nil if absent.
+ (nullable NSURL *)fixtureNamed:(NSString *)name;

/// The inner 36-JPEG .cbz, extracted once per process from the review zip.
+ (nullable NSURL *)jessieJamesCBZ;

/// Extracts the first \c count pages (in name order) of the cbz into a
/// fresh directory under \c parent and returns their names in that order.
/// Returns nil if the cbz is missing or extraction fails.
+ (nullable NSArray<NSString *> *)extractJessieJamesPagesInto:(NSString *)directory count:(NSUInteger)count;

/// Path of the Homebrew 7zz tool, nil if not installed.
+ (nullable NSString *)sevenZipPath;

/// Runs a tool synchronously; YES when it exits 0.
+ (BOOL)runTool:(NSString *)path arguments:(NSArray<NSString *> *)arguments inDirectory:(NSString *)directory;

@end

/// FAILS the test and returns from it unless \c condition holds. For bundled
/// fixtures, whose absence means the bundle is mis-configured, not "skip".
#define TSSTRequireBundled(condition, ...) \
	do { XCTAssertTrue((condition), __VA_ARGS__); if (!(condition)) { return; } } while (0)

/// Declares `NSURL *var` for the bundled fixture \c name, failing the test if
/// it is missing. Use inside a test method, before touching the fixture.
#define TSSTRequireFixture(var, name) \
	NSURL *var = [TSSTTestFixtures fixtureNamed: (name)]; \
	TSSTRequireBundled(var != nil, @"fixture %@ is missing from the test bundle", (name))

NS_ASSUME_NONNULL_END
