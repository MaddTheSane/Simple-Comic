/*
	Simple Comic
	TSSTEdgeBlurRenderer.h

	Renders the "blurred page edges" page-view background: the outer
	edge pixels of the page image(s) are stretched outward and heavily
	Gaussian-blurred so the background continues seamlessly past the
	page border, fading to the solid background color far from the page.

	Two separate caches, on two separate schedules:

	 - A *source* cache: small (256px) decoded page thumbnails, keyed on a
	   stable per-page identity (e.g. NSManagedObjectID) rather than on any
	   particular NSImage instance. Populated ahead of time by prefetching
	   neighboring pages (see -prepareSourceForPageKey:...), off the main
	   thread, so it's normally already warm by the time a page becomes
	   current.

	 - A *canvas* cache: the actual blurred-edge render for one page (or
	   page pair) layout, keyed on the page key(s) plus their relative
	   geometry and the fallback color. Building a canvas from already-
	   cached sources is fast (a few ms of Core Image work on tiny inputs),
	   so this happens synchronously, on demand, right in -drawRect:.
*/

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSSTEdgeBlurRenderer : NSObject

/*! Shared renderer instance backed by a single CIContext. */
+ (instancetype)sharedRenderer;

/*!	How far the returned canvas extends past the union of the page rects,
	as a multiple of that union's width/height on each side. The canvas
	is therefore (1 + 2 * canvasPadding) times the union's size in each
	dimension (6x, at the default 2.5). */
+ (CGFloat)canvasPadding;

/*! Whether a decoded source image is already cached for `pageKey`. */
- (BOOL)hasSourceForPageKey:(id)pageKey;

/*!	Ensures a small decoded source image is cached for `pageKey`, for later,
	synchronous use by `-canvasImageForFirstPageKey:...` below. No-ops (and
	calls `completion` immediately, on the main queue) if a source is
	already cached for this key. Concurrent prepares for the same key are
	de-duplicated rather than redone.

	If `thumbnailData` is non-nil, it's decoded directly -- cheap, and it
	never touches anything beyond the data itself off the calling thread.
	If it's nil, `pageImageProvider` is invoked, off the main thread, to
	produce one; give it something that follows the app's existing off-
	main thumbnail-generation precedent (see how TSSTThumbnailItemView
	calls `page.thumbnail` directly from a background queue) rather than
	inventing a new way to touch a managed object off the main thread.

	`completion`, if given, is always called, on the main queue, once the
	prepare attempt (successful or not) finishes. */
- (void)prepareSourceForPageKey:(id)pageKey
				  thumbnailData:(nullable NSData *)thumbnailData
			  pageImageProvider:(nullable NSImage * (^)(void))pageImageProvider
					 completion:(nullable void (^)(void))completion;

/*!	Synchronous, and fast (a few ms) when it can proceed at all: builds (or
	returns a cached) blurred-edge canvas for the given page layout purely
	from already-cached sources. Returns nil -- a plain cache miss, never a
	blocking render -- unless a source is already cached (via
	`-prepareSourceForPageKey:...` above) for `firstPageKey`, and for
	`secondPageKey` too when it's non-nil.

	`firstRect`/`secondRect` are the (already centered) rects the page
	images are drawn into, in the caller's coordinate space -- used only to
	determine the pages' union and their relative layout within it; the
	returned image does not depend on where that union sits, or on the
	view/window size. `secondPageKey`/`secondRect` may be omitted when
	there is no second page. `fallbackColor` fills any gap between two
	pages and shows through where no page image is available.

	The returned canvas covers the union of the two (untransformed) rects
	expanded by `canvasPadding` on each side; position it accordingly.

	Returns a CGImageRef the caller does not own (autoreleased/cached);
	do not CGImageRelease it. */
- (nullable CGImageRef)canvasImageForFirstPageKey:(id)firstPageKey
										 firstRect:(NSRect)firstRect
									 secondPageKey:(nullable id)secondPageKey
										secondRect:(NSRect)secondRect
									 fallbackColor:(NSColor *)fallbackColor;

@end

NS_ASSUME_NONNULL_END
