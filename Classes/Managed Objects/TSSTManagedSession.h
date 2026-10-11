//
//  TSSTManagedSession.h
//  SimpleComic
//
//  Created by Alexander Rauchfuss on 2/9/08.
//  Copyright 2008 Dancing Tortoise Software. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface TSSTManagedSession : NSManagedObject

/**
 Transient, non-persisted count of background archive scans still in flight
 for this session (see -[SimpleComicAppDelegate addFileURLs:toSession:]).
 Overlapping adds to one session each contribute one per archive. Only
 touch it on the main queue.
 */
@property (nonatomic) NSUInteger pendingScanCount;

/**
 YES while \c pendingScanCount is non-zero. KVO-compliant (it follows
 \c pendingScanCount) so TSSTSessionWindowController can observe it to know
 when to stop showing the "Loading..." overlay / decide whether to close a
 window that still has zero pages.
 */
@property (nonatomic, readonly, getter=isLoading) BOOL loading;

/**
 Transient, non-persisted: set by -[SimpleComicAppDelegate addFileURLs:toSession:]
 when a background scan reported any per-file errors (already surfaced via
 an error alert). TSSTSessionWindowController checks this so it
 doesn't pile a second, redundant "no pages found" alert on top of that one.
 */
@property (nonatomic) BOOL lastOpenHadErrors;

@end

#import "TSSTManagedSession+CoreDataProperties.h"
