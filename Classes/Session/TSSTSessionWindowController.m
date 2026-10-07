/*
	Copyright (c) 2006-2009 Dancing Tortoise Software
	Created by Alexander Rauchfuss

	Permission is hereby granted, free of charge, to any person
	obtaining a copy of this software and associated documentation
	files (the "Software"), to deal in the Software without
	restriction, including without limitation the rights to use,
	copy, modify, merge, publish, distribute, sublicense, and/or
	sell copies of the Software, and to permit persons to whom the
	Software is furnished to do so, subject to the following
	conditions:

	The above copyright notice and this permission notice shall be
	included in all copies or substantial portions of the Software.

	TSSTSessionWindowController.m
*/

#import <stdatomic.h>
#import <XADMaster/XADArchive.h>
#import "UKXattrMetadataStore.h"
#import "SimpleComicAppDelegate.h"
#import "TSSTSessionWindowController.h"
#import "TSSTPageView.h"
#import "TSSTSortDescriptor.h"
#import "TSSTImageUtilities.h"
#import "TSSTPage.h"
#import "TSSTManagedGroup.h"
#import "TSSTManagedSession.h"
#import "OCRFind.h"
#import "TSSTEdgeBlurRenderer.h"
#import "TSSTPageDecodeCache.h"
#import "OCRFindViewController.h"
#import "OCRTracker.h"
#import "OCRVision.h"
#import "GeneratedAssetSymbols.h"

#import "Simple_Comic-Swift.h"

NSString * const TSSTMouseDragNotification = @"SCMouseDragNotification";



@interface TSSTSessionWindowController()<OCRFindDelegate, OCRTrackerDelegate>
@property(nonatomic, readonly) OCRFind *find;
@property OCRVision *ocrVision API_AVAILABLE(macos(10.15));
@end

@implementation TSSTSessionWindowController
{
	/** The session object used to maintain settings */
	TSSTManagedSession * session;
	
	/** This var is bound to the session window name */
	NSInteger pageTurn;
	
	/** Exactly what it sounds like */
	NSArray<TSSTSortDescriptor*> *pageSortDescriptor;
	
	/** Manages the cursor hiding while in fullscreen */
	NSTimer *mouseMovedTimer;

	BOOL newSession;
	
	PageSelectionMode pageSelectionInProgress;
	CGFloat savedZoom;

	/** "Loading..." overlay shown over pageScrollView while a background
	    archive scan hasn't produced any pages yet. Built in code, not the
	    xib, and lazily added/removed. */
	NSView *loadingOverlayView;
	NSProgressIndicator *loadingSpinner;
	NSTextField *loadingLabel;

	/** The page object auto-pinned to selection while a background scan
	    (RAR/7z progressive listing) is still delivering pages
	    in batches. Reading order isn't discovery order, so a later batch
	    can insert a page that now sorts before it; re-pin to the new
	    page 1 only while the user hasn't navigated away from the one we
	    pinned. nil once the scan finishes or the user moves selection. */
	id autoPinnedPageDuringScan;

	/** Bumped on every -changeViewImages call; an async page load compares
	    its captured value against the current one before applying its
	    result, so a stale load (superseded by a later selection change)
	    never clobbers what's on screen. */
	_Atomic NSUInteger displayGeneration; // read off-main by the decode queue's staleness check
	/** Set to `displayGeneration`'s value at the top of
	    -finishDisplayForIndex:..., i.e. the generation that's actually on
	    screen right now. Distinct from displayGeneration itself so the
	    delayed HUD-show timer can tell "selection moved on" (generation
	    changed) apart from "this generation already finished displaying,
	    including possibly by a wait that resolved in under 150ms" (this
	    generation was already displayed) -- either should suppress it. */
	NSUInteger displayedGeneration;

	/** Small HUD ("Loading page N...") shown over the page view when a
	    page has to be fetched over the network and hasn't arrived within
	    ~150ms. Built in code, like loadingOverlayView. */
	NSView *pageLoadHUDView;
	NSProgressIndicator *pageLoadSpinner;
	NSTextField *pageLoadLabel;

	/** Coalesces TSSTArchiveCacheProgressNotification bursts into at most
	    one -refreshBufferedIndexes call per ~250ms. */
	BOOL bufferedIndexesRefreshScheduled;
}

@synthesize pageTurn, pageSortDescriptor;
@synthesize find = _find;
@synthesize pageController;
@synthesize pageView;
@synthesize pageScrollView;
@synthesize jumpPanel;
@synthesize jumpField;
@synthesize progressBar;
@synthesize infoWindow;
@synthesize infoPicture;
@synthesize loupeWindow;
@synthesize zoomView;
@synthesize exposeBezel;
@synthesize exposeView;
@synthesize thumbnailPanel;

- (instancetype)initWithSession:(TSSTManagedSession *)aSession
{
	self = [super init];
	if (self != nil)
	{
		pageTurn = 0;
		pageSelectionInProgress = PageSelectionModeNone;
		mouseMovedTimer = nil;
		session = aSession;
		BOOL cascade = session.position ? NO : YES;
		[self setShouldCascadeWindows: cascade];
		/* Make sure that the session does not start out in fullscreen, nor with the loupe enabled. */
		session.loupe = NO;
		/* Images are sorted by group and then image name. */
		TSSTSortDescriptor * fileNameSort = [[TSSTSortDescriptor alloc] initWithKey: @"imagePath" ascending: YES];
		TSSTSortDescriptor * archivePathSort = [[TSSTSortDescriptor alloc] initWithKey: @"group.path" ascending: YES];
		self.pageSortDescriptor = @[archivePathSort, fileNameSort];
	}
	
	return self;
}


- (NSString *)windowNibName
{
	return @"TSSTSessionWindow";
}


- (void)windowDidLoad
{
	if ([[NSUserDefaults standardUserDefaults] boolForKey: TSSTUnifiedTitlebar]) {
		[super windowDidLoad];
		self.window.titleVisibility = NSWindowTitleHidden;
	} else {
		[super windowDidLoad];
	}
	
	// Set up the toolbar, because Apple decided it hates Interface Builder for toolbars.
	NSToolbar *newToolbar = [[NSToolbar alloc] initWithIdentifier:@"1A96E21F-07EA-4D3B-B356-508A45D1FCBB"];
	
	newToolbar.delegate = self;
	newToolbar.allowsUserCustomization = YES;
	newToolbar.autosavesConfiguration = YES;
	newToolbar.displayMode = NSToolbarDisplayModeIconOnly;
	
	self.window.toolbar = newToolbar;
	[self.window.toolbar validateVisibleItems];
}


/*  Sets up all of the observers and bindings. */
- (void)awakeFromNib
{
	[super awakeFromNib];
	/* This needs to be set as the window subclass that the expose window
	 uses has mouse events turned off by default */
	[exposeBezel setIgnoresMouseEvents: NO];
	[exposeBezel setFloatingPanel: YES];
	[exposeBezel setWindowController: self];
	[[self window] setAcceptsMouseMovedEvents: YES];
	[pageController setSelectionIndex: session.selection];
	
	NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
	
	[defaults addObserver: self forKeyPath: TSSTConstrainScale options: 0 context: nil];
	[defaults addObserver: self forKeyPath: TSSTStatusbarVisible options: 0 context: nil];
	[defaults addObserver: self forKeyPath: TSSTScrollersVisible options: 0 context: nil];
	[defaults addObserver: self forKeyPath: TSSTBackgroundColor options: 0 context: nil];
	[defaults addObserver: self forKeyPath: TSSTBackgroundMode options: 0 context: nil];
	[defaults addObserver: self forKeyPath: TSSTLoupeDiameter options: 0 context: nil];
	[defaults addObserver: self forKeyPath: TSSTLoupePower options: 0 context: nil];
	[defaults addObserver: self forKeyPath: TSSTUnifiedTitlebar options: 0 context: nil];
	[session addObserver: self forKeyPath: TSSTPageOrder options: 0 context: nil];
	[session addObserver: self forKeyPath: TSSTPageScaleOptions options: 0 context: nil];
	[session addObserver: self forKeyPath: TSSTTwoPageSpread options: 0 context: nil];
	[session addObserver: self forKeyPath: @"loupe" options: 0 context: nil];
	[session addObserver: self forKeyPath: @"loading" options: 0 context: nil];
	
	[session bind: @"selection" toObject: pageController withKeyPath: @"selectionIndex" options: nil];
	
	[pageScrollView setPostsFrameChangedNotifications: YES];
	[[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(resizeView) name: NSViewFrameDidChangeNotification object: pageScrollView];
	[pageController addObserver: self forKeyPath: @"selectionIndex" options: 0 context: nil];
	[pageController addObserver: self forKeyPath: @"arrangedObjects.@count" options: 0 context: nil];
	
	[progressBar addObserver: self forKeyPath: @"currentValue" options: 0 context: nil];
	[progressBar bind: @"currentValue" toObject: pageController withKeyPath: @"selectionIndex" options: nil];
	[progressBar bind: @"maxValue" toObject: pageController withKeyPath: @"arrangedObjects.@count" options: nil];
	[progressBar bind: @"leftToRight" toObject: session withKeyPath: TSSTPageOrder options: nil];
	
	[pageView bind: TSSTViewRotation toObject: session withKeyPath: TSSTViewRotation options: nil];
	_tracker = [[OCRTracker alloc] initWithView:pageView];
	_tracker.delegate = self;

	NSTrackingArea * newArea = [[NSTrackingArea alloc] initWithRect: [progressBar progressRect]
															options: NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingActiveInActiveApp
															  owner: self
														   userInfo: @{@"purpose": @"normalProgress"}];
	[progressBar addTrackingArea: newArea];
	[jumpField setDelegate: self];
	
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleMouseDragged:) name:TSSTMouseDragNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleArchiveCacheProgress:) name:TSSTArchiveCacheProgressNotification object:nil];

	[self updateLoadingOverlay];
	[self restoreSession];
}


#pragma mark - Buffered band

- (void)handleArchiveCacheProgress:(NSNotification *)notification
{
	[self scheduleBufferedIndexesRefresh];
}

/// Coalesces bursts of progress notifications (the streamer already
/// throttles to ~4Hz, but a session can have more than one streaming
/// archive) into at most one recompute per ~250ms.
- (void)scheduleBufferedIndexesRefresh
{
	if (bufferedIndexesRefreshScheduled)
	{
		return;
	}
	bufferedIndexesRefreshScheduled = YES;
	__weak typeof(self) weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		typeof(self) strongSelf = weakSelf;
		if (!strongSelf)
		{
			return;
		}
		strongSelf->bufferedIndexesRefreshScheduled = NO;
		[strongSelf refreshBufferedIndexes];
	});
}

