/*
	Simple Comic
	TSSTZipIndex.m
*/

#import "TSSTZipIndex.h"
#import <sys/stat.h>
#import <unistd.h>
#import <fcntl.h>
#import <zlib.h>

NSString * const TSSTZipIndexErrorDomain = @"TSSTZipIndexErrorDomain";

// Signatures.
static const uint32_t kEOCDSignature       = 0x06054b50;
static const uint32_t kEOCD64Signature     = 0x06064b50;
static const uint32_t kEOCD64LocSignature  = 0x07064b50;
static const uint32_t kCDHeaderSignature   = 0x02014b50;
static const uint32_t kLocalHeaderSignature = 0x04034b50;

static const NSUInteger kEOCDFixedSize = 22;
static const NSUInteger kMaxCommentLength = 65535;
static const NSUInteger kCDHeaderFixedSize = 46;
static const NSUInteger kLocalHeaderFixedSize = 30;

// Zip64 extra field id.
static const uint16_t kZip64ExtraID = 0x0001;

// General purpose bit flags.
static const uint16_t kGPFlagEncrypted   = 0x0001;
static const uint16_t kGPFlagUTF8        = 0x0800;

typedef struct
{
	NSUInteger nameOffset;   // offset within centralDirectory data
	NSUInteger nameLength;
	uint16_t generalPurposeFlag;
	uint16_t compressionMethod;
	uint32_t crc32;
	uint64_t compressedSize;
	uint64_t uncompressedSize;
	uint64_t localHeaderOffset;
	uint32_t externalAttributes;
} TSSTZipCDEntry;

@interface TSSTZipIndex ()
{
	id<TSSTArchiveByteSource> _source;
	NSData *_centralDirectoryData; // raw bytes for all CD headers, kept for name decoding
	NSMutableArray<NSValue *> *_entries; // boxed TSSTZipCDEntry
	NSMutableArray<NSString *> *_names;  // decoded names, index-aligned with _entries
}
@end

@implementation TSSTZipIndex

#pragma mark - Construction

+ (nullable instancetype)indexWithFileURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error
{
	id<TSSTArchiveByteSource> source = [TSSTFileByteSource sourceWithFileURL: url error: error];
	if (!source)
	{
		return nil;
	}
	return [self indexWithByteSource: source error: error];
}

