//  OCRTracker.m
//  MockSimpleComic
//
//  Created by David Phillip Oster on 5/21/2022 Apache Version 2 open source license.
//

#import "OCRTracker.h"

#import "OCRSelectionLayer.h"
#import "OCRVision.h"
#import <Vision/Vision.h>

/// @return the quadrilateral of the rect observation as a NSBezierPath/
API_AVAILABLE(macos(10.15))
static NSBezierPath *OCRBezierPathFromRectObservation(VNRectangleObservation *piece)
{
	NSBezierPath *path = [NSBezierPath bezierPath];
	[path moveToPoint:piece.topLeft];
	[path lineToPoint:piece.topRight];
	[path lineToPoint:piece.bottomRight];
	[path lineToPoint:piece.bottomLeft];
	[path closePath];
	return path;
}

/// @param piece - the TextObservation
/// @param r - the range of the string of the TextObservation
/// @return the quadrilateral of the text observation as a NSBezierPath/
API_AVAILABLE(macos(10.15))
NSBezierPath *OCRBezierPathFromTextObservationRange(VNRecognizedTextObservation *piece, NSRange r)
{
	VNRecognizedText *recognizedText = [[piece topCandidates:1] firstObject];
	// VNRectangleObservation is a superclass of VNRecognizedTextObservation. On error, use the whole thing.
	VNRectangleObservation *rect = [recognizedText boundingBoxForRange:r error:NULL] ?: piece;
	return OCRBezierPathFromRectObservation(rect);
}


/// @return the NSRect from two points.
static NSRect RectFrom2Points(NSPoint a, NSPoint b)
{
	return CGRectStandardize(NSMakeRect(a.x, a.y, b.x - a.x, b.y - a.y));
}

/// @return the set of indices into a string such that s[index] is at the near the beginning or end of a whitespace delimited 'word'
static NSIndexSet *WordsBoundariesOfString(NSString *s)
{
	NSMutableIndexSet *indicies = [NSMutableIndexSet indexSetWithIndex:0];
	[indicies addIndex:s.length];
	NSScanner *scanner = [[NSScanner alloc] initWithString:s];
	NSCharacterSet *textChars = [[NSCharacterSet whitespaceAndNewlineCharacterSet] invertedSet];
	while ([scanner scanCharactersFromSet:textChars intoString:NULL])
	{
		[indicies addIndex:scanner.scanLocation];
	}
	return indicies;
}

/// Given two ranges in order, early before late
/// @return a continguous range that spans from early to late.
static NSRange UnionRanges(NSRange early, NSRange late)
{
	return NSMakeRange(early.location, late.length+late.location - early.location);
}


static NSSpeechSynthesizer *sSpeechSynthesizer;

/// Bundle up all the data associated with our client's image.
@interface OCRDatum : NSObject

@property(weak) NSImage *image;

@property(weak) CALayer *selectionLayer;

/// <VNRecognizedTextObservation *> - 10.15 and newer
@property NSArray *textPieces;

// Key is VNRecognizedTextObservation.
// The value is the NSRange of the underlying string to show as selected.
@property NSMutableDictionary<NSObject *, NSValue *> *selectionPieces;
@end

@implementation OCRDatum
@end

@interface OCRTracker()
@property BOOL isDragging;

@property NSArray<OCRDatum *> *datums;

@property (weak, nullable) NSView *view;

@end

@implementation OCRTracker

- (instancetype)initWithView:(NSView *)view
{
	self = [super init];
	if (self)
	{
		_view = view;
		_datums = @[
			[[OCRDatum alloc] init],
			[[OCRDatum alloc] init],
		];
	}
	return self;
}

- (void)becomeNextResponder {
	if (self.view.nextResponder != self)
	{
		self.nextResponder = self.view.nextResponder;
		self.view.nextResponder = self;
	}
}

- (BOOL)acceptsFirstResponder
{
  return YES;
}

- (OCRDatum *)datumOfImage:(NSImage *)image
{
	for (OCRDatum *datum in self.datums) {
		if (datum.image == image) {
			return datum;
		}
	}
	return nil;
}

