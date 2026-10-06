//
//  TSSTManagedGroupURLErrorBatchTests.m
//  Regression tests for the per-archive alert-dedup fix (#147, #123).
//
//  setFileURL:/fileURL used to call -[NSApp presentError:] once per bad file
//  while scanning a folder/archive, so a container with many unreadable
//  entries could pop up dozens of modal alerts in a row. These tests only
//  exercise the accumulation/routing logic (+beginURLErrorBatchForGroupName:,
//  +reportURLError:, and the pure summary-message builder); they deliberately
//  never let the batch depth drop back to 0 with pending errors, since
//  that path calls -[NSAlert runModal] and would hang the test run.
//

#import <XCTest/XCTest.h>
#import "TSSTManagedGroup.h"

@interface TSSTManagedGroup (Testing)
+ (void)beginURLErrorBatchForGroupName:(NSString *)groupName;
+ (void)endURLErrorBatch;
+ (void)reportURLError:(NSError *)error;
+ (nullable NSString *)urlErrorBatchSummaryMessageForErrorCount:(NSUInteger)errorCount groupName:(NSString *)groupName;
+ (NSInteger)urlErrorBatchDepthForTesting;
+ (NSUInteger)pendingURLErrorCountForTesting;
+ (void)resetURLErrorBatchStateForTesting;
@end

@interface TSSTManagedGroupURLErrorBatchTests : XCTestCase
@end

@implementation TSSTManagedGroupURLErrorBatchTests

- (void)setUp
{
	[super setUp];
	[TSSTManagedGroup resetURLErrorBatchStateForTesting];
}

- (void)tearDown
{
	[TSSTManagedGroup resetURLErrorBatchStateForTesting];
	[super tearDown];
}

- (NSError *)sampleErrorWithDescription:(NSString *)description
{
	return [NSError errorWithDomain: @"TSSTManagedGroupURLErrorBatchTests"
								code: 1
							userInfo: @{NSLocalizedDescriptionKey: description}];
}

// While a batch is active (depth > 0), reportURLError: must queue instead of
// presenting immediately - this is the core of the #147/#123 fix.
- (void)testReportURLErrorQueuesWhileBatchIsActive
{
	[TSSTManagedGroup beginURLErrorBatchForGroupName: @"Bad Archive.cbz"];
	XCTAssertEqual([TSSTManagedGroup urlErrorBatchDepthForTesting], 1);
	XCTAssertEqual([TSSTManagedGroup pendingURLErrorCountForTesting], 0u);

	[TSSTManagedGroup reportURLError: [self sampleErrorWithDescription: @"bad entry 1"]];
	[TSSTManagedGroup reportURLError: [self sampleErrorWithDescription: @"bad entry 2"]];
	[TSSTManagedGroup reportURLError: [self sampleErrorWithDescription: @"bad entry 3"]];

	XCTAssertEqual([TSSTManagedGroup pendingURLErrorCountForTesting], 3u,
		@"all three errors should be queued instead of presented as separate alerts");
}

// nestedFolderContents/nestedArchiveContents can recurse into nested archives,
// which each bracket themselves with begin/end - the depth counter must nest
// correctly so only the outermost scan triggers the summary alert.
- (void)testNestedBatchesShareOneAccumulator
{
	[TSSTManagedGroup beginURLErrorBatchForGroupName: @"Outer.cbz"];
	[TSSTManagedGroup reportURLError: [self sampleErrorWithDescription: @"outer bad entry"]];

	[TSSTManagedGroup beginURLErrorBatchForGroupName: @"Nested.cbz"];
	XCTAssertEqual([TSSTManagedGroup urlErrorBatchDepthForTesting], 2,
		@"a nested scan should increase depth rather than starting a fresh batch");
	[TSSTManagedGroup reportURLError: [self sampleErrorWithDescription: @"nested bad entry"]];

	// Simulate the nested scan finishing: depth drops to 1, batch stays open,
	// so this must not present an alert (which would hang the test).
	[TSSTManagedGroup endURLErrorBatch];
	XCTAssertEqual([TSSTManagedGroup urlErrorBatchDepthForTesting], 1);
	XCTAssertEqual([TSSTManagedGroup pendingURLErrorCountForTesting], 2u,
		@"errors from both the outer and nested scan should accumulate in one batch");
}

// Scans run on background threads: a scan's batch must not see, or be
// polluted by, errors reported from another thread's scan.
- (void)testBatchesAreIsolatedPerThread
{
	[TSSTManagedGroup beginURLErrorBatchForGroupName: @"Main.cbz"];
	[TSSTManagedGroup reportURLError: [self sampleErrorWithDescription: @"main bad entry"]];

	XCTestExpectation *done = [self expectationWithDescription: @"background scan"];
	NSThread *thread = [[NSThread alloc] initWithBlock: ^{
		XCTAssertEqual([TSSTManagedGroup urlErrorBatchDepthForTesting], 0,
			@"a new thread must not inherit another thread's batch");
		[TSSTManagedGroup beginURLErrorBatchForGroupName: @"Background.cbz"];
		[TSSTManagedGroup reportURLError: [self sampleErrorWithDescription: @"background bad entry"]];
		XCTAssertEqual([TSSTManagedGroup pendingURLErrorCountForTesting], 1u);
		[done fulfill];
	}];
	[thread start];
	[self waitForExpectations: @[done] timeout: 10];

	XCTAssertEqual([TSSTManagedGroup urlErrorBatchDepthForTesting], 1);
	XCTAssertEqual([TSSTManagedGroup pendingURLErrorCountForTesting], 1u,
		@"the background thread's error must not land in the main thread's batch");
}

// A single top-level file open (no active scan) is the pre-existing behavior:
// it should NOT be queued. We only assert on depth here rather than calling
// reportURLError: at depth 0, since that would call -[NSApp presentError:].
- (void)testNoActiveBatchByDefault
{
	XCTAssertEqual([TSSTManagedGroup urlErrorBatchDepthForTesting], 0);
	XCTAssertEqual([TSSTManagedGroup pendingURLErrorCountForTesting], 0u);
}

- (void)testSummaryMessageForZeroErrorsIsNil
{
	XCTAssertNil([TSSTManagedGroup urlErrorBatchSummaryMessageForErrorCount: 0 groupName: @"Some Folder"]);
}

- (void)testSummaryMessageForSingleErrorUsesSingularWording
{
	NSString *message = [TSSTManagedGroup urlErrorBatchSummaryMessageForErrorCount: 1 groupName: @"Some Folder"];
	XCTAssertTrue([message containsString: @"1 file"]);
	XCTAssertTrue([message containsString: @"Some Folder"]);
}

- (void)testSummaryMessageForMultipleErrorsIncludesCount
{
	NSString *message = [TSSTManagedGroup urlErrorBatchSummaryMessageForErrorCount: 42 groupName: @"Some Folder"];
	XCTAssertTrue([message containsString: @"42 files"]);
	XCTAssertTrue([message containsString: @"Some Folder"]);
}

@end