/// Recomputes the progress bar's buffered band from arrangedObjects. Hides
/// the band entirely (empty set) unless at least one archive backing a
/// page in this session actually streams (non-local volume, or
/// SC_SIMULATE_LINK) -- a purely local session leaves every
/// -isEntryIndexCached: answer YES, which would otherwise show a
/// misleadingly full band.
- (void)refreshBufferedIndexes
{
	NSArray<TSSTPage *> * pages = [pageController arrangedObjects];
	NSMutableIndexSet * cached = [NSMutableIndexSet indexSet];
	BOOL anyStreaming = NO;

	for (NSUInteger i = 0; i < pages.count; ++i)
	{
		TSSTManagedGroup * group = pages[i].group;
		if (![group isKindOfClass: [TSSTManagedGroup class]])
		{
			continue;
		}
		TSSTManagedGroup * archive = (TSSTManagedGroup *)group;
		if (!archive.isStreamingArchive)
		{
			continue;
		}
		anyStreaming = YES;
		NSNumber * pageIndex = pages[i].index;
		if (pageIndex && [archive isEntryIndexCached: pageIndex.integerValue])
		{
			[cached addIndex: i];
		}
	}

	progressBar.bufferedIndexes = anyStreaming ? cached : [NSIndexSet indexSet];
}




#pragma mark - Loading overlay

/**
 Shows/hides a centered "Loading..." label + indeterminate spinner over
 pageScrollView, depending on whether the session is still being scanned
 in the background and has no pages yet.
 */
- (void)updateLoadingOverlay
{
	BOOL shouldShow = session.isLoading && [[pageController arrangedObjects] count] == 0;

	if (!shouldShow)
	{
		[loadingSpinner stopAnimation: nil];
		[loadingOverlayView removeFromSuperview];
		loadingOverlayView = nil;
		loadingSpinner = nil;
		loadingLabel = nil;
		return;
	}

	if (loadingOverlayView)
	{
		return;
	}

	NSView *container = pageScrollView.superview ?: pageScrollView;

	loadingOverlayView = [[NSView alloc] initWithFrame: pageScrollView.frame];
	loadingOverlayView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	loadingOverlayView.translatesAutoresizingMaskIntoConstraints = YES;

	loadingSpinner = [[NSProgressIndicator alloc] initWithFrame: NSMakeRect(0, 0, 32, 32)];
	loadingSpinner.style = NSProgressIndicatorStyleSpinning;
	loadingSpinner.indeterminate = YES;
	[loadingSpinner startAnimation: nil];

	loadingLabel = [[NSTextField alloc] initWithFrame: NSMakeRect(0, 0, 240, 20)];
	loadingLabel.editable = NO;
	loadingLabel.bordered = NO;
	loadingLabel.drawsBackground = NO;
	loadingLabel.alignment = NSTextAlignmentCenter;
	loadingLabel.stringValue = NSLocalizedString(@"Loading…", @"loading overlay message shown while a background archive scan is in progress");

	[loadingOverlayView addSubview: loadingSpinner];
	[loadingOverlayView addSubview: loadingLabel];

	NSRect bounds = loadingOverlayView.bounds;
	loadingSpinner.frameOrigin = NSMakePoint(NSMidX(bounds) - NSWidth(loadingSpinner.frame) / 2.0,
											  NSMidY(bounds) - NSHeight(loadingSpinner.frame) / 2.0 + 16);
	loadingLabel.frameOrigin = NSMakePoint(NSMidX(bounds) - NSWidth(loadingLabel.frame) / 2.0,
											NSMidY(bounds) - NSHeight(loadingLabel.frame) / 2.0 - 16);
	loadingSpinner.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
	loadingLabel.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;

	[container addSubview: loadingOverlayView positioned: NSWindowAbove relativeTo: pageScrollView];
}


- (void)dealloc
{
	[(TSSTThumbnailView *)exposeView setDataSource: nil];
	NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
	
	[defaults removeObserver: self forKeyPath: TSSTStatusbarVisible];
	[defaults removeObserver: self forKeyPath: TSSTScrollersVisible];
	[defaults removeObserver: self forKeyPath: TSSTBackgroundColor];
	[defaults removeObserver: self forKeyPath: TSSTBackgroundMode];
	[defaults removeObserver: self forKeyPath: TSSTConstrainScale];
	[defaults removeObserver: self forKeyPath: TSSTLoupeDiameter];
	[defaults removeObserver: self forKeyPath: TSSTLoupePower];
	[defaults removeObserver: self forKeyPath: TSSTUnifiedTitlebar];
	[pageController removeObserver: self forKeyPath: @"selectionIndex"];
	[pageController removeObserver: self forKeyPath: @"arrangedObjects.@count"];
	[session removeObserver: self forKeyPath: @"loading"];
	[[NSNotificationCenter defaultCenter] removeObserver: self];
	
	[progressBar removeObserver: self forKeyPath: @"currentValue"];
	[progressBar unbind: @"currentValue"];
	[progressBar unbind: @"maxValue"];
	[progressBar unbind: @"leftToRight"];
	
	[pageView setSessionController: nil];
}


/*  Observes changes to the page controller.  Changes are reflected by the
    page view.  */
- (void)observeValueForKeyPath:(NSString *)keyPath
					  ofObject:(id)object
						change:(NSDictionary *)change
					   context:(void *)context
{
	if([[pageController arrangedObjects] count] <= 0)
	{
		if (session.isLoading)
		{
			// A background archive scan hasn't produced any
			// pages yet -- keep the window open showing the loading
			// overlay instead of closing it out from under the scan.
			return;
		}
		if ([keyPath isEqualToString: @"loading"] && !session.lastOpenHadErrors)
		{
			NSAlert * alert = [[NSAlert alloc] init];
			alert.alertStyle = NSAlertStyleWarning;
			NSString * sessionName = [session.groups.anyObject valueForKey: @"name"] ?: [[self window] title] ?: @"";
			alert.messageText = [NSString stringWithFormat: NSLocalizedString(@"No pages could be found in “%@”.", @"empty session alert"), sessionName];
			[alert runModal];
		}
		[self close];
//		[[NSNotificationCenter defaultCenter] postNotificationName: TSSTSessionEndNotification object: self];
		return;
	}
	else if ([keyPath isEqualToString: @"loading"])
	{
		// Pages already exist and the scan just finished -- nothing to do
		// here beyond hiding the loading overlay, handled in -updateLoadingOverlay.
		autoPinnedPageDuringScan = nil;
		[self updateLoadingOverlay];
		return;
	}

	NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
	
	if([keyPath isEqualToString: TSSTScrollersVisible])
	{
		[self scaleToWindow];
	}
	else if([keyPath isEqualToString: @"currentValue"])
	{
		if(object == progressBar)
		{
			[pageController setSelectionIndex: [progressBar currentValue]];
		}
	}
	else if([keyPath isEqualToString: @"arrangedObjects.@count"])
	{
		[self updateLoadingOverlay];

		// NSArrayController doesn't reliably select index 0 (or restore
		// session.selection) when content first arrives into a previously
		// empty controller -- pin it explicitly.
		NSUInteger pageCount = [[pageController arrangedObjects] count];
		NSUInteger selectionIndex = [pageController selectionIndex];
		if (pageCount > 0 && (selectionIndex == NSNotFound || selectionIndex >= pageCount))
		{
			NSUInteger restoredSelection = (NSUInteger)session.selection;
			NSUInteger target = restoredSelection < pageCount ? restoredSelection : 0;
			[pageController setSelectionIndex: target];
			if (session.isLoading)
			{
				autoPinnedPageDuringScan = [pageController arrangedObjects][target];
			}
		}
		else if (pageCount > 0 && session.isLoading && autoPinnedPageDuringScan)
		{
			// A background archive scan is still delivering pages in
			// batches (RAR/7z progressive listing); entries
			// don't necessarily arrive in reading order, so a later batch
			// can insert a page that now sorts before the one we pinned.
			// Follow it to the new index 0 -- but only while the user
			// hasn't navigated away from the page we auto-selected;
			// re-pinning unconditionally on every batch would fight the
			// reader for the whole (possibly many-second) scan window.
			id currentSelection = [pageController selectedObjects].firstObject;
			if (currentSelection == autoPinnedPageDuringScan)
			{
				id newFirstPage = [pageController arrangedObjects][0];
				if (newFirstPage != autoPinnedPageDuringScan)
				{
					[pageController setSelectionIndex: 0];
					autoPinnedPageDuringScan = newFirstPage;
				}
			}
			else
			{
				autoPinnedPageDuringScan = nil;
			}
		}

		/* Thumbnails are only generated while the exposé is open (see
		 -togglePageExpose:); doing it eagerly here read every page of the
		 archive right after opening, competing with the visible page on
		 slow volumes. */
		if([exposeBezel isVisible])
		{
			[NSThread detachNewThreadSelector: @selector(processThumbs) toTarget: exposeView withObject: nil];
		}
		[self changeViewImages];
		[self scheduleBufferedIndexesRefresh];
	}
	else if([keyPath isEqualToString: TSSTPageOrder])
	{
		[defaults setBool: session.pageOrder forKey: TSSTPageOrder];
		[(TSSTThumbnailView *)exposeView setNeedsDisplay: YES];
		[(TSSTThumbnailView *)exposeView buildTrackingRects];
		[self changeViewImages];
	}
	else if([keyPath isEqualToString: TSSTPageScaleOptions])
	{
		[defaults setInteger: session.scaleOptions forKey: TSSTPageScaleOptions];
		[self scaleToWindow];
	}
	else if([keyPath isEqualToString: TSSTTwoPageSpread])
	{
		[defaults setBool: session.twoPageSpread forKey: TSSTTwoPageSpread];
		[self changeViewImages];
	}
	else if([keyPath isEqualToString: TSSTBackgroundColor])
	{
		NSColor * color = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSColor class] fromData:[defaults valueForKey: TSSTBackgroundColor] error:NULL];
		[pageScrollView setBackgroundColor: color];
	}
	else if([keyPath isEqualToString: TSSTBackgroundMode])
	{
		[pageView setNeedsDisplay: YES];
	}
	else if([keyPath isEqualToString: TSSTStatusbarVisible])
	{
		[self adjustStatusBar];
	}
	else if([keyPath isEqualToString: TSSTLoupeDiameter])
	{
		NSInteger loupeDiameter = [defaults integerForKey: TSSTLoupeDiameter];
		[loupeWindow resizeToDiameter: loupeDiameter];
	}
	else if([keyPath isEqualToString: @"loupe"])
	{
		[self refreshLoupePanel];
	}
	else if([keyPath isEqualToString: TSSTLoupePower])
	{
		[self refreshLoupePanel];
	}
	else if([keyPath isEqualToString: TSSTUnifiedTitlebar])
	{
		// Apply live so already-open windows follow the Preferences checkbox.
		self.window.titleVisibility = [defaults boolForKey: TSSTUnifiedTitlebar] ? NSWindowTitleHidden : NSWindowTitleVisible;
	}
	else
	{
		[self changeViewImages];
	}
}