- (BOOL)isAnySelected {
	for (OCRDatum *datum in self.datums)
	{
		if (datum.image != nil && datum.selectionPieces.count != 0)
		{
			return YES;
		}
	}
	return NO;
}

- (NSInteger)totalTextPiecesCount
{
	NSInteger total = 0;
	for (OCRDatum *datum in self.datums)
	{
		if (datum.image != nil) {
			total += datum.textPieces.count;
		}
	}
	return total;
}

- (NSInteger)totalSelectionPiecesCount
{
	NSInteger total = 0;
	for (OCRDatum *datum in self.datums)
	{
		if (datum.image != nil) {
			total += datum.selectionPieces.count;
		}
	}
	return total;
}

- (void)addSelectionPiecesFromDictionary:(NSDictionary *)previousSelection API_AVAILABLE(macos(10.15))
{
	for (VNRecognizedTextObservation *textPiece in previousSelection.allKeys)
	{
		for (OCRDatum *datum in self.datums)
		{
			if (datum.image != nil && [datum.textPieces containsObject:textPiece]) {
				datum.selectionPieces[textPiece] = previousSelection[textPiece];
				break;
			}
		}
	}
}


/// @return a layer of the selection for image scaled to frame.
- (nullable CALayer *)layerForImage:(NSImage *)image imageLayer:(CALayer *)imageLayer {
	CALayer *layer = nil;
	if (@available(macOS 10.15, *))
	{
		OCRDatum *datum = [self datumOfImage:image];
		if (datum.image != nil && datum.textPieces != nil)
		{
			OCRSelectionLayer *selectionLayer =  [[OCRSelectionLayer alloc] initWithObservations:datum.textPieces selection:datum.selectionPieces imageLayer:imageLayer];
			datum.selectionLayer = selectionLayer;
			return selectionLayer;
		}
	}
	return layer;
}

#pragma mark Model

- (NSString *)allText
{
	if (@available(macOS 10.15, *))
	{
		NSMutableArray *a = [NSMutableArray array];
		for (OCRDatum *datum in self.datums)
		{
			if (datum.image != nil)
			{
				for (VNRecognizedTextObservation *piece in datum.textPieces)
				{
					NSArray<VNRecognizedText *> *text1 = [piece topCandidates:1];
					[a addObject:text1.firstObject.string];
				}
			}
		}
		return [a componentsJoinedByString:@"\n"];
	}
	return nil;
}

- (NSString *)selection
{
	NSMutableArray *a = [NSMutableArray array];
	if (@available(macOS 10.15, *))
	{
		for (OCRDatum *datum in self.datums)
		{
			if (datum.image != nil)
			{
				for (VNRecognizedTextObservation *piece in datum.textPieces)
				{
					NSValue *rangeInAValue = datum.selectionPieces[piece];
					if (rangeInAValue != nil)
					{
						NSArray<VNRecognizedText *> *text1 = [piece topCandidates:1];
						NSString *s = text1.firstObject.string;
						s = [s substringWithRange:[rangeInAValue rangeValue]];
						[a addObject:s];
					}
				}
			}
		}
	}
	return [a componentsJoinedByString:@"\n"];
}

- (nullable VNRecognizedTextObservation *)textPieceForMouseEvent:(NSEvent *)theEvent API_AVAILABLE(macos(10.15))
{
	NSPoint where = [self.view convertPoint:[theEvent locationInWindow] fromView:nil];
	return [self textPieceForPoint:where];
}

/// For a point, find the textPiece
///
/// @param where - a point in View coordinates,
/// @return the textPiece that contains that point
- (nullable VNRecognizedTextObservation *)textPieceForPoint:(CGPoint)where API_AVAILABLE(macos(10.15))
{
	if (@available(macOS 10.15, *))
	{
		for (OCRDatum *datum in self.datums)
		{
			if (datum.image != nil && datum.textPieces)
			{
				CGRect container = [[[self view] enclosingScrollView] documentVisibleRect];
				CGSize imageSize = datum.selectionLayer.bounds.size;
				for (VNRecognizedTextObservation *piece in datum.textPieces)
				{
					CGRect r = VNImageRectForNormalizedRect(piece.boundingBox, imageSize.width, imageSize.height);
					r = [datum.selectionLayer convertRect:r toLayer:self.view.layer];
					r = CGRectIntersection(r, container);
					if (!CGRectIsEmpty(r) && CGRectContainsPoint(r, where))
					{
						return piece;
					}
				}
			}
		}
	}
	return nil;
}

