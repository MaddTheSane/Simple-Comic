//
//  TSSTThumbnailViewTests.m
//  Covers the exposé thumbnail loop: cancelling it when the window closes, and
//  running it with no window (the view's window is gone by the time queued
//  main-thread updates run).
//

#import <XCTest/XCTest.h>
#import "TSSTSessionWindowController.h"

/// A data source that records every thumbnail request, and can hold the first
/// one so a test can act while the loop is provably in flight.
@interface TSSTStubThumbnailSource : TSSTSessionWindowController
@property (atomic) NSInteger requestCount;
@property (nonatomic, strong) dispatch_semaphore_t firstRequestStarted;
@property (nonatomic, strong, nullable) dispatch_semaphore_t holdFirstRequest;
@end

@implementation TSSTStubThumbnailSource
- (NSImage *)imageForPageAtIndex:(NSInteger)index
{
	if (self.requestCount++ == 0 && self.holdFirstRequest) {
		dispatch_semaphore_signal(self.firstRequestStarted);
		dispatch_semaphore_wait(self.holdFirstRequest, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
	}
	return [[NSImage alloc] initWithSize: NSMakeSize(1, 1)];
}
@end

@interface TSSTThumbnailViewTests : XCTestCase
/// The view only holds its page controller weakly (it's a nib outlet).
@property (nonatomic, strong) NSArrayController *pages;
@end

@implementation TSSTThumbnailViewTests

/// Builds a thumbnail view with `pageCount` pages and the stub as its data source.
- (NSView *)thumbnailViewWithPageCount:(NSUInteger)pageCount source:(TSSTStubThumbnailSource *)source
{
	// The class name is module-qualified because the view is written in Swift.
	Class viewClass = NSClassFromString(@"Simple_Comic.TSSTThumbnailView") ?: NSClassFromString(@"TSSTThumbnailView");
	XCTAssertNotNil(viewClass, @"TSSTThumbnailView class not found");
	NSView *view = [[viewClass alloc] initWithFrame: NSMakeRect(0, 0, 100, 100)];
	self.pages = [[NSArrayController alloc] initWithContent: nil];
	NSMutableArray *content = [NSMutableArray array];
	for (NSUInteger i = 0; i < pageCount; i++) {
		[content addObject: @(i)];
	}
	self.pages.content = content;
	[view setValue: self.pages forKey: @"pageController"];
	[view setValue: source forKey: @"dataSource"];
	return view;
}

/// The stub is created without a session, which -dealloc of the real controller
/// can't tolerate (it removes observers that awakeFromNib would have added),
/// so tests deliberately keep it alive for the life of the process.
- (TSSTStubThumbnailSource *)immortalStubSource
{
	TSSTStubThumbnailSource *source = [[TSSTStubThumbnailSource alloc] initWithSession: nil];
	source.firstRequestStarted = dispatch_semaphore_create(0);
	CFBridgingRetain(source);
	return source;
}

/// Runs -processThumbs off the main thread, as the app does, and returns an
/// expectation fulfilled when the pass has finished.
- (XCTestExpectation *)runProcessThumbsOn:(NSView *)view
{
	XCTestExpectation *finished = [self expectationWithDescription: @"processThumbs returned"];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		[view performSelector: NSSelectorFromString(@"processThumbs")];
		[finished fulfill];
	});
	return finished;
}

// Cancelling while the loop is mid-pass must stop it before the next page; an
// uncancelled pass would request all ten.
- (void)testCancelThumbnailProcessingStopsAnInFlightPass
{
	TSSTStubThumbnailSource *source = [self immortalStubSource];
	source.holdFirstRequest = dispatch_semaphore_create(0);
	NSView *view = [self thumbnailViewWithPageCount: 10 source: source];

	[self runProcessThumbsOn: view];
	XCTAssertEqual(dispatch_semaphore_wait(source.firstRequestStarted, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0,
				   @"the loop never requested the first thumbnail");

	[view performSelector: NSSelectorFromString(@"cancelThumbnailProcessing")];
	dispatch_semaphore_signal(source.holdFirstRequest);
	[self waitForExpectationsWithTimeout: 10 handler: nil];

	XCTAssertEqual(source.requestCount, 1, @"the loop kept running after cancellation");
}

// The periodic redraw request used to force-unwrap the view's window, trapping
// once the window had closed (or when the view was never in one).
- (void)testProcessThumbsWithNoWindowDoesNotTrap
{
	TSSTStubThumbnailSource *source = [self immortalStubSource];
	NSView *view = [self thumbnailViewWithPageCount: 6 source: source];
	XCTAssertNil(view.window);

	[self runProcessThumbsOn: view];
	[self waitForExpectationsWithTimeout: 10 handler: nil];

	XCTAssertEqual(source.requestCount, 6, @"every page should be processed");
}

@end