#pragma mark - Progress Bar


- (NSImage *)imageForPageAtIndex:(NSInteger)index
{
	return [[pageController arrangedObjects][index] valueForKey: @"thumbnail"];
}


- (NSString *)nameForPageAtIndex:(NSInteger)index
{
	return [[pageController arrangedObjects][index] valueForKey: @"name"];
}


#pragma mark - Event handling


- (void)mouseMoved:(NSEvent *)theEvent
{
	NSRect progressRect;
	NSPoint windowLocation = [theEvent locationInWindow];
	progressRect = [progressBar convertRect: [progressBar progressRect] toView: nil];
	if(NSMouseInRect(windowLocation, progressRect, [progressBar isFlipped]))
	{
		[self infoPanelSetupAtPoint: windowLocation];
	}
	
	[self refreshLoupePanel];
	
	[self handleFullscreenCursorHiding];
}


- (void)mouseEntered:(NSEvent *)theEvent
{
	NSString * purpose = [(NSDictionary *)[theEvent userData] valueForKey: @"purpose"];
	if([purpose isEqualToString: @"normalProgress"])
	{
		[self infoPanelSetupAtPoint: [theEvent locationInWindow]];
		[[self window] addChildWindow: infoWindow ordered: NSWindowAbove];
	}
}


- (void)mouseExited:(NSEvent *)theEvent
{
	if([theEvent trackingArea])
	{
		[[infoWindow parentWindow] removeChildWindow: infoWindow];
		[infoWindow orderOut: self];
	}
}


/* Handles mouse drag notifications relayed from progressbar */
- (void)handleMouseDragged:(NSNotification*)notification
{
	[infoWindow orderOut:self];
}


- (void)refreshLoupePanel
{
	BOOL loupe = session.loupe;
	NSPoint mouse = [NSEvent mouseLocation];
	
	NSRect point = NSMakeRect(mouse.x, mouse.y, 0, 0);
	NSPoint localPoint = [pageView convertPoint: [[self window] convertRectFromScreen: point].origin fromView: nil];
	NSPoint scrollPoint = [pageScrollView convertPoint: [[self window] convertRectFromScreen: point].origin fromView: nil];
	if(NSMouseInRect(scrollPoint, [pageScrollView bounds], [pageScrollView isFlipped])
	   && loupe
	   && [[self window] isKeyWindow]
	   && pageSelectionInProgress == PageSelectionModeNone)
	{
		if(![loupeWindow isVisible])
		{
			[[self window] addChildWindow: loupeWindow ordered: NSWindowAbove];
			[NSCursor hide];
		}
		
		NSRect zoomRect = [zoomView frame];
		[loupeWindow centerAtPoint: mouse];
		zoomRect.origin = localPoint;
		[zoomView setImage: [pageView imageInRect: zoomRect]];
	}
	else
	{
		if([loupeWindow isVisible])
		{
			[[loupeWindow parentWindow] removeChildWindow: loupeWindow];
			[loupeWindow orderOut: self];
		}
		
		[NSCursor unhide];
	}
}


- (void)infoPanelSetupAtPoint:(NSPoint)point
{
	NSPoint cursorPoint;
	NSInteger index;
	DTPolishedProgressBar * bar = progressBar;
	
	[[infoWindow contentView] setBordered: NO];
	point.y = (NSMaxY([bar frame]) - 6);
	
	cursorPoint = [bar convertPoint: point fromView: nil];
	index = [bar indexForPoint: cursorPoint];
	
	NSImage * thumb = [self imageForPageAtIndex: index];
	NSSize thumbSize = sizeConstrainedByDimension([thumb size], 128);
	
	[infoPicture setFrameSize: thumbSize];
	[infoPicture setImage: thumb];
	
	cursorPoint = [[bar window] convertRectToScreen: (NSRect){point, NSZeroSize}].origin;
	
	[infoWindow caretAtPoint: cursorPoint size: NSMakeSize(thumbSize.width, thumbSize.height)
			   withLimitLeft: NSMinX([[bar window] frame])
					   right: NSMaxX([[bar window] frame])];
}

- (void)handleFullscreenCursorHiding
{
	if ([[self window] isFullscreen])
	{
		// Invalidate eventual previous timer to prevent cursor flickering
		[mouseMovedTimer invalidate];
		mouseMovedTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(hideCursor) userInfo:nil repeats:NO];
	}
}

#pragma mark - Actions


- (IBAction)changeTwoPage:(id)sender
{
	BOOL spread = !session.twoPageSpread;
	session.twoPageSpread = spread;
}


- (IBAction)changePageOrder:(id)sender
{
	BOOL pageOrder = !session.pageOrder;
	session.pageOrder = pageOrder;
}


- (IBAction)changeScaling:(id)sender
{
	DTPageScaling scaleType = [sender tag] % 400;
	session.scaleOptions = scaleType;
}


- (IBAction)changeScalingNewToolbar:(id)sender
{
	DTPageScaling scaleType = [sender selectedIndex];
	session.scaleOptions = scaleType;
}

- (IBAction)turnPage:(id)sender
{
	NSInteger segmentTag = [(NSToolbarItem*)[[sender subitems] objectAtIndex: [sender selectedIndex]] tag];
	if(segmentTag == 701)
	{
		[self pageLeft: self];
	}
	else if(segmentTag == 702)
	{
		[self pageRight: self];
	}
}

- (IBAction)pageEnd:(id)sender
{
	BOOL right = ([sender selectedIndex] > 0);
	if(session.pageOrder ^ right)
	{
		[self firstPage:sender];
	}
	else
	{
		[self lastPage:sender];
	}
}

/*! Method flips the page to the right calling nextPage or previousPage
	depending on the prefered page ordering.
*/
- (IBAction)pageRight:(id)sender
{
	[self setPageTurn: 2];
	if(session.pageOrder)
	{
		[self nextPage];
	}
	else
	{
		[self previousPage];
	}
}


/*! Method flips the page to the left calling nextPage or previousPage
    depending on the prefered page ordering.
*/
- (IBAction)pageLeft:(id)sender
{
	[self setPageTurn: 1];
	
	if(session.pageOrder)
	{
		[self previousPage];
	}
	else
	{
		[self nextPage];
	}
}


- (IBAction)shiftPageRight:(id)sender
{
	if(session.pageOrder)
	{
		[pageController selectNext: sender];
	}
	else
	{
		[pageController selectPrevious: sender];
	}
}


- (IBAction)shiftPageLeft:(id)sender
{
	if(session.pageOrder)
	{
		[pageController selectPrevious: sender];
	}
	else
	{
		[pageController selectNext: sender];
	}
}


- (IBAction)skipRight:(id)sender
{
	NSUInteger index;
	if(session.pageOrder)
	{
		index = ([pageController selectionIndex] + 10);
		index = index < [[pageController content] count] ? index : [[pageController content] count] - 1;
	}
	else
	{
		index = [pageController selectionIndex] > 10 ? [pageController selectionIndex] - 10 : 0;
	}
	
	[pageController setSelectionIndex: index];
}


- (IBAction)skipLeft:(id)sender
{
	NSUInteger index;
	if(!session.pageOrder)
	{
		index = ([pageController selectionIndex] + 10);
		index = index < [[pageController content] count] ? index : [[pageController content] count] - 1;
	}
	else
	{
		index = [pageController selectionIndex] > 10 ? [pageController selectionIndex] - 10 : 0;
	}
	[pageController setSelectionIndex: index];
}


- (IBAction)firstPage:(id)sender
{
	[pageController setSelectionIndex: 0];
}


- (IBAction)lastPage:(id)sender
{
	[pageController setSelectionIndex: [[pageController content] count] - 1];
}


/* Zoom method for the zoom segmented control. Each segment has its own tag. */
- (IBAction)zoom:(id)sender
{
	NSInteger segmentTag = [(NSToolbarItem*)[[sender subitems] objectAtIndex: [sender selectedIndex]] tag];
	if(segmentTag == 801)
	{
		[self zoomIn: self];
	}
	else if(segmentTag == 802)
	{
		[self zoomOut: self];
	}
	else if(segmentTag == 803)
	{
		[self zoomReset: self];
	}
}

- (IBAction)zoomIn:(id)sender
{
	int scalingOption = session.scaleOptions;
	CGFloat previousZoom = session.zoomLevel;
	if(scalingOption != 0)
	{
		previousZoom = NSWidth([pageView imageBounds]) / [pageView combinedImageSizeForZoom: 1].width;
	}
	
	previousZoom += 0.1;
	session.zoomLevel = previousZoom;
	session.scaleOptions = 0;
	
	[pageView resizeView];
	[self refreshLoupePanel];
}

- (IBAction)zoomOut:(id)sender
{
	int scalingOption = session.scaleOptions;
	CGFloat previousZoom = session.zoomLevel;
	if(scalingOption != 0)
	{
		previousZoom = NSWidth([pageView imageBounds]) / [pageView combinedImageSizeForZoom: 1].width;
	}
	
	previousZoom -= 0.1;
	previousZoom = previousZoom < 0.1 ? 0.1 : previousZoom;
	session.zoomLevel = previousZoom;
	session.scaleOptions = 0;
	
	[pageView resizeView];
	[self refreshLoupePanel];
}

- (IBAction)zoomReset:(id)sender
{
	session.scaleOptions = 0;
	session.zoomLevel = 1.0;
	[pageView resizeView];
	[self refreshLoupePanel];
}


- (IBAction)rotate:(id)sender
{
	NSInteger segmentTag = [(NSToolbarItem*)[[sender subitems] objectAtIndex: [sender selectedIndex]] tag];
	if(segmentTag == 901)
	{
		[self rotateLeft: self];
	}
	else if(segmentTag == 902)
	{
		[self rotateRight: self];
	}
}

- (IBAction)rotateRight:(id)sender
{
	int currentRotation = session.rotation;
	currentRotation = currentRotation + 1 > 3 ? 0 : currentRotation + 1;
	session.rotation = currentRotation;
	[self resizeWindow];
	[self refreshLoupePanel];
}

