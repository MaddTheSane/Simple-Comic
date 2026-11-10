//
//  TSSTInitialWindowSizeTests.m
//  A new session opened from an archive gets its pages asynchronously (the scan
//  and decode run off the main thread), so the window is created before any
//  page exists. The initial zoom must wait for the first page, or the window is
//  sized to the 400x228 minimum and, with "Automatically resize windows" off,
//  never corrected (MaddTheSane/Simple-Comic#183).
//
//  The window is never ordered on screen and nothing here can raise an alert.
//

#import <XCTest/XCTest.h>
#import "SimpleComicAppDelegate.h"
#import "TSSTManagedSession.h"
#import "TSSTSessionWindowController.h"
#import "TSSTTestFixtures.h"

@interface TSSTInitialWindowSizeTests : XCTestCase
@property (nonatomic, strong) SimpleComicAppDelegate *delegate;
@property (nonatomic, strong) TSSTManagedSession *session;
@property (nonatomic, strong) TSSTSessionWindowController *controller;
@property (nonatomic, strong, nullable) id savedAutoResize;
@end

@implementation TSSTInitialWindowSizeTests

- (void)setUp
{
	[super setUp];
	self.delegate = (SimpleComicAppDelegate *)NSApp.delegate;
	XCTAssertTrue([self.delegate isKindOfClass: SimpleComicAppDelegate.class], @"tests must run hosted in Simple Comic");
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	self.savedAutoResize = [defaults objectForKey: TSSTWindowAutoResize];
	[defaults setBool: NO forKey: TSSTWindowAutoResize];
}

- (void)tearDown
{
	[self.controller.window orderOut: nil];
	// Let the neighbor-page predecode kicked off by the first display finish
	// before its pages are deleted out from under it.
	[[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.5]];
	self.controller = nil;
	if (self.session) {
		[self.delegate.managedObjectContext deleteObject: self.session];
		self.session = nil;
	}
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	if (self.savedAutoResize) {
		[defaults setObject: self.savedAutoResize forKey: TSSTWindowAutoResize];
	} else {
		[defaults removeObjectForKey: TSSTWindowAutoResize];
	}
	[super tearDown];
}

// With auto-resize off, nothing re-fits the window after the first page lands,
// so the initial zoom has to happen once that page is on the page view.
- (void)testNewSessionFromArchiveIsSizedToItsFirstPage
{
	NSURL *cbz = [TSSTTestFixtures jessieJamesCBZ];
	TSSTRequireBundled(cbz != nil, @"Jessie James fixture missing");

	self.session = [self.delegate newSessionWithFileURLs: @[cbz]];
	self.session.scaleOptions = 2; // fit width, as in the report
	self.controller = [[TSSTSessionWindowController alloc] initWithSession: self.session];
	NSWindow *window = self.controller.window; // loads the nib; the window is not shown
	XCTAssertEqual(self.session.images.count, 0u, @"the archive scan must still be in flight when the window loads");
	NSSize minSize = window.minSize;

	// The title is set when the first page is displayed.
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: 30];
	while ([window.title isEqualToString: @"Window"] && deadline.timeIntervalSinceNow > 0) {
		[[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.05]];
	}
	XCTAssertFalse([window.title isEqualToString: @"Window"], @"first page was never displayed");

	NSSize size = window.frame.size;
	XCTAssertGreaterThan(size.width, minSize.width + 100, @"window stayed at the minimum width: %@", NSStringFromSize(size));
	XCTAssertGreaterThan(size.height, minSize.height + 100, @"window stayed at the minimum height: %@", NSStringFromSize(size));
}

@end
