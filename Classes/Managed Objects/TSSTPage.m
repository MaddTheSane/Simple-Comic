/*
Copyright (c) 2006-2009 Dancing Tortoise Software

	Permission is hereby granted, free of charge, to any person
	obtaining a copy of this software and associated documentation
	files (the "Software"), to deal in the Software without
	restriction, including without limitation the rights to use,
	copy, modify, merge, publish, distribute, sublicense, and/or
	sell copies of the Software, and to permit persons to whom the
	Software is furnished to do so, subject to the following
	conditions:

	The above copyright notice and this permission notice shall be
	included in all copies or substantial portions of the Software.

  TSSTPage.m
*/

#import "TSSTPage.h"
#import "SimpleComicAppDelegate.h" // AppleScript
#import "TSSTSessionWindowController.h"	// AppleScript
#import "TSSTImageUtilities.h"
#import "TSSTManagedGroup.h"
#import <XADMaster/XADArchive.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>

static NSDictionary * TSSTInfoPageAttributes = nil;
static NSSize monospaceCharacterSize;

@implementation TSSTPage

+ (NSArray<NSString*>*)imageTypes
{
	static NSArray * imageTypes = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSMutableArray<NSString*> *aimageTypes = [[NSImage imageTypes] mutableCopy];
		[aimageTypes removeObject:(NSString*)kUTTypePDF];
		[aimageTypes filterUsingPredicate:[NSPredicate predicateWithFormat:@"!(SELF like %@)" argumentArray:@[@"com.adobe.encapsulated-postscript"]]];
		imageTypes = [aimageTypes copy];
	});
	
	return imageTypes;
}

+ (NSArray *)imageExtensions
{
	static NSArray * imageTypes = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSArray<NSString*> *imgTyp = self.imageTypes;
		NSMutableSet<NSString*> *aimageTypes = [[NSMutableSet alloc] initWithCapacity:imgTyp.count * 2];
		for (NSString *uti in imgTyp) {
			UTType *fileUTI = [UTType typeWithIdentifier:uti];
			NSArray *fileExts = fileUTI.tags[UTTagClassFilenameExtension];
			[aimageTypes addObjectsFromArray:fileExts];
		}
		//Some early JPEGs have the extension jfi/jfif.
		[aimageTypes addObject:@"jfi"];
		[aimageTypes addObject:@"jfif"];
		imageTypes = [[aimageTypes allObjects] sortedArrayUsingSelector:@selector(compare:)];
	});
	
	return imageTypes;
}

+ (NSArray *)textExtensions
{
	static NSArray * textTypes = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		textTypes = @[@"txt", @"nfo", @"info"];
	});
	
	return textTypes;
}

+ (void)initialize
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		/* Figure out the size of a single monospace character to set the tab stops */
		NSFont * menlo14 = [NSFont fontWithName: @"Menlo" size: 14];
		NSDictionary * fontAttributes = @{NSFontAttributeName: menlo14};
		monospaceCharacterSize = [@"A" boundingRectWithSize: NSZeroSize options: 0 attributes: fontAttributes].size;
		
		NSMutableArray<NSTextTab*> * tabStops = [NSMutableArray arrayWithCapacity:120/8-1];
		/* Loop through the tab stops */
		for (NSInteger tabSize = 8; tabSize < 120; tabSize+=8) {
			CGFloat tabLocation = tabSize * monospaceCharacterSize.width;
			NSTextTab * tabStop = [[NSTextTab alloc] initWithType: NSLeftTabStopType location: tabLocation];
			[tabStops addObject: tabStop];
		}
		
		NSMutableParagraphStyle * style = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
		style.tabStops = tabStops;
		
		TSSTInfoPageAttributes = @{NSFontAttributeName: menlo14,
								   NSParagraphStyleAttributeName: style};
	});
}

- (void)awakeFromInsert
{
	[super awakeFromInsert];
	thumbLock = [NSLock new];
	loaderLock = [NSLock new];
}

- (void)awakeFromFetch
{
	[super awakeFromFetch];
	thumbLock = [NSLock new];
	loaderLock = [NSLock new];
}

- (void)didTurnIntoFault
{
	loaderLock = nil;
	thumbLock = nil;
}

- (BOOL)shouldDisplayAlone
{   
	if(self.text)
	{
		return YES;
	}
	
	CGFloat defaultAspect = 1;
	CGFloat aspect = self.aspectRatio;
	if(!aspect)
	{
		NSData * imageData = [self pageData];
		[self setOwnSizeInfoWithData: imageData];
		aspect = self.aspectRatio;
	}
	
	return aspect != 0 ? aspect > defaultAspect : YES;
}