/// Return the boundbox of a range of a piece in View coordinates
///
/// @param piece - A text piece
/// @param charRange - the range within the piece.
/// @return The bound box in VNRecognizedTextObservation coordinates
- (CGRect)boundBoxOfPiece:(VNRecognizedTextObservation *)piece range:(NSRange)charRange API_AVAILABLE(macos(10.15))
{
	VNRecognizedText *text1 = [[piece topCandidates:1] firstObject];
	NSString *s1 = text1.string;
	if (s1.length < charRange.location + charRange.length)
	{
		return CGRectNull;
	}

	NSBezierPath *path = OCRBezierPathFromTextObservationRange(piece, charRange);
	return path.bounds;
}


#pragma mark OCR

/// Housekeeping around being called by the OCR engine.
///
///  Since this will affect the U.I., sets state on the main thread.
/// @param results -  the OCR's results object.
- (void)ocrDidFinish:(id<OCRVisionResults>)results image:(NSImage *)image index:(NSInteger)index
{
	NSArray *textPieces = @[];
	if (@available(macOS 10.15, *)) {
		textPieces = results.textObservations;
	}
	// Since we are changing state that affects the U.I., we do it on the main thread in the future,
	// but `complete` isn't guaranteed to exist then, so we assign to locals so it will be captured
	// by the block.
	dispatch_async(dispatch_get_main_queue(), ^{
		OCRDatum *datum = self.datums[index];
		datum.image = image;
		datum.textPieces = textPieces;
		[datum.selectionPieces removeAllObjects];
		[self.view setNeedsDisplay:YES];
		[self.view.window invalidateCursorRectsForView:self.view];
	});
}

- (void)ocrImage:(NSImage *)image index:(NSInteger)index
{
	if (@available(macOS 10.15, *)) {
		OCRDatum *datum = self.datums[index];
		datum.image = nil;
		datum.textPieces = @[];
		[datum.selectionPieces removeAllObjects];
		if (image)
		{
			__block OCRVision *ocrVision = [[OCRVision alloc] init];
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
				[ocrVision ocrImage:image completion:^(id<OCRVisionResults> _Nonnull complete) {
					[self ocrDidFinish:complete image:image index:index];
					ocrVision = nil;
				}];
			});
		}
	}
}

- (void)ocrImage:(NSImage *)image
{
	[self ocrImage:image index:0];
}

- (void)ocrImage2:(NSImage *)image
{
	[self ocrImage:image index:1];
}


#pragma mark Mouse

- (BOOL)didMouseDown:(NSEvent *)theEvent
{
	NSObject *textPiece = nil;
	if (@available(macOS 10.15, *)) {
		textPiece = [self textPieceForMouseEvent:theEvent];
	}
	BOOL isDoingMouseDown = (textPiece != nil);
	if (isDoingMouseDown)
	{
		[self mouseDown:theEvent textPiece:textPiece];
	}
	else if (!(theEvent.modifierFlags & NSEventModifierFlagCommand) && self.isAnySelected)
	{
		// click not in text selection. Clear the selection.
		for (OCRDatum *datum in self.datums)
		{
			[datum.selectionPieces removeAllObjects];
		}
		[self.view setNeedsDisplay:YES];
	}
	return isDoingMouseDown;
}

