/*
	Simple Comic
	TSSTByteSourceHandle.h

  A CSHandle over a TSSTArchiveByteSource, so XADMaster's parsers (which
  only know how to read through a CSHandle) can read archives that live
  behind our byte-source stack (caching, simulated-link, plain file).
  Keeps a small read-ahead buffer so XAD's many small reads don't each
  turn into an upstream request.
*/

#import <Foundation/Foundation.h>
#import <XADMaster/CSHandle.h>

#import "TSSTArchiveByteSource.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const TSSTByteSourceHandleErrorException;

@interface TSSTByteSourceHandle : CSHandle

- (instancetype)initWithByteSource:(id<TSSTArchiveByteSource>)source;
- (instancetype)initAsCopyOf:(TSSTByteSourceHandle *)other;

@property (nonatomic, readonly) id<TSSTArchiveByteSource> byteSource;

@end

NS_ASSUME_NONNULL_END