- (IBAction)rotateLeft:(id)sender
{
	int currentRotation = session.rotation;
	currentRotation = currentRotation - 1 < 0 ? 3 : currentRotation - 1;
	session.rotation = currentRotation;
	[self resizeWindow];
	[self refreshLoupePanel];
}

- (IBAction)noRotation:(id)sender
{
	session.rotation = 0;
	[self resizeWindow];
	[self refreshLoupePanel];
}


- (IBAction)toggleLoupe:(id)sender
{
	BOOL loupe = session.loupe;
	loupe = !loupe;
	session.loupe = loupe;
}


- (IBAction)togglePageExpose:(id)sender
{
	if([exposeBezel isVisible])
	{
		[[thumbnailPanel parentWindow] removeChildWindow: thumbnailPanel];
		[thumbnailPanel orderOut: self];
		[exposeBezel orderOut: self];
		[[self window] makeKeyAndOrderFront: self];
		[[self window] makeFirstResponder: pageView];
	}
	else
	{
		[NSCursor unhide];
		[(TSSTThumbnailView *)exposeView buildTrackingRects];
		[exposeBezel setFrame: [[[self window] screen] frame] display: NO];
		[exposeBezel makeKeyAndOrderFront: self];
		[NSThread detachNewThreadSelector: @selector(processThumbs) toTarget: exposeView withObject: nil];
	}
}


- (IBAction)launchJumpPanel:(id)sender
{
	[jumpField setIntegerValue: [pageController selectionIndex] + 1];
	[self.window beginSheet:jumpPanel completionHandler:^(NSModalResponse returnCode) {
		[self closeSheet:returnCode];
	}];
}


- (IBAction)cancelJumpPanel:(id)sender
{
	[self.window endSheet: jumpPanel returnCode: NSModalResponseAbort];
}


- (IBAction)goToPage:(id)sender
{
	if([jumpField integerValue] != NSNotFound)
	{
		NSInteger index = [jumpField integerValue] < 1 ? 0 : [jumpField integerValue] - 1;
		[pageController setSelectionIndex: index];
	}
	
	[self.window endSheet: jumpPanel returnCode: NSModalResponseContinue];
}


- (IBAction)removePages:(id)sender
{
	pageSelectionInProgress = PageSelectionModeDelete;
	[self changeViewForSelection];
}


/*  Method that allows the user to select an icon for comic archives.
	Calls pageView and verifies that the images selected are from an
	archive. */
- (IBAction)setArchiveIcon:(id)sender
{
	pageSelectionInProgress = PageSelectionModeIcon;
	[self changeViewForSelection];
}


/*	Saves the selected page to a user specified location. */
- (IBAction)extractPage:(id)sender
{
	pageSelectionInProgress = PageSelectionModeExtract;
	[self changeViewForSelection];
}


- (BOOL)pageSelectionCanCrop
{
	return (pageSelectionInProgress == PageSelectionModeIcon);
}


/*! Used by all of the page selection methods to make both pages visible.  Also adds a small
	gutter around the images for cropping. */
- (void)changeViewForSelection
{
	savedZoom = session.zoomLevel;
	[pageScrollView setHasVerticalScroller: NO];
	[pageScrollView setHasHorizontalScroller: NO];
	[self refreshLoupePanel];
	NSSize imageSize = [pageView combinedImageSizeForZoom: 1];
	NSSize scrollerBounds = [[pageView enclosingScrollView] bounds].size;
	scrollerBounds.height -= 20;
	scrollerBounds.width -= 20;
	CGFloat factor;
	if(imageSize.width / imageSize.height > scrollerBounds.width / scrollerBounds.height)
	{
		factor = scrollerBounds.width / imageSize.width;
	}
	else
	{
		factor = scrollerBounds.height / imageSize.height;
	}
	
	session.zoomLevel = factor;
	[pageView resizeView];
}


- (BOOL)canSelectPageIndex:(NSInteger)selection
{
	// Signed math: stepping back from page 0 must not wrap around.
	NSInteger index = (NSInteger)[pageController selectionIndex] + selection;
	NSArray * arrangedObjects = [pageController arrangedObjects];
	if(index < 0 || index >= (NSInteger)[arrangedObjects count])
	{
		return NO;
	}
	TSSTPage * selectedPage = arrangedObjects[index];
	TSSTManagedGroup * selectedGroup = selectedPage.group;
	/* Makes sure that the group is both an archive and not nested */
	if([selectedGroup class] == [TSSTManagedArchive class] &&
	   selectedGroup == [selectedGroup topLevelGroup] &&
	   !selectedPage.text)
	{
		return YES;
	}
	
	return NO;
}


- (BOOL)pageSelectionInProgress
{
	return (pageSelectionInProgress != PageSelectionModeNone);
}


- (void)cancelPageSelection
{
	session.zoomLevel = savedZoom;
	pageSelectionInProgress = PageSelectionModeNone;
	[self scaleToWindow];
}


- (void)selectedPage:(NSInteger)selection withCropRect:(NSRect)cropRect
{
	switch (pageSelectionInProgress)
	{
		case PageSelectionModeIcon:
			[self setIconWithSelection: selection andCropRect: cropRect];
			break;
		case PageSelectionModeDelete:
			[self deletePageWithSelection: selection];
			break;
		case PageSelectionModeExtract:
			[self extractPageWithSelection: selection];
			break;
		default:
			break;
	}
	
	session.zoomLevel = savedZoom;
	pageSelectionInProgress = PageSelectionModeNone;
	[self scaleToWindow];
}


- (void)deletePageWithSelection:(NSInteger)selection
{
	if(selection != -1)
	{
		NSUInteger index = [pageController selectionIndex];
		index += selection;
		TSSTPage * selectedPage = [pageController arrangedObjects][index];
		[pageController removeObject: selectedPage];
		[[self managedObjectContext] deleteObject: selectedPage];
	}
}


- (void)extractPageWithSelection:(NSInteger)selection
{
	/*	selectpage returns prompts the user for which page they wish to use.
	 If there is only one page or the user selects the first page 0 is returned,
	 otherwise 1. */
	if(selection != -1)
	{
		NSUInteger index = [pageController selectionIndex];
		index += selection;
		TSSTPage * selectedPage = [pageController arrangedObjects][index];
		
		NSSavePanel * savePanel = [NSSavePanel savePanel];
		[savePanel setTitle: NSLocalizedString(@"Extract Page", @"")];
		[savePanel setPrompt: NSLocalizedString(@"Extract", @"")];
		[savePanel setNameFieldStringValue:[selectedPage name]];
		if(NSModalResponseOK == [savePanel runModal])
		{
			[[selectedPage pageData] writeToFile: [[savePanel URL] path] atomically: YES];
		}
	}
}


- (void)setIconWithSelection:(NSInteger)selection andCropRect:(NSRect)cropRect
{
	if(selection != -1)
	{
		NSUInteger index = [pageController selectionIndex];
		index += selection;
		TSSTPage * selectedPage = [pageController arrangedObjects][index];
		TSSTManagedGroup * selectedGroup = selectedPage.group;
		/* Makes sure that the group is both an archive and not nested */
		if([selectedGroup isKindOfClass:[TSSTManagedArchive class]] &&
		   selectedGroup == [selectedGroup topLevelGroup] &&
		   !selectedPage.text)
		{
			NSString * archivePath = [selectedGroup.path stringByStandardizingPath];
			if([(TSSTManagedArchive *)selectedGroup quicklookCompatible])
			{
				NSInteger coverIndex = [selectedPage.index integerValue];
				NSString * coverName = [(TSSTManagedArchive *)selectedGroup nameOfEntryAtIndex: coverIndex];
				[UKXattrMetadataStore setString: coverName
										 forKey: SCQuickLookCoverName
										 atPath: archivePath
								   traverseLink: NO
										  error: nil];
				[UKXattrMetadataStore setString: NSStringFromRect(cropRect)
										 forKey: SCQuickLookCoverRect
										 atPath: archivePath
								   traverseLink: NO
										  error: nil];
				
				if(![[NSUserDefaults standardUserDefaults] boolForKey: TSSTPreserveModDate])
				{
					[NSTask launchedTaskWithLaunchPath: @"/usr/bin/touch"
											 arguments: @[archivePath]];
				}
			}
			else
			{
				NSRect drawRect = NSMakeRect(0, 0, 496, 496);
				NSImage * iconImage = [[NSImage alloc] initWithSize: drawRect.size];
				cropRect.size = NSEqualSizes(cropRect.size, NSZeroSize) ? NSMakeSize([[selectedPage valueForKey: @"width"] doubleValue], [[selectedPage valueForKey: @"height"] doubleValue]) : cropRect.size;
				drawRect = rectWithSizeCenteredInRect( cropRect.size, drawRect);
				
				[iconImage lockFocus];
				[[NSGraphicsContext currentContext] setImageInterpolation: NSImageInterpolationHigh];
				[[selectedPage pageImage] drawInRect: drawRect fromRect: cropRect operation: NSCompositingOperationSourceOver fraction: 1];
				[iconImage unlockFocus];
				
				NSImage * shadowImage = [[NSImage alloc] initWithSize: NSMakeSize(512, 512)];
				
				NSShadow * thumbShadow = [NSShadow new];
				[thumbShadow setShadowOffset: NSMakeSize(0.0, -8.0)];
				[thumbShadow setShadowBlurRadius: 25.0];
				[thumbShadow setShadowColor: [NSColor colorWithCalibratedWhite: 0.2 alpha: 1.0]];
				
				[shadowImage lockFocus];
				[thumbShadow set];
				[iconImage drawInRect: NSMakeRect(16, 16, 496, 496) fromRect: NSZeroRect operation: NSCompositingOperationSourceOver fraction: 1];
				[shadowImage unlockFocus];
				
				[[NSWorkspace sharedWorkspace] setIcon: shadowImage forFile: archivePath options: 0];
			}
		}
	}
	
	session.zoomLevel = savedZoom;
}


- (void)closeSheet:(NSInteger)code
{
	[jumpPanel close];
}

#pragma mark - Find


- (IBAction)performOCRFindAction:(id)sender
{
	[self.find performAction:[sender tag]];
}

- (OCRFind *)find
{
	if (_find == nil)
	{
		_find = [[OCRFind alloc] init];
		_find.delegate = self;
	}
	return _find;
}

- (id<NSTextFinderBarContainer>)findBarContainer
{
	return self.pageScrollView;
}

- (NSInteger)findCount
{
	return [[pageController arrangedObjects] count];
}

- (NSInteger)findIndex
{
	return [pageController selectionIndex];
}

- (void)setFindIndex:(NSInteger)index
{
	[pageController setSelectionIndex:index];
	[pageView displayIfNeeded];
}

