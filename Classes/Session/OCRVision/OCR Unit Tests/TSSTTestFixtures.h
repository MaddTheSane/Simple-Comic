//
//  TSSTTestFixtures.h
//  OCR Unit Tests
//
//  Locates test fixture files relative to this source file, so committed
//  tests never depend on a machine-specific directory. Fixtures live in
//  Fixtures/ (RAR structure variants in Fixtures/rarzoo/).
//  SC_FIXTURES_DIR (pass as TEST_RUNNER_SC_FIXTURES_DIR) points at a copy of
//  that layout, for runs where the sandboxed test host can't read the
//  checkout (e.g. it lives under ~/Documents). Every accessor returns nil
//  when a fixture is unreadable, so callers skip instead of failing.
//

#import <Foundation/Foundation.h>
#import <XCTest/XCTest.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSSTTestFixtures : NSObject

/// SC_FIXTURES_DIR if set, else the Fixtures folder next to this file.
+ (NSURL *)fixturesDirectory;

/// A fixture by file name in Fixtures/ (else Fixtures/rarzoo/), nil if absent or unreadable.
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

/// Declares `NSURL *var` for the fixture \c name, or SKIPS the test when the
/// file cannot be read. Use inside a test method, before touching the fixture.
#define TSSTRequireFixture(var, name) \
	NSURL *var = [TSSTTestFixtures fixtureNamed: (name)]; \
	XCTSkipUnless(var != nil, @"fixture %@ is not readable by the test host (set TEST_RUNNER_SC_FIXTURES_DIR to a copy of the fixtures)", (name))

NS_ASSUME_NONNULL_END