+ (BOOL)pixelSizeFromImageData:(NSData *)imageData size:(NSSize *)outSize
{
	NSSize imageSize = NSZeroSize;

	// Try reading pixel dimensions from the image header only, via ImageIO. This avoids
	// decoding the full image (expensive for formats like JPEG XL) just to get its size.
	NSDictionary * sourceOptions = @{(id)kCGImageSourceShouldCache: @NO};
	CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)imageData, (__bridge CFDictionaryRef)sourceOptions);
	if (source) {
		CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, 0, (__bridge CFDictionaryRef)sourceOptions);
		if (properties) {
			NSDictionary * props = (__bridge NSDictionary *)properties;
			NSNumber * pixelWidth = props[(id)kCGImagePropertyPixelWidth];
			NSNumber * pixelHeight = props[(id)kCGImagePropertyPixelHeight];
			if (pixelWidth && pixelHeight) {
				imageSize = NSMakeSize(pixelWidth.doubleValue, pixelHeight.doubleValue);
			}
			CFRelease(properties);
		}
		CFRelease(source);
	}

	if (NSEqualSizes(NSZeroSize, imageSize)) {
		// Fall back to decoding the image if ImageIO couldn't provide header dimensions
		// (e.g. WebP handled by the vendored decoder, or other custom NSImageRep types).
		NSImageRep * pageRep = [NSBitmapImageRep imageRepWithData: imageData];
		if (!pageRep) {
			// If it failed, try iterating through each registered NSImageRep subclass.
			Class imgRepClass = [NSImageRep imageRepClassForData:imageData];
			pageRep = [imgRepClass imageRepWithData: imageData];
		}
		imageSize = NSMakeSize([pageRep pixelsWide], [pageRep pixelsHigh]);
	}

	if (NSEqualSizes(NSZeroSize, imageSize))
	{
		return NO;
	}
	if (outSize) { *outSize = imageSize; }
	return YES;
}

- (void)setOwnSizeInfoWithData:(NSData *)imageData
{
	NSSize imageSize;
	if ([TSSTPage pixelSizeFromImageData: imageData size: &imageSize])
	{
		self.width = imageSize.width;
		self.height = imageSize.height;
		self.aspectRatio = imageSize.width / imageSize.height;
	}
}

- (NSString *)name
{
	return [self.imagePath lastPathComponent];
}

- (NSImage *)thumbnail
{
	NSImage * thumbnail = nil;
	NSData * thumbnailData = self.thumbnailData;
	if(!thumbnailData)
	{
		thumbnailData = [self prepThumbnail];
		self.thumbnailData = thumbnailData;
		thumbnail = [[NSImage alloc] initWithData: thumbnailData];
	}
	else
	{
		thumbnail = [[NSImage alloc] initWithData: thumbnailData];
	}
	
	return thumbnail;
}

+ (NSData *)thumbnailDataFromImageData:(NSData *)imageData
{
	if (!imageData) { return nil; }
	CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)imageData, NULL);
	if (!source) { return nil; }
	NSDictionary * options = @{ (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
								(id)kCGImageSourceCreateThumbnailWithTransform: @YES,
								(id)kCGImageSourceThumbnailMaxPixelSize: @256 };
	CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
	CFRelease(source);
	if (!image) { return nil; }
	NSMutableData * output = [NSMutableData data];
	CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)output, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
	if (destination)
	{
		CGImageDestinationAddImage(destination, image, NULL);
		if (!CGImageDestinationFinalize(destination)) { output = nil; }
		CFRelease(destination);
	}
	else { output = nil; }
	CGImageRelease(image);
	return output;
}

- (NSData *)renderThumbnailDataOffMain
{
	if (self.text) { return nil; }
	return [TSSTPage thumbnailDataFromImageData: [self pageData]];
}

- (NSData *)prepThumbnail
{
	[thumbLock lock];
	NSImage * managedImage = [self pageImage];
	NSData * thumbnailData = nil;
	NSSize pixelSize = [managedImage size];
	if(managedImage)
	{
		pixelSize = sizeConstrainedByDimension(pixelSize, 256);
		NSImage * temp = [[NSImage alloc] initWithSize: pixelSize];
		[temp lockFocus];
		[[NSGraphicsContext currentContext] setImageInterpolation: NSImageInterpolationHigh];
		[managedImage drawInRect: NSMakeRect(0, 0, pixelSize.width, pixelSize.height)
						fromRect: NSZeroRect
					   operation: NSCompositingOperationSourceOver
						fraction: 1.0];
		[temp unlockFocus];
		thumbnailData = [temp TIFFRepresentation];
	}
	[thumbLock unlock];
	
	return thumbnailData;
}

