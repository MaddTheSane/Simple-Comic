//
//  DTPolishedProgressBarTests.m
//  OCR Unit Tests
//
//  The timeline bar shows loaded vs unloaded pages only (position is the
//  marker alone). Renders the real view and samples pixels.
//

#import <XCTest/XCTest.h>

@interface DTPolishedProgressBarTests : XCTestCase
@end

@implementation DTPolishedProgressBarTests

static const CGFloat kWidth = 200;

/// Renders the bar (10 pages, 200 pt wide) and returns the colour of the
/// bar row at the centre of `page`.
- (NSColor *)barColorAtPage:(NSInteger)page
                    current:(NSInteger)current
                     loaded:(NSIndexSet *)loaded
                 leftToRight:(BOOL)ltr
{
	// The Swift class isn't visible through a header in this target, so it
	// is looked up by its module-qualified name and driven through KVC.
	Class cls = NSClassFromString(@"Simple_Comic.DTPolishedProgressBar");
	XCTAssertNotNil(cls);
	NSView *bar = [[cls alloc] initWithFrame:NSMakeRect(0, 0, kWidth, 20)];
	[bar setValue:@10 forKey:@"maxValue"];
	[bar setValue:@(current) forKey:@"currentValue"];
	[bar setValue:@(ltr) forKey:@"leftToRight"];
	[bar setValue:loaded forKey:@"bufferedIndexes"];
	NSBitmapImageRep *rep = [bar bitmapImageRepForCachingDisplayInRect:bar.bounds];
	__block NSColor *result = nil;
	NSAppearance *appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	[appearance performAsCurrentDrawingAppearance:^{
		[bar cacheDisplayInRect:bar.bounds toBitmapImageRep:rep];
		CGFloat x = ltr ? (page + 0.5) * kWidth / 10 : kWidth - (page + 0.5) * kWidth / 10;
		// Two points down from the top is inside the 5 pt bar; the marker (2 pt wide)
		// is avoided by callers keeping `current` off the sampled page.
		CGFloat scale = (CGFloat)rep.pixelsWide / kWidth; // the bitmap is backing-scale sized
		result = [[rep colorAtX:(NSInteger)(x * scale) y:(NSInteger)(2 * scale)] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
	}];
	return result;
}

- (BOOL)color:(NSColor *)a isCloseTo:(NSColor *)b
{
	return fabs(a.redComponent - b.redComponent) < 0.02 && fabs(a.greenComponent - b.greenComponent) < 0.02 && fabs(a.blueComponent - b.blueComponent) < 0.02;
}

- (void)testLoadedAndUnloadedPagesDrawDifferently
{
	NSIndexSet *loaded = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(5, 5)];
	NSColor *unloaded = [self barColorAtPage:1 current:9 loaded:loaded leftToRight:YES];
	NSColor *loadedColor = [self barColorAtPage:6 current:9 loaded:loaded leftToRight:YES];
	XCTAssertFalse([self color:unloaded isCloseTo:loadedColor], @"loaded and unloaded pages must be visibly different");
}

- (void)testPositionDoesNotChangeTheFill
{
	// Loaded state behind and ahead of the marker draws the same colour.
	NSIndexSet *loaded = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 10)];
	NSColor *behind = [self barColorAtPage:1 current:5 loaded:loaded leftToRight:YES];
	NSColor *ahead = [self barColorAtPage:8 current:5 loaded:loaded leftToRight:YES];
	XCTAssertTrue([self color:behind isCloseTo:ahead], @"cached pages behind the marker must look like cached pages ahead");
}

- (void)testJumpingBackKeepsUnloadedGapUnloaded
{
	NSIndexSet *loaded = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(3, 7)];
	NSColor *gap = [self barColorAtPage:1 current:2 loaded:loaded leftToRight:YES];
	NSColor *cached = [self barColorAtPage:8 current:2 loaded:loaded leftToRight:YES];
	XCTAssertFalse([self color:gap isCloseTo:cached]);
}

- (void)testNothingStreamingCountsEverythingAsLoaded
{
	NSIndexSet *all = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 10)];
	NSColor *local = [self barColorAtPage:8 current:2 loaded:[NSIndexSet indexSet] leftToRight:YES];
	NSColor *loadedColor = [self barColorAtPage:8 current:2 loaded:all leftToRight:YES];
	XCTAssertTrue([self color:local isCloseTo:loadedColor], @"a local file (no streamer) must show a solid bar");
}

- (void)testRightToLeftMirrorsTheLoadedRuns
{
	NSIndexSet *loaded = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(5, 5)];
	NSColor *unloaded = [self barColorAtPage:1 current:9 loaded:loaded leftToRight:NO];
	NSColor *loadedColor = [self barColorAtPage:6 current:0 loaded:loaded leftToRight:NO];
	XCTAssertFalse([self color:unloaded isCloseTo:loadedColor]);
}

@end
