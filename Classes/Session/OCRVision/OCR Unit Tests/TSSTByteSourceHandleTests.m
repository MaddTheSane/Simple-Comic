//
//  TSSTByteSourceHandleTests.m
//  OCR Unit Tests
//
//  Verifies TSSTByteSourceHandle (the CSHandle adapter XAD's parsers read
//  archives through) against a plain in-memory byte source: random
//  seek/read parity, -initAsCopyOf: independence, and EOF behavior.
//

#import <XCTest/XCTest.h>
#import "TSSTByteSourceHandle.h"

/// A trivial in-memory byte source for testing the handle adapter,
/// independent of TSSTFileByteSource.
@interface TSSTMemoryByteSourceForHandleTests : NSObject <TSSTArchiveByteSource>
- (instancetype)initWithData:(NSData *)data;
@end

@implementation TSSTMemoryByteSourceForHandleTests
{
	NSData *_data;
}

- (instancetype)initWithData:(NSData *)data
{
	if (self = [super init]) _data = [data copy];
	return self;
}

- (uint64_t)length
{
	return _data.length;
}

- (NSData *)readAtOffset:(uint64_t)offset length:(NSUInteger)length error:(NSError **)error
{
	if (offset > _data.length) {
		if (error) *error = [NSError errorWithDomain: TSSTArchiveByteSourceErrorDomain code: TSSTArchiveByteSourceErrorOffsetPastEOF userInfo: nil];
		return nil;
	}
	NSUInteger available = (NSUInteger)MIN((uint64_t)length, _data.length - offset);
	return [_data subdataWithRange: NSMakeRange((NSUInteger)offset, available)];
}

@end

/// Counts requests through a timeless simulated link, wrapping the plain
/// memory source, to verify the handle's read-ahead buffer coalesces XAD's
/// small reads into few upstream requests.
@interface TSSTByteSourceHandleBufferingTests : XCTestCase
@property (nonatomic, strong) NSData *referenceData;
@end

@implementation TSSTByteSourceHandleBufferingTests

- (void)setUp
{
	[super setUp];
	NSMutableData *data = [NSMutableData dataWithLength: 500 * 1024];
	uint8_t *bytes = data.mutableBytes;
	srandom(42);
	for (NSUInteger i = 0; i < data.length; i++) bytes[i] = (uint8_t)(random() & 0xFF);
	self.referenceData = data;
}

- (void)testSmallReadsAndInBufferSeeksCoalesceIntoFewRequests
{
	id<TSSTArchiveByteSource> memory = [[TSSTMemoryByteSourceForHandleTests alloc] initWithData: self.referenceData];
	TSSTSimulatedLinkByteSource *link = [TSSTSimulatedLinkByteSource lanLinkWrapping: memory];
	link.simulateTime = NO;

	TSSTByteSourceHandle *handle = [[TSSTByteSourceHandle alloc] initWithByteSource: link];

	uint8_t buf[100];
	for (int i = 0; i < 20; i++) {
		XCTAssertEqual([handle readAtMost: sizeof(buf) toBuffer: buf], (int)sizeof(buf));
	}
	XCTAssertEqual(link.readCount, (NSUInteger)1, @"sequential small reads within the read-ahead buffer should not each hit the source");

	// A backward seek that stays inside the buffered region must not refill.
	[handle seekToFileOffset: 4];
	XCTAssertEqual([handle readAtMost: sizeof(buf) toBuffer: buf], (int)sizeof(buf));
	XCTAssertEqual(link.readCount, (NSUInteger)1);

	// A seek far outside the buffered region forces exactly one more request.
	[handle seekToFileOffset: 200 * 1024];
	XCTAssertEqual([handle readAtMost: sizeof(buf) toBuffer: buf], (int)sizeof(buf));
	XCTAssertEqual(link.readCount, (NSUInteger)2);
}