- (NSImage *)pageImage
{
	if(self.text)
	{
		return [self textPage];
	}

	NSData * imageData = [self pageData];
	if(imageData)
	{
		[self setOwnSizeInfoWithData: imageData];
	}

	return [TSSTPage imageWithData: imageData pixelSize: NSMakeSize(self.width, self.height)];
}

+ (nullable NSImage *)imageWithData:(nullable NSData *)imageData pixelSize:(NSSize)pixelSize
{
	if (!imageData || NSEqualSizes(NSZeroSize, pixelSize))
	{
		return nil;
	}
	NSImage * imageFromData = [[NSImage alloc] initWithData: imageData];
	if (!imageFromData)
	{
		return nil;
	}
	[imageFromData setCacheMode: NSImageCacheNever];
	[imageFromData setSize: pixelSize];
	[imageFromData setCacheMode: NSImageCacheBySize];
	return imageFromData;
}

- (NSImage *)textPage
{
	__block NSData * textData;
	if(self.index != nil)
	{
		[self.group requestDataForPageIndex: [self.index integerValue] completionHandler:^(NSData * _Nullable pageData, NSError * _Nullable error) {
			textData = pageData;
		}];
	}
	else
	{
		textData = [NSData dataWithContentsOfFile: self.imagePath];
	}
	
	BOOL lossyConversion = NO;
	NSString * text;
	NSStringEncoding stringEncoding = [NSString stringEncodingForData: textData
													  encodingOptions: @{NSStringEncodingDetectionFromWindowsKey: @YES}
													  convertedString: &text
												  usedLossyConversion: &lossyConversion];
	if (stringEncoding == 0 && text == nil) {
		// get back something, even if it's garbled.
		stringEncoding = NSMacOSRomanStringEncoding;
		text = [[NSString alloc] initWithData: textData encoding: stringEncoding];
	}
	//	int lineCount = 0;
	NSRect lineRect;
	NSRect pageRect = NSZeroRect;
	
	NSUInteger index = 0;
	NSUInteger textLength = [text length];
	NSRange lineRange;
	NSString * singleLine;
	while(index < textLength)
	{
		lineRange = [text lineRangeForRange: NSMakeRange(index, 0)];
		index = NSMaxRange(lineRange);
		singleLine = [text substringWithRange: lineRange];
		lineRect = [singleLine boundingRectWithSize: NSMakeSize(800, 800) options: NSStringDrawingUsesLineFragmentOrigin attributes: TSSTInfoPageAttributes];
		if(NSWidth(lineRect) > NSWidth(pageRect))
		{
			pageRect.size.width = lineRect.size.width;
		}
		
		pageRect.size.height += (NSHeight(lineRect) - 19);
	}
	pageRect.size.width += 10;
	pageRect.size.height += 10;
	pageRect.size.height = MAX(NSHeight(pageRect), 500);
	
	NSImage * textImage = [[NSImage alloc] initWithSize: pageRect.size];
	
	[textImage lockFocus];
	[[NSColor whiteColor] set];
	NSRectFill(pageRect);
	[text drawWithRect: NSInsetRect( pageRect, 5, 5) options: NSStringDrawingUsesLineFragmentOrigin attributes: TSSTInfoPageAttributes];
	[textImage unlockFocus];
	
	return textImage;
}

- (NSData *)pageData
{
	__block NSData * imageData = nil;
	TSSTManagedGroup * group = self.group;
	if(self.index != nil)
	{
		NSInteger entryIndex = [self.index integerValue];
		[group requestDataForPageIndex:entryIndex completionHandler:^(NSData * _Nullable pageData, NSError * _Nullable error) {
			imageData = pageData;
		}];
	}
	else if([self imagePath])
	{
		imageData = [NSData dataWithContentsOfFile: self.imagePath];
	}
	
	return imageData;
}

#pragma mark - Applescript

- (NSScriptObjectSpecifier *)objectSpecifier
{
	TSSTManagedSession *session = self.session;
	NSArray<TSSTSessionWindowController *> *controllers = [(SimpleComicAppDelegate *)[NSApp delegate] sessions];
	for (TSSTSessionWindowController *controller in controllers) {
		if (controller.session == session) {
			NSScriptObjectSpecifier *parent = [controller objectSpecifier];
			NSScriptClassDescription *desc = [NSScriptClassDescription classDescriptionForClass:[self class]];
			return [[NSIndexSpecifier alloc] initWithContainerClassDescription:desc
																											containerSpecifier:parent
																																		 key:@"page"
																																	 index:[self.index integerValue]];
		}
	}
	return nil;
}

@end
