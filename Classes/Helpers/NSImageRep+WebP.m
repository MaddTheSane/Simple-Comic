//
//  NSImageRep+WebP.m
//  Simple Comic
//
//  Created using SDWebImageWebPCoder on 2/5/26.
//

#import "NSImageRep+WebP.h"

// SDWebImageWebPCoder integration
#import <SDWebImage/SDImageAWebPCoder.h>
#import <SDWebImage/SDWebImage.h>
#import <SDWebImageWebPCoder/SDImageWebPCoder.h>

@implementation NSImageRep (WebP)

+ (void)registerWebPSupport {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Register WebP coder with SDWebImage
        // Use SDImageAWebPCoder (system-provided) on macOS 11.0+ for better performance,
        // fallback to SDImageWebPCoder (libwebp-based) on older systems
        id<SDImageCoder> webPCoder;
        
        if (@available(macOS 11.0, *)) {
            webPCoder = [SDImageAWebPCoder sharedCoder];
        } else {
            webPCoder = [SDImageWebPCoder sharedCoder];
        }
        
        [[SDImageCodersManager sharedManager] addCoder:webPCoder];
        
        // Register SDAnimatedImageRep with NSImage so it can handle animated images (including WebP)
        // This allows NSImage's +imageWithData: to automatically create animated image representations
        [NSImageRep registerImageRepClass:[SDAnimatedImageRep class]];
    });
}

@end

