//
//  TSSTManagedSession.m
//  SimpleComic
//
//  Created by Alexander Rauchfuss on 2/9/08.
//  Copyright 2008 Dancing Tortoise Software. All rights reserved.
//

#import "TSSTManagedSession.h"
#import "TSSTManagedGroup.h"

@implementation TSSTManagedSession

/*	The whole point of this method is to check for files in a session.
	Making sure they are still there. If not they are deleted. */
- (void)awakeFromFetch
{
	[super awakeFromFetch];
	[self waitForSlowDisks];
	/* By calling path for all children, groups with unresolved bookmarks
	 are deleted.
	 Using copy to make sure changes to groups won't cause Cocoa to complain about mutated iterators. */
	for (TSSTManagedGroup *group in [self.groups copy])
	{
		[group fileURL];
	}
}

/**
  If Simple Comic is set to open at login, and the books to show on launch are on a slow hard disk, this will wait up to five seconds
  for the slow disk to become available. Trying every second to resolve the bookmark data.
 */
- (void) waitForSlowDisks
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		for(NSUInteger i = 0; i < 5;++i){
			BOOL bookmarkFailed = NO;
			for (TSSTManagedGroup *group in [self.groups copy])
			{
				NSURL *url = [group probeFileURL];
				if (url == nil) {
					bookmarkFailed = YES;
				}
			}
			if (bookmarkFailed) {
				sleep(1);
			} else {
				break;
			}
		}
	});
}

@end
