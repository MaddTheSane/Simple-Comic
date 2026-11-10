//
//  TSSTWebPFixtureTests.m
//  Runs the webpzoo fixtures (small public-domain Jessie James pages re-encoded as
//  WebP) through the same decode path the app uses for WebP pages.
//

#import <XCTest/XCTest.h>
#import <XADMaster/XADArchive.h>
#import <SDWebImage/SDWebImage.h>

@interface TSSTWebPFixtureTests : XCTestCase
@end

@implementation TSSTWebPFixtureTests

- (XADArchive *)archiveNamed:(NSString *)name {
	NSURL *url = [[NSBundle bundleForClass:self.class] URLForResource:name.stringByDeletingPathExtension
														withExtension:name.pathExtension
														 subdirectory:@"webpzoo"];
	XCTAssertNotNil(url, @"%@ is not in the test bundle", name);
	if (!url) return nil;
	XADArchive *archive = [[XADArchive alloc] initWithFileURL:url delegate:nil error:NULL];
	XCTAssertNotNil(archive, @"%@ did not open", name);
	return archive;
}

// Entry data for each file in an archive, in name order.
- (NSArray<NSArray *> *)entriesIn:(XADArchive *)archive {
	NSMutableArray *entries = [NSMutableArray array];
	for (NSInteger i = 0; i < archive.numberOfEntries; i++) {
		NSString *name = [archive nameOfEntry:i];
		NSData *data = [archive contentsOfEntry:i];
		if (name && data) [entries addObject:@[name, data]];
	}
	[entries sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
	return entries;
}

// Mirrors TSSTPage: WebP data is detected by content and decoded to a rep with the right size
// and frame count; animated files report more than one frame, static ones exactly one.
- (void)checkEntries:(NSArray<NSArray *> *)entries expectedWebP:(NSUInteger)expectedWebP animated:(NSUInteger)expectedAnimated {
	NSUInteger webp = 0, animated = 0;
	for (NSArray *entry in entries) {
		NSData *data = entry[1];
		if ([NSData sd_imageFormatForImageData:data] != SDImageFormatWebP) continue;
		webp++;
		SDAnimatedImageRep *rep = [SDAnimatedImageRep imageRepWithData:data];
		XCTAssertNotNil(rep, @"%@ failed to decode", entry[0]);
		XCTAssertGreaterThan(rep.size.width, 0, @"%@", entry[0]);
		XCTAssertGreaterThan(rep.size.height, 0, @"%@", entry[0]);
		NSUInteger frames = [[rep valueForProperty:NSImageFrameCount] unsignedIntegerValue];
		BOOL isAnimated = frames > 1;
		BOOL nameSaysAnimated = [entry[0] containsString:@"anim"];
		XCTAssertEqual(isAnimated, nameSaysAnimated, @"%@ animated=%d frames=%lu", entry[0], isAnimated, (unsigned long)frames);
		if (isAnimated) animated++;
	}
	XCTAssertEqual(webp, expectedWebP);
	XCTAssertEqual(animated, expectedAnimated);
}

- (void)testStaticWebPDecodes {
	NSArray *entries = [self entriesIn:[self archiveNamed:@"webp_static.cbz"]];
	XCTAssertEqual(entries.count, 3u);
	[self checkEntries:entries expectedWebP:3 animated:0];
}

- (void)testAnimatedWebPReportsMultipleFrames {
	NSArray *entries = [self entriesIn:[self archiveNamed:@"webp_animated.cbz"]];
	XCTAssertEqual(entries.count, 3u);
	[self checkEntries:entries expectedWebP:3 animated:3];
}

// A mixed archive: WebP pages are recognized by content and PNG pages are left to ImageIO.
- (void)testMixedArchiveKeepsPNGOutOfWebPPath {
	NSArray *entries = [self entriesIn:[self archiveNamed:@"webp_mixed.cbz"]];
	XCTAssertEqual(entries.count, 4u);
	[self checkEntries:entries expectedWebP:2 animated:1];
	for (NSArray *entry in entries) {
		if ([entry[0] hasSuffix:@".png"]) {
			XCTAssertNotNil([[NSImage alloc] initWithData:entry[1]], @"%@", entry[0]);
		}
	}
}

@end
