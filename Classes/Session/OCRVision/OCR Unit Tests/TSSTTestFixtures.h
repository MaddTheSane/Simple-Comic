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

@end

/// Declares `NSURL *var` for the bundled fixture \c name. A missing fixture
/// FAILS the test (it means the bundle is mis-configured) and returns from it.
/// Use inside a test method, before touching the fixture.
#define TSSTRequireFixture(var, name) \
	NSURL *var = [TSSTTestFixtures fixtureNamed: (name)]; \
	XCTAssertNotNil(var, @"fixture %@ is missing from the test bundle", (name)); \
	if (var == nil) { return; }

NS_ASSUME_NONNULL_END
