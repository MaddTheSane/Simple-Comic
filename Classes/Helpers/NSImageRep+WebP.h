//
//  NSImageRep+WebP.h
//  Simple Comic
//
//  Created using SDWebImageWebPCoder on 2/5/26.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSImageRep (WebP)

/// Register the WebP image coder with NSImageRep system
/// This allows NSImage to automatically load WebP files (including animated)
+ (void)registerWebPSupport;

@end

NS_ASSUME_NONNULL_END