- (void)observationsForFindIndex:(NSInteger)index completion:(void (^)(NSArray<VNRecognizedTextObservation *> *pieces)) completion
{
	NSImage *image = [[[[self pageController] arrangedObjects] objectAtIndex:index] pageImage];
	if (image)
	{
		self.ocrVision = [[OCRVision alloc] init];
		__weak typeof(self) weakSelf = self;
		[self.ocrVision ocrImage:image completion:^(id<OCRVisionResults> ocrResults) {
			NSArray<VNRecognizedTextObservation *> *textObservations = ocrResults.textObservations;
			weakSelf.ocrVision = nil;
			completion(textObservations ?: @[]);
		}];
	} else {
		completion( @[] );
	}
}

- (void)cancelObservations
{
	[self.ocrVision cancel];
	self.ocrVision = nil;
}

#pragma mark - Applescript

- (NSScriptObjectSpecifier *)objectSpecifier
{
    NSUInteger i = [[(SimpleComicAppDelegate *)[NSApp delegate] sessions] indexOfObject:self];
    NSScriptClassDescription *desc = [NSScriptClassDescription classDescriptionForClass:[self class]];
    NSIndexSpecifier *spec = [[NSIndexSpecifier alloc] initWithContainerClassDescription:desc containerSpecifier:nil key:@"docu" index:i];
    return spec;
}

- (nullable id)handleCloseScriptCommand:(NSCloseCommand *)command
{
    return [[self window] handleCloseScriptCommand:command];
}

- (NSInteger)pageSelectionIndex
{
    return [[self pageController] selectionIndex] + 1;
}

- (void)setPageSelectionIndex:(NSInteger)index
{
    [[self pageController] setSelectionIndex:index - 1];
}

- (NSArray *)pages
{
    return [[self pageController] arrangedObjects];
}

- (NSString *)displayName
{
    return [[self window] title];
}

- (NSURL *)fileURL
{
    NSUInteger index = [pageController selectionIndex];
    TSSTPage * pageOne = [pageController arrangedObjects][index];
    return pageOne.group ? [pageOne valueForKeyPath: @"group.topLevelGroup.fileURL"] : [NSURL fileURLWithPath:pageOne.imagePath];
}

#pragma mark - Convenience Methods


- (void)hideCursor
{
	[mouseMovedTimer invalidate];
	mouseMovedTimer = nil;
	[NSCursor setHiddenUntilMouseMoves: YES];
}


- (void)restoreSession
{
	[self changeViewImages];
	[self scaleToWindow];
	[self adjustStatusBar];
	NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
	NSInteger loupeDiameter = [defaults integerForKey: TSSTLoupeDiameter];
	[loupeWindow setFrame:NSMakeRect(0,0, loupeDiameter, loupeDiameter) display: NO];
	NSColor * color = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSColor class] fromData:[defaults valueForKey: TSSTBackgroundColor] error:NULL];
	[pageScrollView setBackgroundColor: color];
	[pageView setRotation: session.rotation];
	NSValue * positionValue;
	NSData * posData = [session valueForKey: @"position"];
	
	if(posData)
	{
		positionValue = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSValue class] fromData:posData error:NULL];
		if (!positionValue) {
			positionValue = [NSUnarchiver unarchiveObjectWithData: posData];
		}
		[[self window] setFrame: [positionValue rectValue] display: NO];
		NSData * scrollData = session.scrollPosition;
		if(scrollData)
		{
			[self setShouldCascadeWindows: NO];
			positionValue = [NSKeyedUnarchiver unarchivedObjectOfClass: [NSValue class] fromData: scrollData error: NULL];
			if (!positionValue) {
				positionValue = [NSUnarchiver unarchiveObjectWithData: scrollData];
			}
			[pageView scrollPoint: [positionValue pointValue]];
		}
	}
	else
	{
		newSession = YES;
		[self setShouldCascadeWindows: YES];
		
		if (![[self window] isZoomed])
		{
			[[self window] zoom: self];
		} else {
			NSLog(@"Window is already zoomed – zoom not toggled");
		}
		
		[pageView correctViewPoint];
	}
}


#pragma mark - Non-blocking page display

/// Cheap (no network) check of whether calling -shouldDisplayAlone on
/// `page` right now would have to block on the network: nil pages, text
/// pages, pages whose aspect is already known, pages outside a streaming
/// archive, and pages whose bytes are already cached are all safe. Only a
/// page in a streaming archive with an unknown aspect and uncached bytes
/// is not.
- (BOOL)pageIsSafeToInspectSynchronously:(nullable TSSTPage *)page
{
	if (!page || page.text || page.aspectRatio != 0)
	{
		return YES;
	}
	if ([[TSSTPageDecodeCache sharedCache] imageForPage: page])
	{
		return YES; // decoding already set the aspect ratio as a side effect
	}
	TSSTManagedGroup * group = page.group;
	if (![group isKindOfClass: [TSSTManagedGroup class]])
	{
		return YES; // local file / nested PDF page -- disk read is fast
	}
	if (page.index == nil)
	{
		return YES;
	}
	return [(TSSTManagedGroup *)group isEntryIndexCached: page.index.integerValue];
}

/// -shouldDisplayAlone, but safe to call from anywhere (including
/// navigation logic run on the main thread): never fetches over the
/// network. When the real answer isn't known without a network read, this
/// guesses YES (display alone). A page-turn that could go either way then
/// re-shows the mispredicted page as a single instead of skipping a page
/// outright -- -changeViewImages self-corrects once the page is actually
/// loaded and the real aspect ratio is known.
- (BOOL)navigationShouldDisplayAlonePage:(nullable TSSTPage *)page
{
	if (!page)
	{
		return NO;
	}
	if ([self pageIsSafeToInspectSynchronously: page])
	{
		return page.shouldDisplayAlone;
	}
	// Bytes aren't cached and the aspect is unknown -- nudge the streamer
	// toward this entry (we're likely headed there) without blocking here.
	[(TSSTManagedGroup *)page.group prioritizeEntryIndex: page.index.integerValue];
	return YES;
}

/// -pageImage, preferring an already-decoded image from the pre-decode
/// cache. Safe to call on the main thread only when the caller has already
/// established the page won't have to block on the network (see
/// -pageIsSafeToInspectSynchronously:).
- (nullable NSImage *)displayImageForPage:(nullable TSSTPage *)page
{
	if (!page)
	{
		return nil;
	}
	NSImage * cached = [[TSSTPageDecodeCache sharedCache] imageForPage: page];
	return cached ?: page.pageImage;
}

/// Tells the page's archive (if any) that this is the page currently being
/// read, so the background streamer follows the reader.
- (void)noteReadingForPage:(nullable TSSTPage *)page
{
	if (page.index != nil && [page.group isKindOfClass: [TSSTManagedGroup class]])
	{
		[(TSSTManagedGroup *)page.group noteReadingEntryIndex: page.index.integerValue];
	}
}

/// Like -noteReadingForPage:, but also wakes the streamer immediately --
/// used when a page has to be fetched now, not merely queued.
- (void)prioritizeReadingForPage:(nullable TSSTPage *)page
{
	if (page.index != nil && [page.group isKindOfClass: [TSSTManagedGroup class]])
	{
		[(TSSTManagedGroup *)page.group prioritizeEntryIndex: page.index.integerValue];
	}
}

- (void)changeViewImages
{
	NSUInteger count = [[pageController arrangedObjects] count];
	if (count == 0)
	{
		// Nothing to show yet -- e.g. a session still being scanned in the
		// background with 0 pages so far. The loading
		// overlay covers the page view in this state.
		return;
	}
	NSUInteger index = [pageController selectionIndex];
	if (index == NSNotFound || index >= count)
	{
		index = 0;
	}
	TSSTPage * pageOne = [pageController arrangedObjects][index];
	TSSTPage * pageTwoCandidate = (index + 1) < count ? [pageController arrangedObjects][(index + 1)] : nil;
	/* Don't wait on a second page that can't end up in the spread: on a
	 slow link that would double the wait for pages that show alone anyway. */
	BOOL pageOneKnownAlone = pageOne.text || (pageOne.aspectRatio != 0 && pageOne.aspectRatio > 1);
	if (!session.twoPageSpread || pageOneKnownAlone ||
		(index == 0 && [[NSUserDefaults standardUserDefaults] boolForKey: TSSTLonelyFirstPage]))
	{
		pageTwoCandidate = nil;
	}

	displayGeneration++;
	NSUInteger generation = displayGeneration;

	[self noteReadingForPage: pageOne];
	[self noteReadingForPage: pageTwoCandidate];

	BOOL oneReady = [[TSSTPageDecodeCache sharedCache] imageForPage: pageOne] != nil
		|| pageOne.text || [self pageIsSafeToInspectSynchronously: pageOne];
	BOOL twoReady = !pageTwoCandidate
		|| [[TSSTPageDecodeCache sharedCache] imageForPage: pageTwoCandidate] != nil
		|| pageTwoCandidate.text || [self pageIsSafeToInspectSynchronously: pageTwoCandidate];

	if (oneReady && twoReady)
	{
		[self finishDisplayForIndex: index pageOne: pageOne candidateTwo: pageTwoCandidate generation: generation];
	}
	else
	{
		[self loadPagesAsynchronouslyForIndex: index pageOne: pageOne pageTwoCandidate: pageTwoCandidate generation: generation];
	}
}

/// Kicks off an off-main fetch+decode of `pageOne` (and `pageTwoCandidate`,
/// if any) when at least one of them isn't ready to show synchronously.
/// The currently displayed page(s) stay on screen while this runs; a
/// small HUD appears if it takes more than ~150ms.
- (void)loadPagesAsynchronouslyForIndex:(NSUInteger)index pageOne:(TSSTPage *)pageOne pageTwoCandidate:(nullable TSSTPage *)pageTwoCandidate generation:(NSUInteger)generation
{
	[self prioritizeReadingForPage: pageOne];
	[self prioritizeReadingForPage: pageTwoCandidate];

	__weak typeof(self) weakSelf = self;
	// A HUD left up by an earlier, still-loading generation now describes
	// this one: retarget it at once rather than after another 150 ms.
	if (pageLoadHUDView)
	{
		[self showPageLoadHUDForPageNumber: index + 1];
	}
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		typeof(self) strongSelf = weakSelf;
		if (!strongSelf || generation != strongSelf->displayGeneration || generation == strongSelf->displayedGeneration)
		{
			return; // selection already moved on, or this generation already finished displaying
		}
		[strongSelf showPageLoadHUDForPageNumber: index + 1];
	});

	NSArray<TSSTPage *> * pages = pageTwoCandidate ? @[pageOne, pageTwoCandidate] : @[pageOne];
	[[TSSTPageDecodeCache sharedCache] decodePages: pages whileCurrent: ^BOOL{
		typeof(self) strongSelf = weakSelf;
		return strongSelf && generation == strongSelf->displayGeneration;
	} completion: ^(BOOL ran) {
		typeof(self) strongSelf = weakSelf;
		// A generation the reader moved past neither displays nor touches
		// the HUD: it belongs to the newer generation, which hides it in
		// -finishDisplayForIndex:... (a stale completion hiding it made
		// the current page's wait look finished while it was not).
		if (!strongSelf || generation != strongSelf->displayGeneration)
		{
			return;
		}
		[strongSelf finishDisplayForIndex: index pageOne: pageOne candidateTwo: pageTwoCandidate generation: generation];
	}];
}

