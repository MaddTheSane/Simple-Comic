/*
	Simple Comic
	TSSTRAR5QuickOpen.h

  Lists a RAR5 archive from its "Quick Open" (QO) service header -- a
  cached copy of every file header, stored in one block near the end of
  the archive -- instead of walking the headers one seek at a time. Over a
  slow volume that turns a per-entry round trip into a few reads.

  The cached headers are decoded by XADRAR5Parser's own readers and fed to
  its own -addEntryWithDictionary:inputParts:isCorrupted:, so the entry
  dictionaries (and the parser's solid-stream table used for extraction)
  are exactly what a normal -parse would have produced.
*/

#import <Foundation/Foundation.h>

@class XADArchiveParser;

NS_ASSUME_NONNULL_BEGIN

@interface TSSTRAR5QuickOpen : NSObject

/// Tries to list the archive behind parser (not yet parsed) via its Quick
/// Open record. Returns NO, having emitted nothing and left the parser
/// ready for a normal -parse, when parser isn't RAR5 or the archive has no
/// usable record (no QO, solid, multi-volume, encrypted, malformed, ...).
/// Returns YES once the entries have been delivered to the parser's
/// delegate; *error is then set only if delivery itself failed.
+ (BOOL)listParser:(XADArchiveParser *)parser error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