- (void)mouseDown:(NSEvent *)theEvent textPiece:(NSObject *)textPiece
{
	NSInteger i = 0;
	NSValue *rangeValue = nil;
	for (;i < self.datums.count; ++i) {
		OCRDatum *datum = self.datums[i];
		rangeValue = datum.selectionPieces[textPiece];
		if (datum.image != nil && rangeValue != nil)
		{
			break;
		}
	}
	if (rangeValue != nil && (theEvent.modifierFlags & NSEventModifierFlagControl) != 0) {
		NSMenu *theMenu = [[NSMenu alloc] initWithTitle:@"Contextual Menu"];
		[theMenu insertItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"" atIndex:0];
		[theMenu insertItem:[NSMenuItem separatorItem] atIndex:1];
		[theMenu insertItemWithTitle:@"Start Speaking" action:@selector(startSpeaking:) keyEquivalent:@"" atIndex:2];
		[theMenu insertItemWithTitle:@"Stop Speaking" action:@selector(stopSpeaking:) keyEquivalent:@"" atIndex:3];
		[NSMenu popUpContextMenu:theMenu withEvent:theEvent forView:self.view];
	} else {
		[[NSCursor IBeamCursor] set];
		if (!(theEvent.modifierFlags & NSEventModifierFlagCommand))
		{
			for (OCRDatum *datum in self.datums)
			{
				[datum.selectionPieces removeAllObjects];
			}
			[self.view setNeedsDisplay:YES];
		}
	}
}

- (BOOL)didMouseDragged:(NSEvent *)theEvent
{
	NSObject *textPiece = nil;
	if (@available(macOS 10.15, *)) {
		textPiece = [self textPieceForMouseEvent:theEvent];
	}
	BOOL isDoingMouseDragged = (textPiece != nil);
	if (isDoingMouseDragged)
	{
		[self mouseDrag:theEvent textPiece:textPiece];
	}
	return isDoingMouseDragged;
}

- (void)mouseDrag:(NSEvent *)theEvent textPiece:(NSObject *)textPiece
{
	NSPoint startPoint = [self.view convertPoint:[theEvent locationInWindow] fromView:nil];
	self.isDragging = YES;
	NSMutableDictionary *previousSelection = [NSMutableDictionary dictionary];
	if (theEvent.modifierFlags & NSEventModifierFlagCommand)
	{
		for (OCRDatum *datum in self.datums)
		{
			if (datum.image != nil)
			{
				[previousSelection addEntriesFromDictionary:datum.selectionPieces];
			}
		}
	}
	for (OCRDatum *datum in self.datums)
	{
		[datum.selectionPieces removeAllObjects];
	}
	if (@available(macOS 10.15, *)) {
		[self addSelectionPiecesFromDictionary:previousSelection];
	}
	while ([theEvent type] != NSEventTypeLeftMouseUp)
	{
		if ([theEvent type] == NSEventTypeLeftMouseDragged)
		{
			NSPoint endPoint = [self.view convertPoint:[theEvent locationInWindow] fromView:nil];
			NSRect downRect = RectFrom2Points(startPoint, endPoint);
			[self updateSelectionFromDownRect:downRect previousSelection:previousSelection];
		}
		theEvent = [[self.view window] nextEventMatchingMask: NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged];
	}
	[self.view.window invalidateCursorRectsForView:self.view];
	self.isDragging = NO;
}

/// @param downRect - the rectangle in view coordinates from the start mouse position to the current mouse position.
/// @param previousSelection - the selection as it was before the call to this. This method will update it.
- (void)updateSelectionFromDownRect:(NSRect)downRect previousSelection:(NSMutableDictionary *)previousSelection
{
	if (@available(macOS 10.15, *))
	{
		BOOL needsDisplay = NO;

		for (OCRDatum *datum in self.datums) {
			if (datum.image != nil)
			{
				NSMutableDictionary *selectionDict = [NSMutableDictionary dictionary];
				CGSize imageSize = datum.selectionLayer.bounds.size;
				for (VNRecognizedTextObservation *piece in datum.textPieces)
				{
					CGRect pieceR = VNImageRectForNormalizedRect(piece.boundingBox, imageSize.width, imageSize.height);
					pieceR = [datum.selectionLayer convertRect:pieceR toLayer:self.view.layer];
					if (CGRectIntersectsRect(downRect, pieceR)) {
						CGRect imageDownRect = [datum.selectionLayer convertRect:downRect fromLayer:self.view.layer];
						CGRect pieceDownRect = VNNormalizedRectForImageRect(imageDownRect, imageSize.width, imageSize.height);
						NSRange r = [self rangeOfPiece:piece intersectsRect:pieceDownRect];
						NSValue *rangePtr = previousSelection[piece];
						if (rangePtr != nil) {
							NSRange oldRange = [rangePtr rangeValue];
							r = UnionRanges(r, oldRange);
							previousSelection[piece] = nil;
						}
						selectionDict[piece] = [NSValue valueWithRange:r];
					}
				}
				[selectionDict addEntriesFromDictionary:previousSelection];
				if (![datum.selectionPieces isEqual:selectionDict]) {
					datum.selectionPieces = selectionDict;
					needsDisplay = YES;
				}

			}
		}
		if (needsDisplay)
		{
			[self.view setNeedsDisplay:YES];
			[self.view.window invalidateCursorRectsForView:self.view];
		}
	}
}