/// Common tail of page display, whether pageOne/candidateTwo were ready
/// immediately or just finished loading asynchronously: decides the final
/// pairing (now that both pages' real aspect ratios are known, or safe to
/// read), and pushes the images/title/prefetch. Main-thread only.
- (void)finishDisplayForIndex:(NSUInteger)index pageOne:(TSSTPage *)pageOne candidateTwo:(nullable TSSTPage *)candidateTwo generation:(NSUInteger)generation
{
	if (generation != displayGeneration)
	{
		return; // superseded by a later selection change
	}
	displayedGeneration = generation;
	// Whatever HUD is up was for a load that this display supersedes or ends.
	[self hidePageLoadHUD];

	TSSTPage * pageTwo = candidateTwo;
	NSString * titleString = pageOne.name;
	NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];

	BOOL currentAllowed = ![pageOne shouldDisplayAlone] &&
	!(index == 0 && [defaults boolForKey: TSSTLonelyFirstPage]);

	if(currentAllowed && session.twoPageSpread && pageTwo && ![pageTwo shouldDisplayAlone])
	{
		if(session.pageOrder)
		{
			titleString = [NSString stringWithFormat:@"%@ %@", titleString, pageTwo.name];
		}
		else
		{
			titleString = [NSString stringWithFormat:@"%@ %@", pageTwo.name, titleString];
		}
	}
	else
	{
		pageTwo = nil;
	}

	NSURL *representationURL = pageOne.group ? [pageOne valueForKeyPath: @"group.topLevelGroup.fileURL"] : [NSURL fileURLWithPath:pageOne.imagePath];
	[[self window] setRepresentedURL: representationURL];

	NSString *fileName = nil;
	[representationURL getResourceValue:&fileName forKey:NSURLLocalizedNameKey error:NULL];
	if (fileName == nil) {
		fileName = representationURL.lastPathComponent;
	}
	self.window.title = fileName;
	if ([fileName isEqualToString:titleString]) {
		self.window.subtitle = @"";
	} else {
		self.window.subtitle = titleString;
	}
	[pageView setFirstPage: [self displayImageForPage: pageOne] secondPageImage: [self displayImageForPage: pageTwo]];
	pageView.firstPageKey = pageOne.objectID;
	pageView.secondPageKey = pageTwo.objectID;

	// Called by the page view when its blur source isn't cached yet; redraws
	// once each page's source is ready (unless the view has moved on).
	__weak TSSTSessionWindowController * weakSelf = self;
	__weak TSSTPageView * weakPageView = pageView;
	pageView.requestMissingBackgroundSources = ^{
		for(TSSTPage * page in (pageTwo ? @[pageOne, pageTwo] : @[pageOne]))
		{
			[weakSelf prepareEdgeBlurSourceForPage: page completion: ^{
				TSSTPageView * strongPageView = weakPageView;
				if([strongPageView.firstPageKey isEqual: page.objectID] || [strongPageView.secondPageKey isEqual: page.objectID])
				{
					[strongPageView setNeedsDisplay: YES];
				}
			}];
		}
	};

	[self scaleToWindow];
	[pageView correctViewPoint];
	[self refreshLoupePanel];

	[self predecodeNeighborsAroundIndex: index twoPageMode: (pageTwo != nil)];
	[self prefetchEdgeBlurSourcesAroundIndex: index twoPageMode: (pageTwo != nil)];
}


/*!	Ensures a small (256px) decoded blur source is cached for `page`,
	following the app's existing off-main thumbnail precedent: if
	`page.thumbnailData` already exists, decoding it touches nothing but the
	data itself off the main thread; if it doesn't, `page.thumbnail` (which
	itself reads/writes the managed `thumbnailData` attribute) is called off
	the main thread exactly the way TSSTThumbnailItemView already does for
	the Touch Bar strip. `completion` always runs on the main queue. */
- (void)prepareEdgeBlurSourceForPage:(TSSTPage *)page completion:(void (^)(void))completion
{
	TSSTEdgeBlurRenderer * renderer = [TSSTEdgeBlurRenderer sharedRenderer];
	NSManagedObjectID * key = page.objectID;
	if([renderer hasSourceForPageKey: key])
	{
		if(completion)
		{
			completion();
		}
		return;
	}

	NSData * existingThumbnailData = page.thumbnailData; // Core Data read, main thread
	__weak TSSTPage * weakPage = page;
	NSImage * (^pageImageProvider)(void) = existingThumbnailData ? nil : ^NSImage * {
		return weakPage.thumbnail;
	};

	[renderer prepareSourceForPageKey: key
						thumbnailData: existingThumbnailData
					pageImageProvider: pageImageProvider
						   completion: completion];
}


/*!	Best-effort prefetch of blur sources for the pages around `index`, so
	the "blurred page edges" background is normally already cached by the
	time a page turn actually happens. Single-page mode covers -1, current,
	+1 and +2; two-page mode covers -2 through +3 (which already includes
	the current pair). Off the main thread; see -prepareEdgeBlurSourceForPage:. */
- (void)prefetchEdgeBlurSourcesAroundIndex:(NSUInteger)index twoPageMode:(BOOL)twoPageMode
{
	if([[NSUserDefaults standardUserDefaults] integerForKey: TSSTBackgroundMode] != TSSTBackgroundModeBlurredEdges)
	{
		return;
	}

	NSArray<TSSTPage *> * pages = [pageController arrangedObjects];
	NSInteger count = (NSInteger)pages.count;
	NSArray<NSNumber *> * offsets = twoPageMode ? @[@-2, @-1, @0, @1, @2, @3] : @[@-1, @0, @1, @2];

	for(NSNumber * offsetNumber in offsets)
	{
		NSInteger candidate = (NSInteger)index + offsetNumber.integerValue;
		if(candidate < 0 || candidate >= count)
		{
			continue;
		}
		[self prepareEdgeBlurSourceForPage: pages[candidate] completion: nil];
	}
}


#pragma mark - Pre-decode

/// Best-effort off-main pre-decode of the pages a reader is likely to turn
/// to next: the next 2 pages in reading direction (4 in two-page mode) and
/// the previous page. Only pages whose bytes are already cached (or that
/// are local) are decoded, so this never competes with the network
/// streamer for bandwidth.
- (void)predecodeNeighborsAroundIndex:(NSUInteger)index twoPageMode:(BOOL)twoPageMode
{
	NSArray<TSSTPage *> * pages = [pageController arrangedObjects];
	NSInteger count = (NSInteger)pages.count;
	NSArray<NSNumber *> * offsets = twoPageMode ? @[@-1, @1, @2, @3, @4] : @[@-1, @1, @2];

	NSMutableArray<TSSTPage *> * candidates = [NSMutableArray array];
	for (NSNumber * offsetNumber in offsets)
	{
		NSInteger candidateIndex = (NSInteger)index + offsetNumber.integerValue;
		if (candidateIndex < 0 || candidateIndex >= count)
		{
			continue;
		}
		TSSTPage * page = pages[candidateIndex];
		if (page.text || [[TSSTPageDecodeCache sharedCache] imageForPage: page])
		{
			continue;
		}
		if ([self pageIsSafeToInspectSynchronously: page] && (page.group == nil || ![page.group isKindOfClass: [TSSTManagedGroup class]] || page.index == nil || [(TSSTManagedGroup *)page.group isEntryIndexCached: page.index.integerValue]))
		{
			[candidates addObject: page];
		}
	}

	if (candidates.count == 0)
	{
		return;
	}

	TSSTPageDecodeCache * decodeCache = [TSSTPageDecodeCache sharedCache];
	dispatch_async(decodeCache.decodeQueue, ^{
		for (TSSTPage * page in candidates)
		{
			[decodeCache decodeAndCachePage: page];
		}
	});
}


#pragma mark - Page-load HUD

/// Compact centered HUD ("Loading page N...") shown over the page view
/// while a page is being fetched over the network. Unlike
/// -updateLoadingOverlay, it never covers the whole page with an opaque
/// view -- the currently displayed page stays visible underneath.
- (void)showPageLoadHUDForPageNumber:(NSUInteger)pageNumber
{
	NSString * message = [NSString stringWithFormat: NSLocalizedString(@"Loading page %lu…", @"HUD shown while a page is fetched over a slow network volume"), (unsigned long)pageNumber];

	if (pageLoadHUDView)
	{
		pageLoadLabel.stringValue = message;
		return;
	}

	NSView * container = pageScrollView.superview ?: pageScrollView;
	NSSize hudSize = NSMakeSize(220, 60);

	NSVisualEffectView * hud = [[NSVisualEffectView alloc] initWithFrame: NSMakeRect(0, 0, hudSize.width, hudSize.height)];
	hud.material = NSVisualEffectMaterialHUDWindow;
	hud.state = NSVisualEffectStateActive;
	hud.wantsLayer = YES;
	hud.layer.cornerRadius = 10;
	hud.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
	pageLoadHUDView = hud;

	pageLoadSpinner = [[NSProgressIndicator alloc] initWithFrame: NSMakeRect(NSMidX(hud.bounds) - 12, 26, 24, 24)];
	pageLoadSpinner.style = NSProgressIndicatorStyleSpinning;
	pageLoadSpinner.indeterminate = YES;
	pageLoadSpinner.controlSize = NSControlSizeSmall;
	[pageLoadSpinner startAnimation: nil];

	pageLoadLabel = [[NSTextField alloc] initWithFrame: NSMakeRect(10, 8, hudSize.width - 20, 16)];
	pageLoadLabel.editable = NO;
	pageLoadLabel.bordered = NO;
	pageLoadLabel.drawsBackground = NO;
	pageLoadLabel.alignment = NSTextAlignmentCenter;
	pageLoadLabel.font = [NSFont systemFontOfSize: 11];
	pageLoadLabel.textColor = [NSColor labelColor];
	pageLoadLabel.stringValue = message;

	[hud addSubview: pageLoadSpinner];
	[hud addSubview: pageLoadLabel];

	NSRect containerBounds = container.bounds;
	hud.frame = NSMakeRect(NSMidX(containerBounds) - hudSize.width / 2.0, NSMidY(containerBounds) - hudSize.height / 2.0, hudSize.width, hudSize.height);

	[container addSubview: hud positioned: NSWindowAbove relativeTo: pageScrollView];
}

