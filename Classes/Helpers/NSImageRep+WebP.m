//
//  NSImageRep+WebP.m
//  Simple Comic
//
//  Created using SDWebImageWebPCoder on 2/5/26.
//

#import "NSImageRep+WebP.h"

// SDWebImageWebPCoder integration
@import SDWebImageWebPCoder;
@import SDWebImage;

@implementation NSImageRep (WebP)

+ (void)registerWebPSupport {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Register WebP coder with SDWebImage
        SDImageWebPCoder *webPCoder = [SDImageWebPCoder sharedCoder];
        [[SDImageCodersManager sharedManager] addCoder:webPCoder];
        
        // Register SDAnimatedImageRep with NSImage so it can handle animated images (including WebP)
        // This allows NSImage's +imageWithData: to automatically create animated image representations
        [NSImageRep registerImageRepClass:[SDAnimatedImageRep class]];
    });
}

@end