/// File extraction reads sequentially in small pieces; every upstream request
/// costs a round trip on a slow link, so the read-ahead has to ramp up to
/// large requests and stay there instead of paying one round trip per 64 KB.
- (void)testSequentialReadsRampToLargeRequestsAndKeepTheirSize
{
	NSMutableData *data = [NSMutableData dataWithLength: 6 * 1024 * 1024];
	uint8_t *bytes = data.mutableBytes;
	for (NSUInteger i = 0; i < data.length; i++) bytes[i] = (uint8_t)(i * 31);
	id<TSSTArchiveByteSource> memory = [[TSSTMemoryByteSourceForHandleTests alloc] initWithData: data];
	TSSTSimulatedLinkByteSource *link = [TSSTSimulatedLinkByteSource smbWifiLinkWrapping: memory];
	link.simulateTime = NO;
	link.logsRequests = YES;

	TSSTByteSourceHandle *handle = [[TSSTByteSourceHandle alloc] initWithByteSource: link];
	uint8_t buf[16 * 1024];
	NSUInteger total = 0;
	while (total < data.length) {
		int got = [handle readAtMost: sizeof(buf) toBuffer: buf];
		XCTAssertGreaterThan(got, 0);
		if (got <= 0) break;
		XCTAssertEqual(memcmp(buf, (const uint8_t *)data.bytes + total, (size_t)got), 0);
		total += (NSUInteger)got;
	}
	XCTAssertEqual(total, data.length);
	// 4 KB, 64 KB, then 1 MB requests: 6 MB needs about 8, not ~100.
	XCTAssertLessThanOrEqual(link.readCount, (NSUInteger)10, @"sequential reads should ramp up to ~1 MB requests");
	NSUInteger largest = 0;
	for (NSValue *v in link.requestLog) largest = MAX(largest, v.rangeValue.length);
	XCTAssertGreaterThanOrEqual(largest, (NSUInteger)(512 * 1024));

	// Seeking away starts over small (a header walk should not pay for a big block).
	NSUInteger before = link.requestLog.count;
	[handle seekToFileOffset: 100];
	XCTAssertEqual([handle readAtMost: sizeof(buf) toBuffer: buf], (int)sizeof(buf));
	XCTAssertEqual(link.requestLog.count, before + 1);
	XCTAssertLessThanOrEqual(link.requestLog.lastObject.rangeValue.length, (NSUInteger)(16 * 1024));
}

@end

@interface TSSTByteSourceHandleTests : XCTestCase
@property (nonatomic, strong) NSData *referenceData;
@end

@implementation TSSTByteSourceHandleTests

- (void)setUp
{
	[super setUp];
	NSMutableData *data = [NSMutableData dataWithLength: 500 * 1024]; // spans several read-ahead buffers
	uint8_t *bytes = data.mutableBytes;
	srandom(12345);
	for (NSUInteger i = 0; i < data.length; i++) bytes[i] = (uint8_t)(random() & 0xFF);
	self.referenceData = data;
}

- (TSSTByteSourceHandle *)makeHandle
{
	id<TSSTArchiveByteSource> source = [[TSSTMemoryByteSourceForHandleTests alloc] initWithData: self.referenceData];
	return [[TSSTByteSourceHandle alloc] initWithByteSource: source];
}

- (void)testSequentialReadMatchesReference
{
	TSSTByteSourceHandle *handle = [self makeHandle];
	NSMutableData *read = [NSMutableData data];
	uint8_t buf[4096];
	int n;
	while ((n = [handle readAtMost: sizeof(buf) toBuffer: buf]) > 0) {
		[read appendBytes: buf length: (NSUInteger)n];
	}
	XCTAssertEqualObjects(read, self.referenceData);
	XCTAssertTrue(handle.atEndOfFile);
}

- (void)testRandomSeekReadMatchesReference
{
	TSSTByteSourceHandle *handle = [self makeHandle];
	srandom(999);
	for (int trial = 0; trial < 500; trial++) {
		NSUInteger dataLength = self.referenceData.length;
		off_t offset = (off_t)(random() % dataLength);
		NSUInteger length = 1 + (NSUInteger)(random() % 8192);
		length = MIN(length, dataLength - (NSUInteger)offset);

		[handle seekToFileOffset: offset];
		XCTAssertEqual(handle.offsetInFile, offset);

		NSMutableData *read = [NSMutableData dataWithLength: length];
		NSUInteger got = 0;
		while (got < length) {
			int n = [handle readAtMost: (int)(length - got) toBuffer: (uint8_t *)read.mutableBytes + got];
			if (n <= 0) break;
			got += (NSUInteger)n;
		}
		NSData *expected = [self.referenceData subdataWithRange: NSMakeRange((NSUInteger)offset, length)];
		XCTAssertEqualObjects(read, expected, @"mismatch at offset %lld length %lu", (long long)offset, (unsigned long)length);
	}
}

