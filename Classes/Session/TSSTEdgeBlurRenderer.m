/*
	Simple Comic
	TSSTEdgeBlurRenderer.m
*/

#import "TSSTEdgeBlurRenderer.h"
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>

// The working canvas normalizes the page union's long side to this many
// pixels, keeping the blur cost bounded regardless of window/page size.
static const CGFloat kWorkingLongSide = 256.0;

static const CGFloat kBlurRadiusFraction = 0.05; // of the (working-space) union height
static const CGFloat kMinBlurRadius = 4.0;

// The returned canvas extends this many multiples of the union's width/height
// past it on each side, so the canvas is (1 + 2*P) = 6x the union's size.
static const CGFloat kCanvasPadding = 2.5;

// The blur is left untouched out to this many multiples of U past its edge;
// beyond that (and out to kCanvasPadding, the canvas edge) it fades smoothly
// to the solid fallback color, reaching it exactly at the canvas edge so
// there is no seam against the view's solid layer.backgroundColor beyond.
static const CGFloat kFadeStartMultiple = 1.5;

// Cache entries are rounded to this many decimal places for the relative
// (union-normalized) rects so a sub-pixel resize doesn't invalidate the cache.
static const CGFloat kRelativeRectPrecision = 1000.0; // 3 decimal places

static const NSUInteger kMaxCanvasCacheEntries = 4;
static const NSUInteger kMaxSourceCacheEntries = 32;


static BOOL keysEqual(id a, id b)
{
	return a == b || [a isEqual: b];
}


// Identifies one page (or page pair) layout: what determines the rendered
// canvas, and nothing else (not the view/window bounds).
@interface TSSTEdgeBlurCanvasKey : NSObject
@property (nonatomic, strong) id firstPageKey;
@property (nonatomic, strong, nullable) id secondPageKey;
@property (nonatomic) NSRect relativeFirstRect;
@property (nonatomic) NSRect relativeSecondRect;
@property (nonatomic, strong) NSColor * fallbackColor;
@end

@implementation TSSTEdgeBlurCanvasKey

- (BOOL)isEqual:(id)other
{
	if(self == other)
	{
		return YES;
	}
	if(![other isKindOfClass: [TSSTEdgeBlurCanvasKey class]])
	{
		return NO;
	}
	TSSTEdgeBlurCanvasKey * o = (TSSTEdgeBlurCanvasKey *)other;
	return keysEqual(self.firstPageKey, o.firstPageKey)
		&& keysEqual(self.secondPageKey, o.secondPageKey)
		&& NSEqualRects(self.relativeFirstRect, o.relativeFirstRect)
		&& NSEqualRects(self.relativeSecondRect, o.relativeSecondRect)
		&& [self.fallbackColor isEqual: o.fallbackColor];
}

@end


@interface TSSTEdgeBlurCanvasCacheEntry : NSObject
@property (nonatomic, strong) TSSTEdgeBlurCanvasKey * key;
@property (nonatomic) CGImageRef image;
@end

@implementation TSSTEdgeBlurCanvasCacheEntry
- (void)dealloc
{
	if(_image)
	{
		CGImageRelease(_image);
	}
}
@end


@implementation TSSTEdgeBlurRenderer
{
	CIContext * _context;

	NSCache<id, NSImage *> * _sourceCache; // pageKey -> small (256px) decoded thumbnail
	NSMutableDictionary<id<NSCopying>, NSMutableArray<void (^)(void)> *> * _inFlightWaiters; // pageKey -> completions, guarded by _lock

	NSMutableArray<TSSTEdgeBlurCanvasCacheEntry *> * _canvasCache; // most-recently-used first, guarded by _lock

	NSLock * _lock;
	dispatch_queue_t _prepareQueue; // private, serial, QOS_CLASS_USER_INITIATED
}

+ (instancetype)sharedRenderer
{
	static TSSTEdgeBlurRenderer * shared = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		shared = [[self alloc] init];
	});
	return shared;
}


+ (CGFloat)canvasPadding
{
	return kCanvasPadding;
}