- (void)hidePageLoadHUD
{
	[pageLoadSpinner stopAnimation: nil];
	[pageLoadHUDView removeFromSuperview];
	pageLoadHUDView = nil;
	pageLoadSpinner = nil;
	pageLoadLabel = nil;
}


- (void)resizeWindow
{
    NSRect allowedRect;
    NSRect zoomFrame;
    NSRect frame;
    if([[self window] isFullscreen])
    {
        allowedRect = [[[self window] screen] frame];
        [[self window] setFrame: allowedRect display: YES animate: NO];
    }
    else if([[NSUserDefaults standardUserDefaults] boolForKey: TSSTWindowAutoResize])
    {
        allowedRect = [[[self window] screen] visibleFrame];
		frame = [[self window] frame];
		allowedRect = NSMakeRect(frame.origin.x, NSMinY(allowedRect),
								 NSMaxX(allowedRect) - NSMinX(frame),
								 NSMaxY(frame) - NSMinY(allowedRect));
        zoomFrame = [self optimalPageViewRectForRect: allowedRect];
        [[self window] setFrame: zoomFrame display: YES animate: NO];
    }
}


- (void)scaleToWindow
{
    BOOL hasVert = NO;
    BOOL hasHor = NO;
	int scaling = session.scaleOptions;
	
	if(pageSelectionInProgress || ![[NSUserDefaults standardUserDefaults] boolForKey: TSSTScrollersVisible])
	{
		scaling = 1;
	}
	else if([self currentPageIsText])
	{
		scaling = 2;
	}

	switch (scaling)
	{
		case  0:
			hasVert = YES;
			hasHor = YES;
			break;
		case  2:
			session.zoomLevel = 1.0;
			if([pageView rotation] == 1 || [pageView rotation] == 3)
			{
				hasHor = YES;
			}
			else
			{
				hasVert = YES;
			}
			break;
		default:
			session.zoomLevel = 1.0;
			break;
	}
	
    [pageScrollView setHasVerticalScroller: hasVert];
    [pageScrollView setHasHorizontalScroller: hasHor];
	
	if(pageSelectionInProgress == PageSelectionModeNone)
	{
		[self resizeWindow];
	}
	
    [pageView resizeView];
    [self refreshLoupePanel];
}


- (void)adjustStatusBar
{
    NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
    NSRect scrollViewRect;
    BOOL statusBar = [defaults boolForKey: TSSTStatusbarVisible];
    if(statusBar)
    {
        scrollViewRect = [[[self window] contentView] frame];
        scrollViewRect = NSMakeRect(NSMinX(scrollViewRect),
                                    NSMinY(scrollViewRect) + 23,
                                    NSWidth(scrollViewRect),
                                    NSHeight(scrollViewRect) - 23);
        [[self window] setContentBorderThickness: 23 forEdge: NSMinYEdge];
        [pageScrollView setFrame: scrollViewRect];
        [progressBar setHidden: NO];
        [self resizeWindow];
    }
    else
    {
        scrollViewRect = [[[self window] contentView] frame];
        [progressBar setHidden: YES];
        [pageScrollView setFrame: scrollViewRect];
        [[self window] setContentBorderThickness: 0 forEdge: NSMinYEdge];
        [self resizeWindow];
    }
}


- (void)nextPage
{
    if(!session.twoPageSpread)
    {
        [pageController selectNext: self];
        return;
    }
	
    NSUInteger numberOfImages = [[pageController arrangedObjects] count];
	NSUInteger selectionIndex = [pageController selectionIndex];
	if((selectionIndex + 1) >= numberOfImages)
	{
		return;
	}
	
	NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
	BOOL current = ![self navigationShouldDisplayAlonePage: [pageController arrangedObjects][selectionIndex]] &&
        !(selectionIndex == 0 &&[defaults boolForKey: TSSTLonelyFirstPage]);
	BOOL next = ![self navigationShouldDisplayAlonePage: [pageController arrangedObjects][(selectionIndex + 1)]];
	
	if((!current || !next) && ((selectionIndex + 1) < numberOfImages))
	{
		[pageController setSelectionIndex: (selectionIndex + 1)];
	}
	else if((selectionIndex + 2) < numberOfImages)
	{
		[pageController setSelectionIndex: (selectionIndex + 2)];
	}
	else if(((selectionIndex + 1) < numberOfImages) && !next)
	{
		[pageController setSelectionIndex: (selectionIndex + 1)];
	}
}


- (void)previousPage
{
    if(!session.twoPageSpread)
    {
        [pageController selectPrevious: self];
        return;
    }
	
	NSInteger selectionIndex = [pageController selectionIndex];
	if((selectionIndex - 2) >= 0)
	{
        NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];

        BOOL previousPage = ![self navigationShouldDisplayAlonePage: [pageController arrangedObjects][(selectionIndex - 1)]];
		BOOL pageBeforeLast = ![self navigationShouldDisplayAlonePage: [pageController arrangedObjects][(selectionIndex - 2)]] &&
		!((selectionIndex - 2) == 0 && [defaults boolForKey: TSSTLonelyFirstPage]);
        
        if(!previousPage || !pageBeforeLast)
		{
			[pageController setSelectionIndex: (selectionIndex - 1)];
			return;
		}
		[pageController setSelectionIndex: (selectionIndex - 2)];
		return;
	}
	
	if((selectionIndex - 1) >= 0)
	{
		[pageController setSelectionIndex: (selectionIndex - 1)];
	}
}


- (void)updateSessionObject
{
    if(![[self window] isFullscreen])
    {
        NSValue * postionValue = [NSValue valueWithRect: [[self window] frame]];
        NSData * posData = [NSKeyedArchiver archivedDataWithRootObject: postionValue requiringSecureCoding: YES error: NULL];
        session.position = posData;
        
        postionValue = [NSValue valueWithPoint: [[pageView enclosingScrollView] documentVisibleRect].origin];
        posData = [NSKeyedArchiver archivedDataWithRootObject: postionValue requiringSecureCoding: YES error: NULL];
        session.scrollPosition = posData;
    }
    else
    {
        session.scrollPosition = nil;
        [session setValue: nil forKey: TSSTScrollPosition ];
    }
}


- (void)killTopOptionalUIElement
{
	if([exposeBezel isVisible])
	{
		[exposeBezel removeChildWindow: thumbnailPanel];
        [thumbnailPanel orderOut: self];
		[exposeBezel orderOut: self];
	}
    else if([[self window] isFullscreen])
    {
        [[self window] toggleFullScreen: self];
    }
	else if(session.loupe)
	{
        session.loupe = NO;
	}
}


- (void)killAllOptionalUIElements
{
    if([[self window] isFullscreen])
    {
        [[self window] toggleFullScreen: self];
    }
    session.loupe = NO;
    [self refreshLoupePanel];
	[exposeBezel removeChildWindow: thumbnailPanel];
	[thumbnailPanel orderOut: self];
	[exposeBezel orderOut: self];
}


#pragma mark -
#pragma mark Binding Methods

@synthesize session;


- (NSManagedObjectContext *)managedObjectContext
{
    return [(SimpleComicAppDelegate *)[NSApp delegate] managedObjectContext];
}


- (BOOL)canTurnPageLeft
{
	if(session.pageOrder)
    {
        return [self canTurnPreviousPage];
    }
    else
    {
        return [self canTurnPageNext];
    }
}


- (BOOL)canTurnPageRight
{
	if(session.pageOrder)
    {
        return [self canTurnPageNext];
    }
    else
    {
        return [self canTurnPreviousPage];
    }
}


/*	TODO: make the following a bit smarter.  Also the next/previous page turn logic
	ie. Should not be able to turn the page if 2 pages from the end */
- (BOOL)canTurnPreviousPage
{
	return !([pageController selectionIndex] <= 0);
}


- (BOOL)canTurnPageNext
{
	NSInteger selectionIndex = [pageController selectionIndex];
	if([pageController selectionIndex] >= ([[pageController content] count] - 1))
	{
		return NO;
	}
	
	if((selectionIndex + 1) == ([[pageController content] count] - 1) && session.twoPageSpread)
	{
		NSArray * arrangedPages = [pageController arrangedObjects];
		BOOL displayCurrentAlone = [arrangedPages[selectionIndex] shouldDisplayAlone];
		BOOL displayNextAlone = [arrangedPages[selectionIndex + 1] shouldDisplayAlone];

		if (!displayCurrentAlone && !displayNextAlone)
        {
			return NO;
		}
	}
	
	return YES;
}


#pragma mark Menus

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	if(pageSelectionInProgress)
	{
		return NO;
	}
	
	BOOL valid = YES;
    NSControlStateValue state;
    if([menuItem action] == @selector(toggleFullScreen:))
    {
        state = [[self window] isFullscreen] ? NSControlStateValueOn : NSControlStateValueOff;
        [menuItem setState: state];
    }
    else if([menuItem action] == @selector(changeTwoPage:))
    {
        state = session.twoPageSpread ? NSControlStateValueOn : NSControlStateValueOff;
        [menuItem setState: state];
    }
    else if([menuItem action] == @selector(changePageOrder:))
    {
        if(session.pageOrder)
        {
            [menuItem setTitle: NSLocalizedString(@"Right to Left", @"Right to left page order menu item text")];
			if (@available(macOS 26, *)) {
				menuItem.image = [NSImage imageNamed:ACImageNameRightLeftOrderTemplate];
			}
        }
        else
        {
            [menuItem setTitle: NSLocalizedString(@"Left to Right", @"Left to right page order menu item text")];
			if (@available(macOS 26, *)) {
				menuItem.image = [NSImage imageNamed:ACImageNameLeftRightOrderTemplate];
			}
        }
    }
	else if([menuItem action] == @selector(pageRight:))
	{
		valid = [self canTurnPageRight];
	}
	else if([menuItem action] == @selector(pageLeft:))
	{
		valid = [self canTurnPageLeft];
	}
	else if ([menuItem action] == @selector(firstPage:))
	{
		valid = !([pageController selectionIndex] <= 0);
	}
	else if ([menuItem action] == @selector(lastPage:))
	{
		valid = !([pageController selectionIndex] >= ([[pageController content] count] - 1));
	}
	else if ([menuItem action] == @selector(shiftPageRight:))
	{
		valid = [self canTurnPageRight];
	}
	else if ([menuItem action] == @selector(shiftPageLeft:))
	{
		valid = [self canTurnPageLeft];
	}
	else if ([menuItem action] == @selector(skipRight:))
	{
		valid = [self canTurnPageRight];
	}
	else if ([menuItem action] == @selector(skipLeft:))
	{
		valid = [self canTurnPageLeft];
	}
	else if ([menuItem action] == @selector(setArchiveIcon:))
	{
		valid = !session.rotation;
	}
	else if ([menuItem action] == @selector(extractPage:))
	{
		valid = !session.rotation;
	}
	else if ([menuItem action] == @selector(removePages:))
	{
		valid = !session.rotation;
	}
	else if ([menuItem action] == @selector(performOCRFindAction:))
	{
		NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
		return ![defaults boolForKey:OCRDisableKey] && [self.find validateAction:[menuItem tag]];
	}
    else if([menuItem tag] == 400)
    {
        state = session.scaleOptions == 0 ? NSControlStateValueOn : NSControlStateValueOff;
        [menuItem setState: state];
    }
    else if([menuItem tag] == 401)
    {
        state = session.scaleOptions == 1 ? NSControlStateValueOn : NSControlStateValueOff;
        [menuItem setState: state];
    }
    else if([menuItem tag] == 402)
    {
        state = session.scaleOptions == 2 ? NSControlStateValueOn : NSControlStateValueOff;
        [menuItem setState: state];
    }
	
    return valid;
}