+ (nullable instancetype)indexWithByteSource:(id<TSSTArchiveByteSource>)source error:(NSError * _Nullable * _Nullable)error
{
	uint64_t fileSize = source.length;
	if (fileSize < kEOCDFixedSize)
	{
		return nil;
	}

	// One read of the tail: up to 22 + max comment length bytes.
	NSUInteger tailWanted = kEOCDFixedSize + kMaxCommentLength;
	NSUInteger tailLength = (NSUInteger)MIN((uint64_t)tailWanted, fileSize);
	uint64_t tailOffset = fileSize - tailLength;

	NSData *tail = [source readAtOffset: tailOffset length: tailLength error: error];
	if (!tail || tail.length != tailLength)
	{
		return nil;
	}

	const uint8_t *tailBytes = tail.bytes;

	// Search backwards for the EOCD signature.
	NSInteger eocdPos = -1;
	if (tailLength >= kEOCDFixedSize)
	{
		for (NSInteger i = (NSInteger)(tailLength - kEOCDFixedSize); i >= 0; --i)
		{
			uint32_t sig;
			memcpy(&sig, tailBytes + i, 4);
			sig = CFSwapInt32LittleToHost(sig);
			if (sig == kEOCDSignature)
			{
				eocdPos = i;
				break;
			}
		}
	}

	if (eocdPos < 0)
	{
		return nil; // not a zip (or a zip with a truncated/corrupt tail) -- fall back to XAD.
	}

	const uint8_t *eocd = tailBytes + eocdPos;
	uint16_t diskNumber          = CFSwapInt16LittleToHost(*(uint16_t *)(eocd + 4));
	uint16_t cdStartDisk         = CFSwapInt16LittleToHost(*(uint16_t *)(eocd + 6));
	uint16_t entriesOnThisDisk   = CFSwapInt16LittleToHost(*(uint16_t *)(eocd + 8));
	uint16_t totalEntries16      = CFSwapInt16LittleToHost(*(uint16_t *)(eocd + 10));
	uint32_t cdSize32            = CFSwapInt32LittleToHost(*(uint32_t *)(eocd + 12));
	uint32_t cdOffset32          = CFSwapInt32LittleToHost(*(uint32_t *)(eocd + 16));

	if (diskNumber != 0 || cdStartDisk != 0 || entriesOnThisDisk != totalEntries16)
	{
		if (error) { *error = [self errorWithCode: TSSTZipIndexErrorMultiDisk description: @"Multi-disk zip archives are not supported."]; }
		return nil;
	}

	uint64_t totalEntries = totalEntries16;
	uint64_t cdSize = cdSize32;
	uint64_t cdOffset = cdOffset32;

	BOOL needsZip64 = (totalEntries16 == 0xFFFF) || (cdSize32 == 0xFFFFFFFF) || (cdOffset32 == 0xFFFFFFFF);

	if (needsZip64)
	{
		// Look for the Zip64 EOCD locator, which sits directly before the EOCD record.
		NSInteger locatorPos = eocdPos - 20;
		if (locatorPos < 0)
		{
			if (error) { *error = [self errorWithCode: TSSTZipIndexErrorCorrupt description: @"Missing Zip64 end-of-central-directory locator."]; }
			return nil;
		}
		const uint8_t *loc = tailBytes + locatorPos;
		uint32_t locSig = CFSwapInt32LittleToHost(*(uint32_t *)(loc));
		if (locSig != kEOCD64LocSignature)
		{
			if (error) { *error = [self errorWithCode: TSSTZipIndexErrorCorrupt description: @"Malformed Zip64 locator."]; }
			return nil;
		}
		uint64_t eocd64Offset = CFSwapInt64LittleToHost(*(uint64_t *)(loc + 8));

		NSData *eocd64Data = [source readAtOffset: eocd64Offset length: 56 error: error];
		if (!eocd64Data || eocd64Data.length != 56)
		{
			if (error && !*error) { *error = [self errorWithCode: TSSTZipIndexErrorCorrupt description: @"Could not read Zip64 end-of-central-directory record."]; }
			return nil;
		}
		const uint8_t *eocd64Buf = eocd64Data.bytes;
		uint32_t rec64Sig = CFSwapInt32LittleToHost(*(uint32_t *)(eocd64Buf));
		if (rec64Sig != kEOCD64Signature)
		{
			if (error) { *error = [self errorWithCode: TSSTZipIndexErrorCorrupt description: @"Malformed Zip64 end-of-central-directory record."]; }
			return nil;
		}
		uint32_t disk64 = CFSwapInt32LittleToHost(*(uint32_t *)(eocd64Buf + 16));
		uint32_t cdStartDisk64 = CFSwapInt32LittleToHost(*(uint32_t *)(eocd64Buf + 20));
		if (disk64 != 0 || cdStartDisk64 != 0)
		{
			if (error) { *error = [self errorWithCode: TSSTZipIndexErrorMultiDisk description: @"Multi-disk zip archives are not supported."]; }
			return nil;
		}
		totalEntries = CFSwapInt64LittleToHost(*(uint64_t *)(eocd64Buf + 32));
		cdSize = CFSwapInt64LittleToHost(*(uint64_t *)(eocd64Buf + 40));
		cdOffset = CFSwapInt64LittleToHost(*(uint64_t *)(eocd64Buf + 48));
	}

	if (cdOffset + cdSize > fileSize)
	{
		if (error) { *error = [self errorWithCode: TSSTZipIndexErrorCorrupt description: @"Central directory extends past end of file."]; }
		return nil;
	}

	if (cdSize == 0 && totalEntries == 0)
	{
		// Empty archive -- still valid.
		TSSTZipIndex *emptyIndex = [[self alloc] init];
		emptyIndex->_source = source;
		emptyIndex->_entries = [NSMutableArray array];
		emptyIndex->_names = [NSMutableArray array];
		emptyIndex->_centralDirectoryData = [NSData data];
		return emptyIndex;
	}

	NSData *cdData = [source readAtOffset: cdOffset length: (NSUInteger)cdSize error: error];
	if (!cdData || cdData.length != cdSize)
	{
		if (error && !*error) { *error = [self errorWithCode: TSSTZipIndexErrorIO description: @"Could not read central directory."]; }
		return nil;
	}

	TSSTZipIndex *index = [[self alloc] init];
	index->_source = source;
	index->_centralDirectoryData = cdData;
	index->_entries = [NSMutableArray arrayWithCapacity: (NSUInteger)totalEntries];
	index->_names = [NSMutableArray arrayWithCapacity: (NSUInteger)totalEntries];

	const uint8_t *base = cdData.bytes;
	NSUInteger len = cdData.length;
	NSUInteger pos = 0;

	while (pos + kCDHeaderFixedSize <= len)
	{
		uint32_t sig = CFSwapInt32LittleToHost(*(uint32_t *)(base + pos));
		if (sig != kCDHeaderSignature)
		{
			break; // stop cleanly; trailing garbage shouldn't crash us.
		}

		uint16_t gpFlag        = CFSwapInt16LittleToHost(*(uint16_t *)(base + pos + 8));
		uint16_t method        = CFSwapInt16LittleToHost(*(uint16_t *)(base + pos + 10));
		uint32_t crc           = CFSwapInt32LittleToHost(*(uint32_t *)(base + pos + 16));
		uint32_t compSize32    = CFSwapInt32LittleToHost(*(uint32_t *)(base + pos + 20));
		uint32_t uncompSize32  = CFSwapInt32LittleToHost(*(uint32_t *)(base + pos + 24));
		uint16_t nameLen       = CFSwapInt16LittleToHost(*(uint16_t *)(base + pos + 28));
		uint16_t extraLen      = CFSwapInt16LittleToHost(*(uint16_t *)(base + pos + 30));
		uint16_t commentLen    = CFSwapInt16LittleToHost(*(uint16_t *)(base + pos + 32));
		uint32_t externalAttrs = CFSwapInt32LittleToHost(*(uint32_t *)(base + pos + 38));
		uint32_t localOffset32 = CFSwapInt32LittleToHost(*(uint32_t *)(base + pos + 42));

		NSUInteger entryStart = pos;
		NSUInteger nameOffset = pos + kCDHeaderFixedSize;
		NSUInteger extraOffset = nameOffset + nameLen;
		NSUInteger commentOffset = extraOffset + extraLen;
		NSUInteger nextPos = commentOffset + commentLen;

		if (nameOffset + nameLen > len || extraOffset + extraLen > len || nextPos > len)
		{
			break; // corrupt/truncated -- stop, keep what we parsed so far is unsafe, bail entirely.
		}

		uint64_t compSize = compSize32;
		uint64_t uncompSize = uncompSize32;
		uint64_t localOffset = localOffset32;

		// Zip64 extra field, if any of the 32-bit fields were the escape value.
		if (compSize32 == 0xFFFFFFFF || uncompSize32 == 0xFFFFFFFF || localOffset32 == 0xFFFFFFFF)
		{
			NSUInteger ePos = extraOffset;
			NSUInteger eEnd = extraOffset + extraLen;
			while (ePos + 4 <= eEnd)
			{
				uint16_t id = CFSwapInt16LittleToHost(*(uint16_t *)(base + ePos));
				uint16_t size = CFSwapInt16LittleToHost(*(uint16_t *)(base + ePos + 2));
				NSUInteger dataStart = ePos + 4;
				if (dataStart + size > eEnd) { break; }
				if (id == kZip64ExtraID)
				{
					NSUInteger fp = dataStart;
					if (uncompSize32 == 0xFFFFFFFF && fp + 8 <= dataStart + size)
					{
						uncompSize = CFSwapInt64LittleToHost(*(uint64_t *)(base + fp));
						fp += 8;
					}
					if (compSize32 == 0xFFFFFFFF && fp + 8 <= dataStart + size)
					{
						compSize = CFSwapInt64LittleToHost(*(uint64_t *)(base + fp));
						fp += 8;
					}
					if (localOffset32 == 0xFFFFFFFF && fp + 8 <= dataStart + size)
					{
						localOffset = CFSwapInt64LittleToHost(*(uint64_t *)(base + fp));
						fp += 8;
					}
				}
				ePos = dataStart + size;
			}
		}

		TSSTZipCDEntry entry;
		entry.nameOffset = nameOffset;
		entry.nameLength = nameLen;
		entry.generalPurposeFlag = gpFlag;
		entry.compressionMethod = method;
		entry.crc32 = crc;
		entry.compressedSize = compSize;
		entry.uncompressedSize = uncompSize;
		entry.localHeaderOffset = localOffset;
		entry.externalAttributes = externalAttrs;

		[index->_entries addObject: [NSValue valueWithBytes: &entry objCType: @encode(TSSTZipCDEntry)]];
		[index->_names addObject: [self decodeName: base + nameOffset length: nameLen flags: gpFlag]];

		pos = nextPos;
		(void)entryStart;
	}

	if (index->_entries.count == 0 && totalEntries > 0)
	{
		// We couldn't parse anything usable; let the caller fall back.
		if (error) { *error = [self errorWithCode: TSSTZipIndexErrorCorrupt description: @"Central directory could not be parsed."]; }
		return nil;
	}

	return index;
}

