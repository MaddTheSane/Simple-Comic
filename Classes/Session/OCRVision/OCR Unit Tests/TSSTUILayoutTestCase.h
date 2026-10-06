//
//  TSSTUILayoutTestCase.h
//  Shared, read-only layout assertions for nib-based UI regression tests.
//
//  These checks catch what ibtool's compile step cannot: ambiguous Auto Layout,
//  clipped/truncated controls, overlapping siblings, and mis-wired bindings.
//  Nothing here shows a window, runs a modal, or mutates user defaults.
//

#import <XCTest/XCTest.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSSTUILayoutTestCase : XCTestCase

// Loads Preferences.xib's window without showing it, and lays it out. The nib is
// loaded in the host app process, so this exercises the real xib and bindings.
- (NSWindow *)loadPreferencesWindow;

// Depth-first search for a button with this exact title; nil if there is none.
- (nullable NSButton *)checkboxWithTitle:(NSString *)title inView:(NSView *)view;

// Forces layout without showing the window, then asserts no view in the tree
// rooted at contentView has an ambiguous Auto Layout solution.
- (void)assertNoAmbiguousLayoutInContentView:(NSView *)contentView;

// Asserts every descendant view's frame is fully contained within its
// superview's bounds (catches clipping from an under-sized window/content view).
- (void)assertNoClippedSubviewsInContentView:(NSView *)contentView;

// Asserts no two sibling views' frames intersect (catches overlapping controls).
- (void)assertNoOverlappingSiblingsInContentView:(NSView *)contentView;

// Asserts the control's current frame is large enough to fit its content
// (catches truncated checkbox/label titles).
- (void)assertControl:(NSControl *)control fitsWithinFrame:(NSRect)frame;

// Asserts `control` has a value binding to `values.<key>` (catches a typo'd
// binding keyPath, which compiles and ibtool-compiles but silently no-ops).
- (void)assertControl:(NSControl *)control isBoundToDefaultsKey:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
