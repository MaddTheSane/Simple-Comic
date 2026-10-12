//
//  TSSTUILayoutTestCase.m
//

#import "TSSTUILayoutTestCase.h"

@interface TSSTUILayoutTestCase ()
@property (nonatomic, strong, nullable) NSWindowController *preferencesController;
@end

@implementation TSSTUILayoutTestCase

- (NSWindow *)loadPreferencesWindow
{
	// The class name is module-qualified when the controller is written in Swift.
	Class controllerClass = NSClassFromString(@"Simple_Comic.DTPreferencesController") ?: NSClassFromString(@"DTPreferencesController");
	XCTAssertNotNil(controllerClass, @"DTPreferencesController class not found");
	// Retain the controller so the window and its bindings outlive this call.
	self.preferencesController = [[controllerClass alloc] init];
	NSWindow *window = self.preferencesController.window; // forces the nib to load
	XCTAssertNotNil(window, @"Preferences.xib failed to load a window");
	[window.contentView layoutSubtreeIfNeeded];
	return window;
}

- (NSButton *)checkboxWithTitle:(NSString *)title inView:(NSView *)view
{
	for (NSView *subview in view.subviews) {
		if ([subview isKindOfClass:[NSButton class]] && [((NSButton *)subview).title isEqualToString:title]) {
			return (NSButton *)subview;
		}
		NSButton *found = [self checkboxWithTitle:title inView:subview];
		if (found) return found;
	}
	return nil;
}

- (void)tearDown
{
	self.preferencesController = nil;
	[super tearDown];
}

// Every view under (and including) `root`, depth first.
- (NSArray<NSView *> *)viewsInTree:(NSView *)root
{
	NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObject:root];
	for (NSView *subview in root.subviews) {
		[views addObjectsFromArray:[self viewsInTree:subview]];
	}
	return views;
}

// Internal AppKit implementation views (e.g. NSWidgetView, the checkbox hit-target
// layer) routinely extend a couple points past their nominal control bounds as part
// of normal rendering/hit-slop. Checking every subview would flag that as "clipping"
// on stock, unmodified controls, so containment/overlap checks below are scoped to
// NSControl instances (the things a user actually looks at and interacts with) and
// allow a small tolerance for anti-aliasing/hairline rounding.
static const CGFloat kLayoutTolerance = 2.0;

- (NSArray<NSView *> *)controlsInTree:(NSView *)root
{
	return [[self viewsInTree:root] filteredArrayUsingPredicate:
		[NSPredicate predicateWithBlock:^BOOL(NSView *view, id _) { return [view isKindOfClass:[NSControl class]]; }]];
}

// The assert methods below rely on loadPreferencesWindow having laid the window out.
- (void)assertNoAmbiguousLayoutInContentView:(NSView *)contentView
{
	for (NSView *view in [self viewsInTree:contentView]) {
		XCTAssertFalse(view.hasAmbiguousLayout, @"%@ (%@) has an ambiguous Auto Layout solution", view, view.identifier);
	}
}

- (void)assertNoClippedSubviewsInContentView:(NSView *)contentView
{
	for (NSView *control in [self controlsInTree:contentView]) {
		NSView *superview = control.superview;
		if (!superview) continue;
		NSRect inset = NSInsetRect(superview.bounds, -kLayoutTolerance, -kLayoutTolerance);
		XCTAssertTrue(NSContainsRect(inset, control.frame),
			@"%@ frame %@ is not contained (within %.0fpt tolerance) in superview bounds %@",
			control, NSStringFromRect(control.frame), kLayoutTolerance, NSStringFromRect(superview.bounds));
	}
}

- (void)assertNoOverlappingSiblingsInContentView:(NSView *)contentView
{
	NSArray<NSView *> *controls = [self controlsInTree:contentView];
	for (NSUInteger i = 0; i < controls.count; i++) {
		for (NSUInteger j = i + 1; j < controls.count; j++) {
			NSView *a = controls[i];
			NSView *b = controls[j];
			if (a.superview != b.superview) continue; // only compare true siblings
			NSRect intersection = NSIntersectionRect(NSInsetRect(a.frame, kLayoutTolerance, kLayoutTolerance),
													 NSInsetRect(b.frame, kLayoutTolerance, kLayoutTolerance));
			XCTAssertTrue(NSIsEmptyRect(intersection),
				@"%@ and %@ overlap beyond tolerance: %@", a, b, NSStringFromRect(intersection));
		}
	}
}

- (void)assertControlFitsItsFrame:(NSControl *)control
{
	NSSize fitting = control.fittingSize;
	NSSize frame = control.frame.size;
	XCTAssertLessThanOrEqual(fitting.width, frame.width + 0.5,
		@"%@ needs width %.1f but only has %.1f (title likely truncated)", control, fitting.width, frame.width);
	XCTAssertLessThanOrEqual(fitting.height, frame.height + 0.5,
		@"%@ needs height %.1f but only has %.1f", control, fitting.height, frame.height);
}

- (void)assertControl:(NSControl *)control isBoundToDefaultsKey:(NSString *)key
{
	NSDictionary *info = [control infoForBinding:NSValueBinding];
	XCTAssertNotNil(info, @"%@ has no value binding at all", control);
	if (!info) return;

	NSString *keyPath = info[NSObservedKeyPathKey];
	NSString *expected = [NSString stringWithFormat:@"values.%@", key];
	XCTAssertEqualObjects(keyPath, expected, @"%@ is bound to %@ instead of %@", control, keyPath, expected);
}

@end