+ (NSString *)decodeName:(const uint8_t *)bytes length:(NSUInteger)length flags:(uint16_t)flags
{
	if (length == 0)
	{
		return @"";
	}
	if (flags & kGPFlagUTF8)
	{
		NSString *s = [[NSString alloc] initWithBytes: bytes length: length encoding: NSUTF8StringEncoding];
		if (s) { return s; }
	}
	// Try UTF-8 first (the overwhelmingly common case for ASCII names),
	// then fall back to DOS/CP437-ish Latin-1, matching what XAD tends to
	// produce for legacy zips.
	NSString *utf8 = [[NSString alloc] initWithBytes: bytes length: length encoding: NSUTF8StringEncoding];
	if (utf8)
	{
		return utf8;
	}
	NSString *latin1 = [[NSString alloc] initWithBytes: bytes length: length encoding: NSISOLatin1StringEncoding];
	if (latin1)
	{
		return latin1;
	}
	return [[NSString alloc] initWithBytes: bytes length: length encoding: NSASCIIStringEncoding] ?: @"";
}

+ (NSError *)errorWithCode:(TSSTZipIndexError)code description:(NSString *)description
{
	return [NSError errorWithDomain: TSSTZipIndexErrorDomain code: code userInfo: @{ NSLocalizedDescriptionKey: description }];
}