- (instancetype)init
{
	if((self = [super init]))
	{
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		if(device)
		{
			_context = [CIContext contextWithMTLDevice: device];
		}
		else
		{
			_context = [CIContext context];
		}

		_sourceCache = [NSCache new];
		_sourceCache.countLimit = kMaxSourceCacheEntries;
		_inFlightWaiters = [NSMutableDictionary dictionary];

		_canvasCache = [NSMutableArray arrayWithCapacity: kMaxCanvasCacheEntries];
		_lock = [NSLock new];

		dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
		_prepareQueue = dispatch_queue_create("com.simplecomic.TSSTEdgeBlurRenderer.prepare", attr);

		// Core Image/Metal pay a one-time filter-graph compilation cost the
		// first time this exact chain (gradient ramps, multiply, gaussian
		// blur, mask-to-alpha, blend-with-mask) actually renders -- on the
		// order of several extra ms. Pay that cost here, off the main
		// thread, at renderer construction, instead of on the main thread
		// during the first real -drawRect:.
		__weak TSSTEdgeBlurRenderer * weakSelf = self;
		dispatch_async(_prepareQueue, ^{
			TSSTEdgeBlurRenderer * strongSelf = weakSelf;
			if(!strongSelf)
			{
				return;
			}
			// Sized like a real (256px-capped) page thumbnail, at a real
			// portrait-page-ish aspect ratio, so the warm-up exercises the
			// same kernel specializations a real first page will need --
			// a too-small/degenerate dummy (e.g. 8x8) only partially primes
			// the pipeline, leaving a smaller but still-visible one-time
			// cost on the first real call.
			NSImage * dummy = [[NSImage alloc] initWithSize: NSMakeSize(166, 256)];
			[dummy lockFocus];
			[NSColor.blackColor set];
			NSRectFill(NSMakeRect(0, 0, 166, 256));
			[dummy unlockFocus];
			CGImageRef warm = [strongSelf renderCanvasWithFirstSource: dummy
															 firstRect: NSMakeRect(0, 0, 650, 1000)
														  secondSource: nil
															secondRect: NSZeroRect
														 fallbackColor: NSColor.blackColor];
			if(warm)
			{
				CGImageRelease(warm);
			}
		});
	}
	return self;
}


#pragma mark - Source cache

- (BOOL)hasSourceForPageKey:(id)pageKey
{
	if(!pageKey)
	{
		return NO;
	}
	return [_sourceCache objectForKey: pageKey] != nil;
}


- (void)prepareSourceForPageKey:(id)pageKey
				  thumbnailData:(nullable NSData *)thumbnailData
			  pageImageProvider:(nullable NSImage * (^)(void))pageImageProvider
					 completion:(nullable void (^)(void))completion
{
	if(!pageKey || [self hasSourceForPageKey: pageKey])
	{
		if(completion)
		{
			dispatch_async(dispatch_get_main_queue(), completion);
		}
		return;
	}

	// Concurrent prepares for one key share a single decode; later callers
	// just queue their completion behind it.
	[_lock lock];
	NSMutableArray<void (^)(void)> * waiters = _inFlightWaiters[pageKey];
	BOOL alreadyInFlight = (waiters != nil);
	if(!alreadyInFlight)
	{
		waiters = [NSMutableArray array];
		_inFlightWaiters[pageKey] = waiters;
	}
	if(completion)
	{
		[waiters addObject: [completion copy]];
	}
	[_lock unlock];

	if(alreadyInFlight)
	{
		return;
	}

	__weak TSSTEdgeBlurRenderer * weakSelf = self;
	dispatch_async(_prepareQueue, ^{
		TSSTEdgeBlurRenderer * strongSelf = weakSelf;
		if(!strongSelf)
		{
			return;
		}

		NSImage * smallImage = nil;
		if(thumbnailData)
		{
			smallImage = [[NSImage alloc] initWithData: thumbnailData];
		}
		else if(pageImageProvider)
		{
			smallImage = pageImageProvider();
		}
		if(smallImage)
		{
			[strongSelf->_sourceCache setObject: smallImage forKey: pageKey];
		}

		[strongSelf->_lock lock];
		NSArray<void (^)(void)> * finished = strongSelf->_inFlightWaiters[pageKey];
		[strongSelf->_inFlightWaiters removeObjectForKey: pageKey];
		[strongSelf->_lock unlock];

		if(finished.count > 0)
		{
			dispatch_async(dispatch_get_main_queue(), ^{
				for(void (^callback)(void) in finished)
				{
					callback();
				}
			});
		}
	});
}


