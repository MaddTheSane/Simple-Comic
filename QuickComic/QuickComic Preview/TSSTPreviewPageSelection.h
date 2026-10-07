//
//  TSSTPreviewPageSelection.h
//  Which archive entries the Quick Look preview turns into PDF pages.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Offsets (into the sorted image list) to include in the preview: the first
/// `maxPages` entries plus the last one, as suggested by a user. Kept in a header
/// so the unit tests can exercise it without loading the extension.
static inline NSArray<NSNumber *> *TSSTPreviewPageOffsets(NSUInteger imageCount, NSUInteger maxPages) {
	NSMutableArray<NSNumber *> *offsets = [NSMutableArray array];
	for (NSUInteger i = 0; i < imageCount; i++) {
		if (i < maxPages || i == imageCount - 1) {
			[offsets addObject:@(i)];
		}
	}
	return offsets;
}

NS_ASSUME_NONNULL_END