- (void)testSeekWithinBufferedRegionKeepsBuffer
{
	TSSTByteSourceHandle *handle = [self makeHandle];
	uint8_t buf[16];
	// Prime the read-ahead buffer.
	XCTAssertEqual([handle readAtMost: sizeof(buf) toBuffer: buf], (int)sizeof(buf));
	// Seek backwards, still inside what should be buffered (64 KB read-ahead).
	[handle seekToFileOffset: 4];
	uint8_t buf2[8];
	XCTAssertEqual([handle readAtMost: sizeof(buf2) toBuffer: buf2], (int)sizeof(buf2));
	NSData *expected = [self.referenceData subdataWithRange: NSMakeRange(4, 8)];
	XCTAssertEqualObjects([NSData dataWithBytes: buf2 length: sizeof(buf2)], expected);
}

- (void)testSeekToEndOfFileAndAtEndOfFile
{
	TSSTByteSourceHandle *handle = [self makeHandle];
	XCTAssertFalse(handle.atEndOfFile);
	[handle seekToEndOfFile];
	XCTAssertTrue(handle.atEndOfFile);
	XCTAssertEqual(handle.offsetInFile, (off_t)self.referenceData.length);

	uint8_t buf[16];
	XCTAssertEqual([handle readAtMost: sizeof(buf) toBuffer: buf], 0);
}

- (void)testCopyIsIndependentPosition
{
	TSSTByteSourceHandle *handle = [self makeHandle];
	[handle seekToFileOffset: 100];
	// Prime a live read-ahead buffer before copying, so the copy shares a
	// real buffer with the original rather than starting from nil.
	uint8_t prime[8];
	XCTAssertEqual([handle readAtMost: sizeof(prime) toBuffer: prime], (int)sizeof(prime));
	[handle seekToFileOffset: 100];

	TSSTByteSourceHandle *copy = [[TSSTByteSourceHandle alloc] initAsCopyOf: handle];
	XCTAssertEqual(copy.offsetInFile, handle.offsetInFile);

	[copy seekToFileOffset: 999];
	XCTAssertEqual(handle.offsetInFile, (off_t)100, @"seeking the copy must not move the original");

	uint8_t bufOrig[8], bufCopy[8];
	XCTAssertEqual([handle readAtMost: sizeof(bufOrig) toBuffer: bufOrig], (int)sizeof(bufOrig));
	XCTAssertEqual([copy readAtMost: sizeof(bufCopy) toBuffer: bufCopy], (int)sizeof(bufCopy));

	NSData *expectedOrig = [self.referenceData subdataWithRange: NSMakeRange(100, 8)];
	NSData *expectedCopy = [self.referenceData subdataWithRange: NSMakeRange(999, 8)];
	XCTAssertEqualObjects([NSData dataWithBytes: bufOrig length: 8], expectedOrig);
	XCTAssertEqualObjects([NSData dataWithBytes: bufCopy length: 8], expectedCopy);
}

- (void)testLargeReadBypassingBuffer
{
	TSSTByteSourceHandle *handle = [self makeHandle];
	NSUInteger length = self.referenceData.length; // whole file, forces the >=64KB path
	NSMutableData *read = [NSMutableData dataWithLength: length];
	NSUInteger got = 0;
	while (got < length) {
		int n = [handle readAtMost: (int)(length - got) toBuffer: (uint8_t *)read.mutableBytes + got];
		if (n <= 0) break;
		got += (NSUInteger)n;
	}
	XCTAssertEqualObjects(read, self.referenceData);
}

@end