#pragma mark - Canvas rendering

// clampedToExtent misbehaves (transparent/white fringe) when the extent has
// fractional origin or size, so every rect that feeds clampedToExtent gets
// rounded to whole pixels first.
static CGRect integralRect(CGRect rect)
{
	CGFloat minX = floor(CGRectGetMinX(rect));
	CGFloat minY = floor(CGRectGetMinY(rect));
	CGFloat maxX = ceil(CGRectGetMaxX(rect));
	CGFloat maxY = ceil(CGRectGetMaxY(rect));
	return CGRectMake(minX, minY, maxX - minX, maxY - minY);
}


// `rect` expressed in the working space: shifted so `unionRect` starts at the
// origin, scaled, and snapped to whole pixels.
static CGRect workingRect(CGRect rect, CGRect unionRect, CGFloat scale)
{
	CGRect zeroed = CGRectOffset(rect, -unionRect.origin.x, -unionRect.origin.y);
	return integralRect(CGRectMake(zeroed.origin.x * scale, zeroed.origin.y * scale,
								   zeroed.size.width * scale, zeroed.size.height * scale));
}


static CGFloat roundedToPrecision(CGFloat value)
{
	return round(value * kRelativeRectPrecision) / kRelativeRectPrecision;
}


// Expresses `rect` as a fraction of `unionRect` (origin/size normalized to
// 0...1), rounded to a few decimal places -- this is what the cache is
// actually keyed on, so it is invariant to the union's absolute position,
// scale, and the view/window size.
static NSRect relativeRect(CGRect rect, CGRect unionRect)
{
	if(unionRect.size.width <= 0 || unionRect.size.height <= 0)
	{
		return NSZeroRect;
	}
	return NSMakeRect(roundedToPrecision((rect.origin.x - unionRect.origin.x) / unionRect.size.width),
					   roundedToPrecision((rect.origin.y - unionRect.origin.y) / unionRect.size.height),
					   roundedToPrecision(rect.size.width / unionRect.size.width),
					   roundedToPrecision(rect.size.height / unionRect.size.height));
}


