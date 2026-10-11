//
//  TSSTTestFixtures.m
//  OCR Unit Tests
//

#import "TSSTTestFixtures.h"

@implementation TSSTTestFixtures

+ (nullable NSURL *)fixtureNamed:(NSString *)name
{
	NSBundle *bundle = [NSBundle bundleForClass: self];
	return [bundle URLForResource: name withExtension: nil]
		?: [bundle URLForResource: name withExtension: nil subdirectory: @"rarzoo"];
}

@end
