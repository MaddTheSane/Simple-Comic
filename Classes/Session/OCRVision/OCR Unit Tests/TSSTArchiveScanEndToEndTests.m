//
//  TSSTArchiveScanEndToEndTests.m
//  Drives the real -[SimpleComicAppDelegate addFileURLs:toSession:] path (the
//  one File > Open uses) with bundled cb7zoo fixtures: the session must report
//  "loading" from the moment the scan is queued until its pages land.
//
//  No windows are created and nothing here can raise an alert: only a session
//  and its archive groups are inserted into the app's (test-redirected) store,
//  and they are deleted again in -tearDown.
//

#import <XCTest/XCTest.h>
#import "SimpleComicAppDelegate.h"
#import "TSSTManagedSession.h"

@interface TSSTArchiveScanEndToEndTests : XCTestCase
@property (nonatomic, strong) SimpleComicAppDelegate *delegate;
@property (nonatomic, strong) TSSTManagedSession *session;
@end

@implementation TSSTArchiveScanEndToEndTests

- (void)setUp
{
	[super setUp];
	self.delegate = (SimpleComicAppDelegate *)NSApp.delegate;
	XCTAssertTrue([self.delegate isKindOfClass: SimpleComicAppDelegate.class], @"tests must run hosted in Simple Comic");
	self.session = [NSEntityDescription insertNewObjectForEntityForName: @"Session" inManagedObjectContext: self.delegate.managedObjectContext];
}

- (void)tearDown
{
	// Any scan still in flight sees the deleted session and discards its result.
	[self.delegate.managedObjectContext deleteObject: self.session];
	self.session = nil;
	[super tearDown];
}

- (NSURL *)fixture:(NSString *)name
{
	NSURL *url = [[NSBundle bundleForClass: self.class] URLForResource: name.stringByDeletingPathExtension
														 withExtension: name.pathExtension
														  subdirectory: @"cb7zoo"];
	XCTAssertNotNil(url, @"%@ is not in the test bundle", name);
	return url;
}

/// Fails unless the session stops loading, with nothing left pending, within the timeout.
- (void)waitForLoadingToEnd
{
	XCTKVOExpectation *done = [[XCTKVOExpectation alloc] initWithKeyPath: @"loading" object: self.session expectedValue: @NO];
	[self waitForExpectations: @[done] timeout: 30];
	XCTAssertFalse(self.session.loading);
	XCTAssertEqual(self.session.pendingScanCount, 0u);
}

// Loading is YES as soon as the add returns (the scan runs off the main
// thread), then the pages arrive and loading ends with the count balanced.
- (void)testArchiveScanKeepsSessionLoadingUntilPagesArrive
{
	[self.delegate addFileURLs: @[[self fixture: @"jj-4pages.cb7"]] toSession: self.session];
	XCTAssertTrue(self.session.loading, @"loading must be set before addFileURLs:toSession: returns");
	XCTAssertEqual(self.session.pendingScanCount, 1u);
	XCTAssertEqual(self.session.images.count, 0u, @"pages must not appear before the scan lands");

	[self waitForLoadingToEnd];
	XCTAssertEqual(self.session.images.count, 4u);
}

// A truncated or empty archive must still end the loading state (no hang, no
// leaked pending count), whatever pages it manages to yield.
- (void)testBrokenArchivesStillEndLoading
{
	for (NSString *name in @[@"jj-truncated.cb7", @"jj-empty.cb7"]) {
		[self.delegate addFileURLs: @[[self fixture: name]] toSession: self.session];
		XCTAssertTrue(self.session.loading, @"%@", name);
		[self waitForLoadingToEnd];
	}
}

// Two archives added back to back: loading must not end until both have
// landed, so the window never reports "done" with only the first one's pages.
- (void)testBackToBackArchivesStayLoadingUntilBothLand
{
	[self.delegate addFileURLs: @[[self fixture: @"jj-4pages.cb7"]] toSession: self.session];
	[self.delegate addFileURLs: @[[self fixture: @"jj-solid.cb7"]] toSession: self.session];
	XCTAssertTrue(self.session.loading);
	XCTAssertEqual(self.session.pendingScanCount, 2u);

	[self waitForLoadingToEnd];
	XCTAssertEqual(self.session.images.count, 8u, @"both archives' pages must be present when loading ends");
}

@end
