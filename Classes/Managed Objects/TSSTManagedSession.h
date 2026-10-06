//
//  TSSTManagedSession.h
//  SimpleComic
//
//  Created by Alexander Rauchfuss on 2/9/08.
//  Copyright 2008 Dancing Tortoise Software. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface TSSTManagedSession : NSManagedObject
{
	BOOL _loading;
	BOOL _lastOpenHadErrors;
}

/**
 Transient, non-persisted flag. YES while a background archive scan for
 this session is still in flight (see -[SimpleComicAppDelegate addFileURLs:toSession:]).
 KVO-compliant so TSSTSessionWindowController can observe it to know when
 to stop showing the "Loading..." overlay / decide whether to close a
 window that still has zero pages.
 */
@property (nonatomic, getter=isLoading) BOOL loading;

/**
 Transient, non-persisted: set by -[SimpleComicAppDelegate addFileURLs:toSession:]
 when a background scan reported any per-file errors (already surfaced via
 an error alert). TSSTSessionWindowController checks this so it
 doesn't pile a second, redundant "no pages found" alert on top of that one.
 */
@property (nonatomic) BOOL lastOpenHadErrors;

@end

#import "TSSTManagedSession+CoreDataProperties.h"