#pragma mark -
#pragma mark Delegates


- (BOOL)control:(NSTextField *)control didFailToFormatString:(NSString *)string errorDescription:(NSString *)error
{
	NSInteger pageNumber = [string integerValue];
	if(pageNumber > [[pageController arrangedObjects] count])
	{
		[jumpField setIntegerValue: [[pageController arrangedObjects] count]];
	}
	else
	{
		NSBeep();
		[jumpField setIntegerValue: [pageController selectionIndex] + 1];
	}
	
	return YES;
}


- (void)prepareToEnd
{
	[(TSSTThumbnailView *)exposeView cancelThumbnailProcessing];
	[[self window] setAcceptsMouseMovedEvents: NO];
	[mouseMovedTimer invalidate];
	mouseMovedTimer = nil;
    [NSCursor unhide];
    [NSApp setPresentationOptions: NSApplicationPresentationDefault];
	
    [session removeObserver: self forKeyPath: TSSTPageOrder];
    [session removeObserver: self forKeyPath: TSSTPageScaleOptions];
    [session removeObserver: self forKeyPath: TSSTTwoPageSpread];
	[session removeObserver: self forKeyPath: @"loupe"];
    [session unbind: TSSTViewRotation];
    [session unbind: @"selection"];
}


- (BOOL)windowShouldClose:(NSWindow *)sender
{
	[self prepareToEnd];
	[[NSNotificationCenter defaultCenter] postNotificationName: TSSTSessionEndNotification object: self];

    return YES;
}


- (void)windowDidBecomeKey:(NSNotification *)aNotification
{
    if([aNotification object] == [self window])
    {
        if([[self window] isFullscreen])
        {
            // The window is regaining key status while still fullscreen (e.g. after
            // dismissing the thumbnail panel, or returning from a Space switch).
            // Re-derive the fullscreen presentation options instead of resetting to
            // NSApplicationPresentationDefault, which would leave the toolbar/menu
            // bar/dock stuck visible (or hidden) until fullscreen is toggled off and
            // back on. See #112.
            [NSApp setPresentationOptions: [self window: [self window] willUseFullScreenPresentationOptions: [NSApp presentationOptions]]];
        }
        else
        {
            [NSApp setPresentationOptions: NSApplicationPresentationDefault];
        }
		if(session.loupe)
		{
			[NSCursor hide];
		}
		[self refreshLoupePanel];
		[self handleFullscreenCursorHiding];
    }
}


- (void)windowDidResignKey:(NSNotification *)aNotification
{
    if([aNotification object] == exposeBezel)
    {
        [exposeBezel orderOut: self];
    }
	
	if([aNotification object] == [self window])
	{
		[NSCursor unhide];
		[self refreshLoupePanel];
		[[infoWindow parentWindow] removeChildWindow: infoWindow];
		[infoWindow orderOut: self];
	}
}


- (void)windowDidResize:(NSNotification *)aNotification
{
	BOOL statusBar;
    if([aNotification object] == [self window])
    {
		[[infoWindow parentWindow] removeChildWindow: infoWindow];
        [infoWindow orderOut: self];
		
        statusBar = [[NSUserDefaults standardUserDefaults] boolForKey: TSSTStatusbarVisible];
		
        if(statusBar)
        {
            NSPoint mouse = [NSEvent mouseLocation];
            NSRect point = NSMakeRect(mouse.x, mouse.y, 0, 0);
            NSPoint mouseLocation = [[self window] convertRectFromScreen: point].origin;

            NSRect progressRect = [[[self window] contentView] convertRect: [progressBar progressRect] fromView: progressBar];
			BOOL cursorInside = NSMouseInRect(mouseLocation, progressRect, [[[self window] contentView] isFlipped]);
			if(cursorInside && ![pageView inLiveResize])
			{
				[self infoPanelSetupAtPoint: mouseLocation];
				[[self window] addChildWindow: infoWindow ordered: NSWindowAbove];
			}
        }
	}
}

/*	This method deals with window resizing.  It is called every time the user clicks
	the nice little plus button in the upper left of the window. */
- (NSRect)windowWillUseStandardFrame:(NSWindow *)sender defaultFrame:(NSRect)defaultFrame
{
	if(sender == [self window])
	{
		defaultFrame = [self optimalPageViewRectForRect: defaultFrame];
	}
	
	return defaultFrame;
}

- (NSRect)optimalPageViewRectForRect:(NSRect)boundingRect
{
	NSSize maxImageSize = [pageView combinedImageSizeForZoom: session.zoomLevel];
	CGFloat vertOffset = [[self window] contentBorderThicknessForEdge: NSMinYEdge] + [[self window] toolbarHeight];
	if([pageScrollView hasHorizontalScroller] && pageScrollView.horizontalScroller.scrollerStyle == NSScrollerStyleLegacy)
	{
		vertOffset += NSHeight([[pageScrollView horizontalScroller] frame]);
	}
	CGFloat horOffset = [pageScrollView hasVerticalScroller] && pageScrollView.verticalScroller.scrollerStyle == NSScrollerStyleLegacy ? [NSScroller scrollerWidthForControlSize:pageScrollView.verticalScroller.controlSize scrollerStyle:pageScrollView.verticalScroller.scrollerStyle] : 0;
	NSSize minSize = [[self window] minSize];
	NSRect correctedFrame = boundingRect;
	correctedFrame.size.width = MAX(NSWidth(correctedFrame), minSize.width);
	correctedFrame.size.height = MAX(NSHeight(correctedFrame), minSize.height);
	correctedFrame.size.width -= horOffset;
	correctedFrame.size.height -= vertOffset;
	NSSize newSize;
	if(session.scaleOptions == 1 && ![self currentPageIsText])
	{
		CGFloat scale;
		if( maxImageSize.width < NSWidth(correctedFrame) && maxImageSize.height < NSHeight(correctedFrame))
		{
			scale = 1;
		}
		else if( NSWidth(correctedFrame) / NSHeight(correctedFrame) < maxImageSize.width / maxImageSize.height)
		{
			scale = NSWidth(correctedFrame) / maxImageSize.width;
		}
		else
		{
			scale = NSHeight(correctedFrame) / maxImageSize.height;
		}
		newSize = scaleSize(maxImageSize, scale);
	}
	else
	{
		newSize.width = maxImageSize.width < NSWidth(correctedFrame) ? maxImageSize.width : NSWidth(correctedFrame);
		newSize.height = maxImageSize.height < NSHeight(correctedFrame) ? maxImageSize.height : NSHeight(correctedFrame);
	}
	
	newSize.width += horOffset;
	newSize.height += vertOffset;
	
	newSize.width = newSize.width < minSize.width ? minSize.width : newSize.width;
	newSize.height = newSize.height < minSize.height ? minSize.height : newSize.height;
	
	NSRect windowFrame = NSMakeRect(NSMinX(boundingRect), NSMaxY(boundingRect) - newSize.height, newSize.width, newSize.height);
	return windowFrame;
}

- (void)resizeView
{
	[pageView resizeView];
}

- (BOOL)currentPageIsText
{
	TSSTPage * page = [pageController selectedObjects].firstObject;
	return page.text;
}


- (void)toolbarWillAddItem:(NSNotification *)notification
{
	NSToolbarItem * item = [notification userInfo][@"item"];
	
	if([[item label] isEqualToString: @"Page Scaling"])
	{
		[[item view] bind: @"selectedIndex" toObject: self withKeyPath: @"session.scaleOptions" options: nil];
	}
	else if([[item label] isEqualToString: @"Page Order"])
	{
		[[item view] bind: @"selectedIndex" toObject: self withKeyPath: @"session.pageOrder" options: nil];
	}
	else if([[item label] isEqualToString: @"Page Layout"])
	{
		[[item view] bind: @"selectedIndex" toObject: self withKeyPath: @"session.twoPageSpread" options: nil];
	}
	else if([[item label] isEqualToString: @"Loupe"])
	{
		[[item view] bind: @"value" toObject: self withKeyPath: @"session.loupe" options: nil];
	}
}


#pragma Fullscreen Delegate Methods

- (NSApplicationPresentationOptions)window:(NSWindow *)window willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)proposedOptions
{
	if([[self window] isEqual: window])
	{
		if (![[NSUserDefaults standardUserDefaults] boolForKey: TSSTFullscreenToolbar])
		{
			return NSApplicationPresentationAutoHideDock |
			NSApplicationPresentationAutoHideMenuBar |
			NSApplicationPresentationAutoHideToolbar |
			NSApplicationPresentationFullScreen;
		}
		else
		{
			return NSApplicationPresentationAutoHideDock |
			NSApplicationPresentationAutoHideMenuBar |
			NSApplicationPresentationFullScreen;
		}
	}
	
	return NSApplicationPresentationDefault;
}

- (void)windowWillEnterFullScreen:(NSNotification *)notification
{
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification
{
//    [self resizeWindow];
	[self refreshLoupePanel];
	[self hideCursor];
}

- (void)windowWillExitFullScreen:(NSNotification *)notification
{
	[mouseMovedTimer invalidate];
	mouseMovedTimer = nil;
}

- (void)windowDidExitFullScreen:(NSNotification *)notification
{
	[self resizeWindow];
}

@end