// if the start and end indices delimit a range that intersects r, return the range, else the NotFound range.
//
// @param piece - the VNRecognizedTextObservation to examine
// @param r - The rectangle, in VNRecognizedTextObservation coordinates to intersect against
// @param start - the start index into the string of the text of the piece
// @param end - the end index into the string of the text of the piece
// @return the range of the word of the piece that downRect intersects, else the NotFound range.
- (NSRange)rangeOfPiece:(VNRecognizedTextObservation *)piece intersectsRect:(NSRect)r start:(NSUInteger)start end:(NSUInteger)end  API_AVAILABLE(macos(10.15))
{
	if (0 < end - start)	// ignore zero length ranges.
	{
		NSRange wordRange = NSMakeRange(start, end - start);
		CGRect wordR = [self boundBoxOfPiece:piece range:wordRange];
		if (CGRectIntersectsRect(r, wordR))
		{
			return wordRange;
		}
	}
	return NSMakeRange(NSNotFound, 0);
}

/// @param downRect - in VNRecognizedTextObservation coordinates
// @return the first range of the word of the piece that downRect intersects, else the NotFound range.
- (NSRange)firstRangeOfPiece:(VNRecognizedTextObservation *)piece intersectsRect:(NSRect)downRect indexSet:(NSIndexSet *)wordStarts  API_AVAILABLE(macos(10.15))
{
	NSUInteger endIndex = [wordStarts indexGreaterThanIndex:0];
	NSUInteger startIndex = 0;
	for (;endIndex != NSNotFound; endIndex = [wordStarts indexGreaterThanIndex:endIndex])
	{
		NSRange wordRange = [self rangeOfPiece:piece intersectsRect:downRect start:startIndex end:endIndex];
		if (wordRange.location != NSNotFound)
		{
			return wordRange;
		}
		startIndex = endIndex;
	}
	return NSMakeRange(NSNotFound, 0);
}

/// @param downRect - in VNRecognizedTextObservation coordinates
/// @return the last range of the word of the piece that downRect intersects, else the NotFound range.
- (NSRange)lastRangeOfPiece:(VNRecognizedTextObservation *)piece intersectsRect:(NSRect)downRect indexSet:(NSIndexSet *)wordStarts  API_AVAILABLE(macos(10.15))
{
	NSUInteger endIndex = [wordStarts lastIndex];
	NSUInteger startIndex = [wordStarts indexLessThanIndex:endIndex];
	for (;startIndex != NSNotFound; startIndex = [wordStarts indexLessThanIndex:startIndex])
	{
		NSRange wordRange = [self rangeOfPiece:piece intersectsRect:downRect start:startIndex end:endIndex];
		if (wordRange.location != NSNotFound)
		{
			return wordRange;
		}
		endIndex = startIndex;
	}
	return NSMakeRange(0, NSNotFound);
}

/// @param downRect - in VNRecognizedTextObservation coordinates
/// @return the range of all of the words of the text of the piece that downRect intersects.
- (NSRange)rangeOfPiece:(VNRecognizedTextObservation *)piece intersectsRect:(NSRect)downRect API_AVAILABLE(macos(10.15))
{
	VNRecognizedText *text1 = [[piece topCandidates:1] firstObject];
	NSString *s = text1.string;
	NSIndexSet *wordStarts = WordsBoundariesOfString(s);

	NSRange first = [self firstRangeOfPiece:piece intersectsRect:downRect indexSet:wordStarts];
	NSRange last = [self lastRangeOfPiece:piece intersectsRect:downRect indexSet:wordStarts];
	if (first.location == NSNotFound || last.location == NSNotFound)
	{
		return NSMakeRange(0, s.length);
	}
	return UnionRanges(first, last);
}