- (void)getEntry:(TSSTZipCDEntry *)outEntry atIndex:(NSUInteger)index
{
	NSValue *v = _entries[index];
	[v getValue: outEntry];
}

#pragma mark - Public accessors

- (NSUInteger)numberOfEntries
{
	return _entries.count;
}

- (NSString *)nameOfEntry:(NSUInteger)index
{
	if (index >= _names.count) { return @""; }
	return _names[index];
}

- (BOOL)entryIsDirectory:(NSUInteger)index
{
	if (index >= _entries.count) { return NO; }
	NSString *name = _names[index];
	if ([name hasSuffix: @"/"])
	{
		return YES;
	}
	TSSTZipCDEntry entry;
	[self getEntry: &entry atIndex: index];
	// Unix external attributes, high 16 bits = st_mode.
	uint32_t unixMode = entry.externalAttributes >> 16;
	if (unixMode != 0 && S_ISDIR(unixMode))
	{
		return YES;
	}
	return NO;
}

- (BOOL)canExtractEntry:(NSUInteger)index
{
	if (index >= _entries.count) { return NO; }
	TSSTZipCDEntry entry;
	[self getEntry: &entry atIndex: index];
	if (entry.generalPurposeFlag & kGPFlagEncrypted) { return NO; }
	if (entry.compressionMethod != 0 && entry.compressionMethod != 8) { return NO; }
	return YES;
}

#pragma mark - Content extraction

