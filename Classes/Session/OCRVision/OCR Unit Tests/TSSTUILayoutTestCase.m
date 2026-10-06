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

- (void)walkContentView:(NSView *)contentView withBlock:(void (^)(NSView *view))block
{
	block(contentView);
	for (NSView *subview in contentView.subviews) {
		[self walkContentView:subview withBlock:block];
	}
}

- (void)assertNoAmbiguousLayoutInContentView:(NSView *)contentView
{
	[contentView layoutSubtreeIfNeeded];
	[self walkContentView:contentView withBlock:^(NSView *view) {
		XCTAssertFalse(view.hasAmbiguousLayout, @"%@ (%@) has an ambiguous Auto Layout solution", view, view.identifier);
	}];
}

// Internal AppKit implementation views (e.g. NSWidgetView, the checkbox hit-target
// layer) routinely extend a couple points past their nominal control bounds as part
// of normal rendering/hit-slop. Checking every subview would flag that as "clipping"
// on stock, unmodified controls, so containment/overlap checks below are scoped to
// NSControl instances (the things a user actually looks at and interacts with) and
// allow a small tolerance for anti-aliasing/hairline rounding.
static const CGFloat kLayoutTolerance = 2.0;

- (void)collectControlsInView:(NSView *)view into:(NSMutableArray<NSControl *> *)controls
{
	for (NSView *subview in view.subviews) {
		if ([subview isKindOfClass:[NSControl class]]) {
			[controls addObject:(NSControl *)subview];
		}
		[self collectControlsInView:subview into:controls];
	}
}

- (void)assertNoClippedSubviewsInContentView:(NSView *)contentView
{
	[contentView layoutSubtreeIfNeeded];
	NSMutableArray<NSControl *> *controls = [NSMutableArray array];
	[self collectControlsInView:contentView into:controls];
	for (NSControl *control in controls) {
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
	[contentView layoutSubtreeIfNeeded];
	NSMutableArray<NSControl *> *controls = [NSMutableArray array];
	[self collectControlsInView:contentView into:controls];
	for (NSUInteger i = 0; i < controls.count; i++) {
		for (NSUInteger j = i + 1; j < controls.count; j++) {
			NSControl *a = controls[i];
			NSControl *b = controls[j];
			if (a.superview != b.superview) continue; // only compare true siblings
			NSRect frameA = NSInsetRect(a.frame, kLayoutTolerance, kLayoutTolerance);
			NSRect frameB = NSInsetRect(b.frame, kLayoutTolerance, kLayoutTolerance);
			NSRect intersection = NSIntersectionRect(frameA, frameB);
			XCTAssertTrue(NSIsEmptyRect(intersection),
				@"%@ and %@ overlap beyond tolerance: %@", a, b, NSStringFromRect(intersection));
		}
	}
}

- (void)assertControl:(NSControl *)control fitsWithinFrame:(NSRect)frame
{
	NSSize fitting = control.fittingSize;
	XCTAssertLessThanOrEqual(fitting.width, NSWidth(frame) + 0.5,
		@"%@ needs width %.1f but only has %.1f (title likely truncated)", control, fitting.width, NSWidth(frame));
	XCTAssertLessThanOrEqual(fitting.height, NSHeight(frame) + 0.5,
		@"%@ needs height %.1f but only has %.1f", control, fitting.height, NSHeight(frame));
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