- (BOOL)didResetCursorRects
{
	if (self.isDragging) {
		[self.view addCursorRect: [[[self view] enclosingScrollView] documentVisibleRect] cursor:[NSCursor IBeamCursor]];
		return YES;
	}
	else if (@available(macOS 10.15, *))
	{
		for (OCRDatum *datum in self.datums)
		{
			if (datum.image != nil && datum.textPieces.count)
			{
				CGRect container = [[[self view] enclosingScrollView] documentVisibleRect];
				CGSize imageSize = datum.selectionLayer.bounds.size;
				for (VNRecognizedTextObservation *piece in datum.textPieces)
				{
					CGRect r = VNImageRectForNormalizedRect(piece.boundingBox, imageSize.width, imageSize.height);
					r = [datum.selectionLayer convertRect:r toLayer:self.view.layer];
					r = CGRectIntersection(r, container);
					if (!CGRectIsEmpty(r))
					{
						[self.view addCursorRect:r cursor:[NSCursor IBeamCursor]];
					}
				}
			}
		}
	}
	return NO;
}

#pragma mark Menubar

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	if ([menuItem action] == @selector(copy:))
	{
		BOOL isAnySelected = self.isAnySelected;
		menuItem.title = isAnySelected ? NSLocalizedString(@"Copy Text", @"") : NSLocalizedString(@"Copy", @"");
		return isAnySelected;
	}
	else if ([menuItem action] == @selector(selectAll:))
	{
		if (@available(macOS 10.15, *))
		{
			return self.totalTextPiecesCount != 0 && self.totalTextPiecesCount != self.totalSelectionPiecesCount;
		} else {
			return  NO;
		}
		return YES;
	}
	else if ([menuItem action] == @selector(startSpeaking:))
	{
		if (@available(macOS 10.15, *))
		{
			return self.isAnySelected;
		} else {
			return  NO;
		}
		return YES;
	}
	else if ([menuItem action] == @selector(stopSpeaking:))
	{
		return [sSpeechSynthesizer isSpeaking];
	}
	return NO;
}

- (void)startSpeaking:(id)sender
{
	if (sSpeechSynthesizer == nil)
	{
		sSpeechSynthesizer = [[NSSpeechSynthesizer alloc] init];
	}
	[sSpeechSynthesizer startSpeakingString:[self selection]];
}

- (void)stopSpeaking:(id)sender
{
	[sSpeechSynthesizer stopSpeaking];
}

- (void)selectAll:(id)sender
{

	if (@available(macOS 10.15, *))
	{
		for (OCRDatum *datum in self.datums)
		{
			if (datum.image != nil)
			{
				datum.selectionPieces = [NSMutableDictionary dictionary];
				for (VNRecognizedTextObservation *piece in datum.textPieces)
				{
					NSArray<VNRecognizedText *> *text1 = [piece topCandidates:1];
					NSRange r = NSMakeRange(0, text1.firstObject.string.length);
					datum.selectionPieces[piece] = [NSValue valueWithRange:r];
				}
			}
		}
		[self.view setNeedsDisplay:YES];
		[self.view.window invalidateCursorRectsForView:self.view];
	}
}

- (void)copy:(id)sender
{
  NSPasteboard *pboard = [NSPasteboard generalPasteboard];
  [self copyToPasteboard:pboard];
}

- (void)copyToPasteboard:(NSPasteboard *)pboard
{
  NSString *s = [self selection];
  [pboard clearContents];
  [pboard setString:s forType:NSPasteboardTypeString];
}

#pragma mark Services

- (id)validRequestorForSendType:(NSString *)sendType returnType:(NSString *)returnType
{
  if (([sendType isEqual:NSPasteboardTypeString] || [sendType isEqual:NSStringPboardType]) && self.isAnySelected)
	{
    return self;
  }
  return [[self nextResponder] validRequestorForSendType:sendType returnType:returnType];
}

- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pboard types:(NSArray *)types
{
  if (([types containsObject:NSPasteboardTypeString] || [types containsObject:NSStringPboardType]) && self.isAnySelected)
	{
    [self copyToPasteboard:pboard];
    return YES;
  }
  return NO;
}

@end