- (nullable NSData *)contentsOfEntry:(NSUInteger)index error:(NSError * _Nullable * _Nullable)error
{
	if (index >= _entries.count)
	{
		if (error) { *error = [[self class] errorWithCode: TSSTZipIndexErrorCorrupt description: @"Entry index out of range."]; }
		return nil;
	}

	TSSTZipCDEntry entry;
	[self getEntry: &entry atIndex: index];

	if (entry.generalPurposeFlag & kGPFlagEncrypted)
	{
		if (error) { *error = [[self class] errorWithCode: TSSTZipIndexErrorEncrypted description: @"Entry is encrypted."]; }
		return nil;
	}
	if (entry.compressionMethod != 0 && entry.compressionMethod != 8)
	{
		if (error) { *error = [[self class] errorWithCode: TSSTZipIndexErrorUnsupportedCompression description: @"Unsupported compression method."]; }
		return nil;
	}

	static const NSUInteger kSlack = 256;
	NSUInteger wanted = kLocalHeaderFixedSize + entry.nameLength + kSlack + (NSUInteger)entry.compressedSize;

	NSData *buf = [_source readAtOffset: entry.localHeaderOffset length: wanted error: error];
	if (!buf)
	{
		return nil;
	}
	NSUInteger haveLen = buf.length;
	const uint8_t *bytes = buf.bytes;

	if (haveLen < kLocalHeaderFixedSize)
	{
		if (error) { *error = [[self class] errorWithCode: TSSTZipIndexErrorCorrupt description: @"Truncated local header."]; }
		return nil;
	}

	uint32_t localSig = CFSwapInt32LittleToHost(*(uint32_t *)(bytes));
	if (localSig != kLocalHeaderSignature)
	{
		if (error) { *error = [[self class] errorWithCode: TSSTZipIndexErrorCorrupt description: @"Bad local file header signature."]; }
		return nil;
	}

	uint16_t localNameLen = CFSwapInt16LittleToHost(*(uint16_t *)(bytes + 26));
	uint16_t localExtraLen = CFSwapInt16LittleToHost(*(uint16_t *)(bytes + 28));

	NSUInteger dataOffset = kLocalHeaderFixedSize + localNameLen + localExtraLen;

	if (dataOffset + entry.compressedSize > haveLen)
	{
		// Our slack guess wasn't big enough (unusually large local extra
		// field) -- do a second, precisely-sized read.
		NSUInteger wanted2 = (NSUInteger)dataOffset + (NSUInteger)entry.compressedSize;
		NSData *buf2 = [_source readAtOffset: entry.localHeaderOffset length: wanted2 error: error];
		if (!buf2 || buf2.length < dataOffset + entry.compressedSize)
		{
			if (error && !*error) { *error = [[self class] errorWithCode: TSSTZipIndexErrorCorrupt description: @"Truncated entry data."]; }
			return nil;
		}
		buf = buf2;
		bytes = buf.bytes;
		haveLen = buf.length;
	}

	const uint8_t *compressedStart = bytes + dataOffset;
	NSUInteger compSize = (NSUInteger)entry.compressedSize;

	NSMutableData *output;
	if (entry.compressionMethod == 0)
	{
		if (compSize != (NSUInteger)entry.uncompressedSize)
		{
			if (error) { *error = [[self class] errorWithCode: TSSTZipIndexErrorCorrupt description: @"Stored entry size mismatch."]; }
			return nil;
		}
		output = [NSMutableData dataWithBytes: compressedStart length: compSize];
	}
	else
	{
		NSUInteger outSize = (NSUInteger)entry.uncompressedSize;
		output = [NSMutableData dataWithLength: outSize];

		z_stream strm;
		memset(&strm, 0, sizeof(strm));
		int initErr = inflateInit2(&strm, -MAX_WBITS);
		if (initErr != Z_OK)
		{
			if (error) { *error = [[self class] errorWithCode: TSSTZipIndexErrorZlib description: @"zlib inflateInit2 failed."]; }
			return nil;
		}

		strm.next_in = (Bytef *)compressedStart;
		strm.avail_in = (uInt)compSize;
		strm.next_out = (Bytef *)output.mutableBytes;
		strm.avail_out = (uInt)outSize;

		int result = Z_OK;
		if (outSize > 0)
		{
			result = inflate(&strm, Z_FINISH);
		}
		inflateEnd(&strm);

		if (outSize > 0 && result != Z_STREAM_END)
		{
			if (error) { *error = [[self class] errorWithCode: TSSTZipIndexErrorZlib description: [NSString stringWithFormat: @"zlib inflate failed (code %d).", result]]; }
			return nil;
		}
	}

	uLong crc = crc32(0L, Z_NULL, 0);
	crc = crc32(crc, output.bytes, (uInt)output.length);
	if ((uint32_t)crc != entry.crc32)
	{
		if (error) { *error = [[self class] errorWithCode: TSSTZipIndexErrorCRCMismatch description: @"CRC32 mismatch."]; }
		return nil;
	}

	return output;
}

#pragma mark - Streaming-cache hints

- (uint64_t)dataOffsetHintForEntry:(NSUInteger)index
{
	if (index >= _entries.count) { return 0; }
	TSSTZipCDEntry entry;
	[self getEntry: &entry atIndex: index];
	return entry.localHeaderOffset;
}

- (uint64_t)compressedSizeOfEntry:(NSUInteger)index
{
	if (index >= _entries.count) { return 0; }
	TSSTZipCDEntry entry;
	[self getEntry: &entry atIndex: index];
	return entry.compressedSize;
}

@end
