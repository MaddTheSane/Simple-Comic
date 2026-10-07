#import "TSSTRAR5QuickOpen.h"

// Not a public XADMaster header; reached by path so we reuse its readers.
#import "../../Vendor/XADMaster/XADRAR5Parser.h"
#import <XADMaster/XADException.h>
#import <XADMaster/XADPath.h>
#import <XADMaster/CSMemoryHandle.h>

static const uint64_t kQuickOpenMaxBytes = 256u << 20;

/// XADMaster's Release framework keeps its parser classes at hidden symbol
/// visibility, so the class can't be referenced directly without a link
/// error; look it up through the Objective-C runtime instead.
static Class TSSTRAR5ParserClass(void)
{
	static Class cls;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ cls = NSClassFromString(@"XADRAR5Parser"); });
	return cls;
}

/// Reads the main header's locator extra record and returns the archive
/// offset of the QO header, or -1, and where the first file header must
/// start (*firstFile). Leaves the handle wherever it ends up.
static off_t QuickOpenHeaderOffset(XADRAR5Parser *parser, CSHandle *handle, off_t *firstFile)
{
	static const uint8_t kSignature[8] = { 'R', 'a', 'r', '!', 0x1a, 0x07, 0x01, 0x00 };
	[handle seekToFileOffset: 0];
	NSData *signature = [handle readDataOfLength: 8];
	if (memcmp(signature.bytes, kSignature, 8) != 0) return -1;

	RAR5Block main = [parser readBlockHeader];
	if (main.type != RAR5HeaderTypeMain || main.extrasize == 0) return -1;
	uint64_t archiveFlags = [TSSTRAR5ParserClass() readRAR5VIntFrom: handle];
	if (archiveFlags & (RAR5ArchiveFlagsVolume | RAR5ArchiveFlagsSolid)) return -1;

	off_t end = main.start + (off_t)main.headersize;
	*firstFile = end;
	for (off_t pos = end - (off_t)main.extrasize; pos < end;) {
		[handle seekToFileOffset: pos];
		uint64_t size = [TSSTRAR5ParserClass() readRAR5VIntFrom: handle];
		off_t next = handle.offsetInFile + (off_t)size;
		if ([TSSTRAR5ParserClass() readRAR5VIntFrom: handle] == 1) { // locator
			uint64_t flags = [TSSTRAR5ParserClass() readRAR5VIntFrom: handle];
			if (flags & 1) return 8 + (off_t)[TSSTRAR5ParserClass() readRAR5VIntFrom: handle];
		}
		pos = next;
	}
	return -1;
}

@implementation TSSTRAR5QuickOpen

+ (BOOL)listParser:(XADArchiveParser *)baseParser error:(NSError **)error
{
	if (![baseParser isKindOfClass: TSSTRAR5ParserClass()]) return NO;
	XADRAR5Parser *parser = (XADRAR5Parser *)baseParser;
	CSHandle *realHandle = parser.handle;
	if (!realHandle) return NO;

	NSMutableArray<NSMutableDictionary *> *dicts = [NSMutableArray array];
	NSMutableArray<NSArray *> *partLists = [NSMutableArray array];

	off_t expected = 0, qoStart = -1;
	@try {
		qoStart = QuickOpenHeaderOffset(parser, realHandle, &expected);
		if (qoStart < 0) return NO;

		[realHandle seekToFileOffset: qoStart];
		RAR5Block qo = [parser readBlockHeader];
		if (qo.type != RAR5HeaderTypeService || qo.datasize == 0 || qo.datasize > kQuickOpenMaxBytes) return NO;
		NSMutableDictionary *qoDict = [parser readFileBlockHeader: qo];
		if (![[(XADPath *)qoDict[XADFileNameKey] string] isEqualToString: @"QO"] || qoDict[XADIsEncryptedKey]
			|| [qoDict[@"RAR5CompressionMethod"] intValue] != 0) return NO;
		[realHandle seekToFileOffset: [parser endOfBlockHeader: qo]];
		NSData *blob = [realHandle readDataOfLength: (int)qo.datasize];

		// Decode each cached header from memory with the parser's own
		// readers, then re-base its data offset to the real archive.
		CSMemoryHandle *memory = [CSMemoryHandle memoryHandleForReadingData: blob];
		parser.handle = memory;
		while (![memory atEndOfFile]) {
			[memory readUInt32LE]; // record CRC
			uint64_t size = [TSSTRAR5ParserClass() readRAR5VIntFrom: memory];
			off_t next = memory.offsetInFile + (off_t)size;
			[TSSTRAR5ParserClass() readRAR5VIntFrom: memory]; // flags
			uint64_t backOffset = [TSSTRAR5ParserClass() readRAR5VIntFrom: memory];
			[TSSTRAR5ParserClass() readRAR5VIntFrom: memory]; // cached header length
			off_t cachedStart = memory.offsetInFile;

			// The cache must cover the archive contiguously; a gap means it
			// omits entries (seen in the wild), so walk instead.
			off_t headerStart = qoStart - (off_t)backOffset;
			if (headerStart != expected) return NO;
			RAR5Block block = [parser readBlockHeader];
			if (block.type != RAR5HeaderTypeFile || (block.flags & 0x0018)) return NO; // split file
			NSMutableDictionary *dict = [parser readFileBlockHeader: block];
			if (dict[XADIsEncryptedKey] || [dict[XADIsSolidKey] boolValue]) return NO;

			off_t dataOffset = headerStart + [parser endOfBlockHeader: block] - cachedStart;
			dict[@"RAR5DataOffset"] = @(dataOffset);
			NSMutableDictionary *part = [NSMutableDictionary dictionaryWithObjectsAndKeys:
				@(dataOffset), @"Offset", @(block.datasize), @"InputLength", nil];
			if (dict[@"RAR5CRC32"]) part[@"CRC32"] = dict[@"RAR5CRC32"];
			expected = dataOffset + (off_t)block.datasize;
			[dicts addObject: dict];
			[partLists addObject: @[part]];
			[memory seekToFileOffset: next];
		}
	}
	@catch (id exception) {
		dicts = nil;
	}
	@finally {
		parser.handle = realHandle;
		[realHandle seekToFileOffset: 0];
	}
	if (dicts.count == 0 || expected != qoStart) return NO;

	@try {
		for (NSUInteger i = 0; i < dicts.count; i++) {
			[parser addEntryWithDictionary: dicts[i] inputParts: partLists[i] isCorrupted: NO];
		}
	}
	@catch (id exception) {
		if (error) *error = [XADException parseExceptionReturningNSError: exception];
	}
	return YES;
}

@end