static CGImageRef createDownsampledCGImage(CGImageRef source, CGSize targetPixelSize)
{
	size_t width = (size_t)MAX(1, llround(targetPixelSize.width));
	size_t height = (size_t)MAX(1, llround(targetPixelSize.height));

	CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGContextRef bitmapContext = CGBitmapContextCreate(NULL, width, height, 8, 0, colorSpace, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
	CGColorSpaceRelease(colorSpace);
	if(!bitmapContext)
	{
		return NULL;
	}

	CGContextSetInterpolationQuality(bitmapContext, kCGInterpolationMedium);
	CGContextDrawImage(bitmapContext, CGRectMake(0, 0, width, height), source);
	CGImageRef small = CGBitmapContextCreateImage(bitmapContext);
	CGContextRelease(bitmapContext);
	return small;
}


- (nullable CIImage *)scaledSourceImage:(NSImage *)image targetRect:(CGRect)targetRect
{
	if(CGRectIsEmpty(targetRect))
	{
		return nil;
	}

	NSRect proposedRect = NSMakeRect(0, 0, image.size.width, image.size.height);
	CGImageRef cgImage = [image CGImageForProposedRect: &proposedRect context: nil hints: nil];
	if(!cgImage)
	{
		return nil;
	}

	// `image` here is already a small (256px) page thumbnail, so this is a
	// cheap, small resize -- kept anyway for uniform behavior regardless of
	// what the source cache happens to hold.
	CGSize smallSize = CGSizeMake(targetRect.size.width * 2.0, targetRect.size.height * 2.0);
	CGImageRef smallImage = createDownsampledCGImage(cgImage, smallSize);

	CIImage * source;
	if(smallImage)
	{
		source = [CIImage imageWithCGImage: smallImage];
		CGImageRelease(smallImage);
	}
	else
	{
		source = [CIImage imageWithCGImage: cgImage];
	}

	CGFloat sx = targetRect.size.width / source.extent.size.width;
	CGFloat sy = targetRect.size.height / source.extent.size.height;
	CGAffineTransform transform = CGAffineTransformMakeScale(sx, sy);
	transform = CGAffineTransformConcat(transform, CGAffineTransformMakeTranslation(targetRect.origin.x, targetRect.origin.y));
	return [source imageByApplyingTransform: transform];
}


// A smoothstep ramp along the line from `from` to `to` (both x, or both y,
// with the other coordinate irrelevant): `fromValue` before `from`, `toValue`
// after `to`, smoothstep between. Used to build one edge of the fade mask.
- (CIImage *)rampFromPoint:(CGPoint)from toPoint:(CGPoint)to fromValue:(CGFloat)fromValue toValue:(CGFloat)toValue
{
	CIFilter * gradient = [CIFilter filterWithName: @"CISmoothLinearGradient"];
	[gradient setValue: [CIVector vectorWithCGPoint: from] forKey: @"inputPoint0"];
	[gradient setValue: [CIVector vectorWithCGPoint: to] forKey: @"inputPoint1"];
	[gradient setValue: [CIColor colorWithRed: fromValue green: fromValue blue: fromValue alpha: 1] forKey: @"inputColor0"];
	[gradient setValue: [CIColor colorWithRed: toValue green: toValue blue: toValue alpha: 1] forKey: @"inputColor1"];
	return gradient.outputImage;
}


- (CIImage *)multiply:(CIImage *)image by:(CIImage *)other
{
	CIFilter * multiply = [CIFilter filterWithName: @"CIMultiplyBlendMode"];
	[multiply setValue: image forKey: kCIInputImageKey];
	[multiply setValue: other forKey: kCIInputBackgroundImageKey];
	return multiply.outputImage;
}


// Builds an infinite-extent alpha mask (in the same working-space coordinates
// as `workingUnion`) that is fully opaque (1) out to kFadeStartMultiple * U
// past each edge of `workingUnion`, smoothstep-fades to fully transparent (0)
// by kCanvasPadding * U past that edge, and stays 0 beyond. Multiplying the
// independent horizontal and vertical ramps gives a separable approximation
// of a feathered inset rect, per side.
- (CIImage *)fadeMaskForWorkingUnion:(CGRect)workingUnion
{
	CGFloat marginX = workingUnion.size.width;
	CGFloat marginY = workingUnion.size.height;
	CGFloat minX = CGRectGetMinX(workingUnion);
	CGFloat maxX = CGRectGetMaxX(workingUnion);
	CGFloat minY = CGRectGetMinY(workingUnion);
	CGFloat maxY = CGRectGetMaxY(workingUnion);

	CIImage * leftRamp = [self rampFromPoint: CGPointMake(minX - kCanvasPadding * marginX, 0)
									  toPoint: CGPointMake(minX - kFadeStartMultiple * marginX, 0)
									fromValue: 0 toValue: 1];
	CIImage * rightRamp = [self rampFromPoint: CGPointMake(maxX + kFadeStartMultiple * marginX, 0)
									   toPoint: CGPointMake(maxX + kCanvasPadding * marginX, 0)
									 fromValue: 1 toValue: 0];
	CIImage * bottomRamp = [self rampFromPoint: CGPointMake(0, minY - kCanvasPadding * marginY)
										toPoint: CGPointMake(0, minY - kFadeStartMultiple * marginY)
									  fromValue: 0 toValue: 1];
	CIImage * topRamp = [self rampFromPoint: CGPointMake(0, maxY + kFadeStartMultiple * marginY)
									 toPoint: CGPointMake(0, maxY + kCanvasPadding * marginY)
								   fromValue: 1 toValue: 0];

	CIImage * horizontalMask = [self multiply: leftRamp by: rightRamp];
	CIImage * verticalMask = [self multiply: bottomRamp by: topRamp];
	CIImage * grayMask = [self multiply: horizontalMask by: verticalMask];

	CIFilter * toAlpha = [CIFilter filterWithName: @"CIMaskToAlpha"];
	[toAlpha setValue: grayMask forKey: kCIInputImageKey];
	return toAlpha.outputImage;
}


// The actual (cheap, given small sources) Core Image work. No caching here;
// the caller owns the canvas cache.
- (nullable CGImageRef)renderCanvasWithFirstSource:(NSImage *)firstSource
										  firstRect:(NSRect)firstRect
									   secondSource:(nullable NSImage *)secondSource
										 secondRect:(NSRect)secondRect
									  fallbackColor:(NSColor *)fallbackColor
{
	CGRect unionRect = secondSource ? CGRectUnion(firstRect, secondRect) : firstRect;
	if(unionRect.size.width <= 0 || unionRect.size.height <= 0)
	{
		return NULL;
	}

	// Normalize U's long side to a fixed working size, independent of the
	// view/window: everything below is in this page-relative working space.
	CGFloat scale = kWorkingLongSide / MAX(unionRect.size.width, unionRect.size.height);

	CGRect scaledFirstRect = workingRect(firstRect, unionRect, scale);
	CGRect scaledSecondRect = secondSource ? workingRect(secondRect, unionRect, scale) : CGRectNull;

	CGRect workingUnion = secondSource ? CGRectUnion(scaledFirstRect, scaledSecondRect) : scaledFirstRect;

	CIColor * ciFallback = [CIColor colorWithCGColor: fallbackColor.CGColor];
	CIImage * composite = [[CIImage imageWithColor: ciFallback] imageByCroppingToRect: workingUnion];

	CIImage * firstScaled = [self scaledSourceImage: firstSource targetRect: scaledFirstRect];
	if(firstScaled)
	{
		composite = [firstScaled imageByCompositingOverImage: composite];
	}
	if(secondSource)
	{
		CIImage * secondScaled = [self scaledSourceImage: secondSource targetRect: scaledSecondRect];
		if(secondScaled)
		{
			composite = [secondScaled imageByCompositingOverImage: composite];
		}
	}

	// Crop back to the opaque fill so resampled page edges can't leave
	// translucent border pixels for the clamp to smear outward.
	CIImage * clamped = [[composite imageByCroppingToRect: workingUnion] imageByClampingToExtent];

	CGFloat blurRadius = MAX(kMinBlurRadius, kBlurRadiusFraction * workingUnion.size.height);
	CIFilter * blurFilter = [CIFilter filterWithName: @"CIGaussianBlur"];
	[blurFilter setValue: clamped forKey: kCIInputImageKey];
	[blurFilter setValue: @(blurRadius) forKey: kCIInputRadiusKey];
	CIImage * blurred = blurFilter.outputImage;

	// Fade the blur out to the exact fallback color by the canvas edge, so
	// there is no seam against the view's solid layer.backgroundColor beyond.
	CIImage * fadeMask = [self fadeMaskForWorkingUnion: workingUnion];
	CIImage * fallbackPlane = [CIImage imageWithColor: ciFallback];
	CIFilter * blendFilter = [CIFilter filterWithName: @"CIBlendWithMask"];
	[blendFilter setValue: blurred forKey: kCIInputImageKey];
	[blendFilter setValue: fallbackPlane forKey: kCIInputBackgroundImageKey];
	[blendFilter setValue: fadeMask forKey: kCIInputMaskImageKey];
	CIImage * faded = blendFilter.outputImage;

	CGFloat padX = kCanvasPadding * workingUnion.size.width;
	CGFloat padY = kCanvasPadding * workingUnion.size.height;
	CGRect canvasRect = integralRect(CGRectInset(workingUnion, -padX, -padY));

	CIImage * cropped = [faded imageByCroppingToRect: canvasRect];

	CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGImageRef rendered = [_context createCGImage: cropped fromRect: canvasRect format: kCIFormatRGBA8 colorSpace: colorSpace];
	CGColorSpaceRelease(colorSpace);

	return rendered;
}


// Returns the cached entry for `key` and marks it most recently used.
// Caller holds _lock.
- (nullable TSSTEdgeBlurCanvasCacheEntry *)touchCanvasEntryForKey:(TSSTEdgeBlurCanvasKey *)key
{
	NSUInteger index = [_canvasCache indexOfObjectPassingTest: ^BOOL(TSSTEdgeBlurCanvasCacheEntry * entry, NSUInteger idx, BOOL * stop) {
		return [entry.key isEqual: key];
	}];
	if(index == NSNotFound)
	{
		return nil;
	}
	TSSTEdgeBlurCanvasCacheEntry * entry = _canvasCache[index];
	[_canvasCache removeObjectAtIndex: index];
	[_canvasCache insertObject: entry atIndex: 0];
	return entry;
}


- (nullable CGImageRef)canvasImageForFirstPageKey:(id)firstPageKey
										 firstRect:(NSRect)firstRect
									 secondPageKey:(nullable id)secondPageKey
										secondRect:(NSRect)secondRect
									 fallbackColor:(NSColor *)fallbackColor
{
	if(!firstPageKey || CGRectIsEmpty(firstRect))
	{
		return NULL;
	}

	NSImage * firstSource = [_sourceCache objectForKey: firstPageKey];
	if(!firstSource)
	{
		return NULL;
	}

	NSImage * secondSource = nil;
	if(secondPageKey)
	{
		secondSource = [_sourceCache objectForKey: secondPageKey];
		if(!secondSource)
		{
			// Both-or-nothing: don't show a half-blurred spread while the
			// other half is still prepping.
			return NULL;
		}
	}
	else
	{
		secondRect = NSZeroRect;
	}

	CGRect unionRect = secondSource ? CGRectUnion(firstRect, secondRect) : firstRect;
	if(unionRect.size.width <= 0 || unionRect.size.height <= 0)
	{
		return NULL;
	}

	TSSTEdgeBlurCanvasKey * key = [TSSTEdgeBlurCanvasKey new];
	key.firstPageKey = firstPageKey;
	key.secondPageKey = secondPageKey;
	key.relativeFirstRect = relativeRect(firstRect, unionRect);
	key.relativeSecondRect = secondSource ? relativeRect(secondRect, unionRect) : NSZeroRect;
	key.fallbackColor = fallbackColor;

	[_lock lock];
	TSSTEdgeBlurCanvasCacheEntry * cachedEntry = [self touchCanvasEntryForKey: key];
	[_lock unlock];
	if(cachedEntry)
	{
		return cachedEntry.image;
	}

	CGImageRef rendered = [self renderCanvasWithFirstSource: firstSource firstRect: firstRect secondSource: secondSource secondRect: secondRect fallbackColor: fallbackColor];
	if(!rendered)
	{
		return NULL;
	}

	// Another thread may have rendered the same canvas meanwhile; keep theirs.
	[_lock lock];
	TSSTEdgeBlurCanvasCacheEntry * existing = [self touchCanvasEntryForKey: key];
	if(existing)
	{
		CGImageRelease(rendered);
		rendered = existing.image;
	}
	else
	{
		TSSTEdgeBlurCanvasCacheEntry * entry = [TSSTEdgeBlurCanvasCacheEntry new];
		entry.key = key;
		entry.image = rendered; // entry takes ownership of the +1 from createCGImage
		[_canvasCache insertObject: entry atIndex: 0];
		while(_canvasCache.count > kMaxCanvasCacheEntries)
		{
			[_canvasCache removeLastObject];
		}
	}
	[_lock unlock];

	return rendered;
}

@end
