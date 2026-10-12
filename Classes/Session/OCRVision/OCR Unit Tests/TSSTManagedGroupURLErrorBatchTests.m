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
#import "TSSTManagedSession.h"
#import <CoreData/CoreData.h>

// Also covers the scan-lifecycle helpers below (in-flight scan counting and
// temp-file ownership), which need no GUI.
extern NSString *TSSTCreateUnusedTempPath(BOOL isDirectory, NSString *(^candidateName)(NSInteger attempt));


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
{
	NSInteger _loadingChangeCount;
}
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

// The scan helper must run its work inside a batch, and fold the errors the
// work collects into an enclosing batch instead of raising its own alert.
- (void)testBatchHelperJoinsEnclosingBatch
{
	[TSSTManagedGroup beginURLErrorBatchForGroupName: @"Outer"];
	__block NSInteger depthInsideWork = 0;
	[TSSTManagedGroup batchURLErrorsForGroupName: @"Scanned.cbz" during: ^(NSMutableArray<NSError *> *errors) {
		depthInsideWork = [TSSTManagedGroup urlErrorBatchDepthForTesting];
		[errors addObject: [self sampleErrorWithDescription: @"a"]];
		[errors addObject: [self sampleErrorWithDescription: @"b"]];
	}];
	XCTAssertEqual(depthInsideWork, 2);
	XCTAssertEqual([TSSTManagedGroup urlErrorBatchDepthForTesting], 1);
	XCTAssertEqual([TSSTManagedGroup pendingURLErrorCountForTesting], 2u);
}

// No errors means no alert (a non-empty standalone batch would run a modal).
- (void)testBatchHelperWithNoErrorsEndsCleanly
{
	[TSSTManagedGroup batchURLErrorsForGroupName: @"Clean.cbz" during: ^(NSMutableArray<NSError *> *errors) {}];
	XCTAssertEqual([TSSTManagedGroup urlErrorBatchDepthForTesting], 0);
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

#pragma mark - Scan lifecycle

/// Observes "loading" changes, to prove the derived property is KVO-compliant.
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	_loadingChangeCount++;
}

// Overlapping adds to one session each count their archives; the session is
// "loading" until the last scan has landed, not the first.
- (void)testSessionStaysLoadingUntilEveryPendingScanFinishes
{
	NSManagedObjectModel *model = [NSManagedObjectModel mergedModelFromBundles: nil];
	NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel: model];
	NSError *error = nil;
	XCTAssertNotNil([coordinator addPersistentStoreWithType: NSInMemoryStoreType configuration: nil URL: nil options: nil error: &error], @"%@", error);
	NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType: NSMainQueueConcurrencyType];
	context.persistentStoreCoordinator = coordinator;
	TSSTManagedSession *session = [NSEntityDescription insertNewObjectForEntityForName: @"Session" inManagedObjectContext: context];

	XCTAssertFalse(session.isLoading);
	_loadingChangeCount = 0;
	[session addObserver: self forKeyPath: @"loading" options: 0 context: NULL];

	session.pendingScanCount++;   // first addFileURLs:toSession: call
	session.pendingScanCount++;   // second call while the first still scans
	XCTAssertTrue(session.isLoading);
	XCTAssertEqual(_loadingChangeCount, 2, @"loading is KVO-observable through pendingScanCount");

	session.pendingScanCount--;   // first scan lands
	XCTAssertTrue(session.isLoading, @"the second scan is still in flight");
	session.pendingScanCount--;
	XCTAssertFalse(session.isLoading);

	[session removeObserver: self forKeyPath: @"loading"];
}

// A scan record that is dropped (its session was deleted) must take its temp
// files with it, including those of nested archives and PDFs.
- (void)testDiscardScanRecordRemovesTempItemsRecursively
{
	NSFileManager *fileManager = NSFileManager.defaultManager;
	NSString *solid = TSSTCreateUnusedTempPath(YES, ^NSString *(NSInteger n) { return [NSString stringWithFormat: @"SC-test-solid-%li", (long)n]; });
	NSString *nestedArchive = TSSTCreateUnusedTempPath(NO, ^NSString *(NSInteger n) { return [NSString stringWithFormat: @"SC-test-%li-nested.zip", (long)n]; });
	NSString *nestedSolid = TSSTCreateUnusedTempPath(YES, ^NSString *(NSInteger n) { return [NSString stringWithFormat: @"SC-test-nsolid-%li", (long)n]; });
	NSString *deepPDF = TSSTCreateUnusedTempPath(NO, ^NSString *(NSInteger n) { return [NSString stringWithFormat: @"SC-test-%li-deep.pdf", (long)n]; });

	TSSTArchiveScanRecord *pdf = [TSSTArchiveScanRecord new];
	[pdf setValue: deepPDF forKey: @"path"];
	TSSTArchiveScanRecord *nested = [TSSTArchiveScanRecord new];
	[nested setValue: nestedArchive forKey: @"path"];
	[nested setValue: nestedSolid forKey: @"solidDirectory"];
	[nested setValue: @[pdf] forKey: @"children"];
	TSSTArchiveScanRecord *top = [TSSTArchiveScanRecord new];
	[top setValue: solid forKey: @"solidDirectory"];
	[top setValue: @[nested] forKey: @"children"];

	for (NSString *path in @[solid, nestedArchive, nestedSolid, deepPDF]) {
		XCTAssertTrue([fileManager fileExistsAtPath: path]);
	}
	[TSSTManagedArchive discardScanRecord: top];
	for (NSString *path in @[solid, nestedArchive, nestedSolid, deepPDF]) {
		XCTAssertFalse([fileManager fileExistsAtPath: path], @"%@ should have been removed", path);
	}
}

// Picking a temp name must claim it, so concurrent scans never share a path.
- (void)testCreateUnusedTempPathIsUniqueAcrossThreads
{
	const NSUInteger count = 64;
	NSMutableArray<NSString *> *paths = [NSMutableArray array];
	dispatch_group_t group = dispatch_group_create();
	for (NSUInteger i = 0; i < count; ++i) {
		dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			// Every caller proposes the same sequence of names.
			NSString *path = TSSTCreateUnusedTempPath(i % 2 == 0, ^NSString *(NSInteger n) {
				return [NSString stringWithFormat: @"SC-test-unique-%li", (long)n];
			});
			@synchronized (paths) { [paths addObject: path]; }
		});
	}
	XCTAssertEqual(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)), 0);

	XCTAssertEqual([NSSet setWithArray: paths].count, count, @"two callers were handed the same path");
	for (NSString *path in paths) {
		XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath: path]);
		[NSFileManager.defaultManager removeItemAtPath: path error: NULL];
	}
}

@end
