//
// Copyright 2013 Facebook
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "RunTestsAction.h"

#import "EventBuffer.h"
#import "EventGenerator.h"
#import "OCUnitIOSAppTestRunner.h"
#import "OCUnitIOSDeviceTestRunner.h"
#import "OCUnitIOSLogicTestRunner.h"
#import "OCUnitIOSTestQueryRunner.h"
#import "OCUnitOSXAppTestRunner.h"
#import "OCUnitOSXLogicTestRunner.h"
#import "OCUnitOSXTestQueryRunner.h"
#import "Options.h"
#import "ReporterEvents.h"
#import "ReportStatus.h"
#import "TaskUtil.h"
#import "Testable.h"
#import "TestableExecutionInfo.h"
#import "XcodeSubjectInfo.h"
#import "XCToolUtil.h"

/// Break up an array into chunks of specified size
static NSArray *chunkifyArray(NSArray *array, NSUInteger chunkSize) {
  if (array.count == 0) {
    return @[@[]];
  }

  NSMutableArray *chunks = [NSMutableArray array];
  NSMutableArray *currentChunk = [NSMutableArray array];
  for (id chunk in array) {
    [currentChunk addObject:chunk];
    if (currentChunk.count >= chunkSize) {
      [chunks addObject:currentChunk];
      currentChunk = [NSMutableArray array];
    }
  }
  if (currentChunk.count > 0) {
    [chunks addObject:currentChunk];
  }
  return chunks;
}

NSArray *BucketizeTestCasesByTestCase(NSArray *testCases, int bucketSize)
{
  return chunkifyArray(testCases, bucketSize);
}

NSArray *BucketizeTestCasesByTestClass(NSArray *testCases, int bucketSize)
{
  NSMutableArray *testClassNames = [NSMutableArray array];
  NSMutableDictionary *testCasesByClass = [NSMutableDictionary dictionary];

  for (NSString *classAndMethod in testCases) {
    NSString *className = [classAndMethod componentsSeparatedByString:@"/"][0];

    if (testCasesByClass[className] == nil) {
      testCasesByClass[className] = [NSMutableArray array];
      [testClassNames addObject:className];
    }

    [testCasesByClass[className] addObject:classAndMethod];
  }

  NSArray *testClassNamesChunked = chunkifyArray(testClassNames, bucketSize);

  NSMutableArray *result = [NSMutableArray array];

  for (NSArray *testClassNames in testClassNamesChunked) {
    NSMutableArray *testCasesForClasses = [NSMutableArray array];
    for (NSString *testClassName in testClassNames) {
      [testCasesForClasses addObjectsFromArray:testCasesByClass[testClassName]];
    }
    [result addObject:testCasesForClasses];
  }

  return result;
}

@implementation RunTestsAction

+ (NSString *)name
{
  return @"run-tests";
}

+ (NSArray *)options
{
  return
  @[
    [Action actionOptionWithName:@"test-sdk"
                         aliases:nil
                     description:@"SDK to test with"
                       paramName:@"SDK"
                           mapTo:@selector(setTestSDK:)],
    [Action actionOptionWithName:@"only"
                         aliases:nil
                     description:@"SPEC is TARGET[:Class/case[,Class2/case2]]"
                       paramName:@"SPEC"
                           mapTo:@selector(addOnly:)],
    [Action actionOptionWithName:@"freshSimulator"
                         aliases:nil
                     description:
     @"Start fresh simulator for each application test target"
                         setFlag:@selector(setFreshSimulator:)],
    [Action actionOptionWithName:@"freshInstall"
                         aliases:nil
                     description:
     @"Use clean install of TEST_HOST for every app test run"
                         setFlag:@selector(setFreshInstall:)],
    [Action actionOptionWithName:@"parallelize"
                         aliases:nil
                     description:@"Parallelize execution of tests"
                         setFlag:@selector(setParallelize:)],
    [Action actionOptionWithName:@"logicTestBucketSize"
                         aliases:nil
                     description:@"Break logic test bundles in buckets of N test cases."
                       paramName:@"N"
                           mapTo:@selector(setLogicTestBucketSize:)],
    [Action actionOptionWithName:@"appTestBucketSize"
                         aliases:nil
                     description:@"Break app test bundles in buckets of N test cases."
                       paramName:@"N"
                           mapTo:@selector(setAppTestBucketSize:)],
    [Action actionOptionWithName:@"bucketBy"
                         aliases:nil
                     description:@"Either 'case' (default) or 'class'."
                       paramName:@"BUCKETBY"
                           mapTo:@selector(setBucketBy:)],
    [Action actionOptionWithName:@"simulator"
                         aliases:nil
                     description:@"Set simulator type (either iphone or ipad)"
                       paramName:@"SIMULATOR"
                           mapTo:@selector(setSimulatorType:)],
    ];
}

- (id)init
{
  if (self = [super init]) {
    self.onlyList = [NSMutableArray array];
    _logicTestBucketSize = 0;
    _appTestBucketSize = 0;
    _bucketBy = BucketByTestCase;
  }
  return self;
}

- (void)dealloc {
  self.onlyList = nil;
  self.testSDK = nil;
  self.simulatorType = nil;
  [super dealloc];
}

- (void)addOnly:(NSString *)argument
{
  [self.onlyList addObject:argument];
}

- (void)setLogicTestBucketSize:(NSString *)str
{
  _logicTestBucketSize = [str intValue];
}

- (void)setAppTestBucketSize:(NSString *)str
{
  _appTestBucketSize = [str intValue];
}

- (void)setBucketBy:(NSString *)str
{
  if ([str isEqualToString:@"class"]) {
    _bucketBy = BucketByClass;
  } else {
    _bucketBy = BucketByTestCase;
  }
}

- (NSArray *)onlyListAsTargetsAndSenTestList
{
  NSMutableArray *results = [NSMutableArray array];

  for (NSString *only in self.onlyList) {
    NSRange colonRange = [only rangeOfString:@":"];
    NSString *target = nil;
    NSString *senTestList = nil;

    if (colonRange.length > 0) {
      target = [only substringToIndex:colonRange.location];
      senTestList = [only substringFromIndex:colonRange.location + 1];
    } else {
      target = only;
    }

    [results addObject:@{
     @"target": target,
     @"senTestList": senTestList ? senTestList : [NSNull null]
     }];
  }

  return results;
}

- (BOOL)validateWithOptions:(Options *)options
           xcodeSubjectInfo:(XcodeSubjectInfo *)xcodeSubjectInfo
               errorMessage:(NSString **)errorMessage
{
  if ([self testSDK] == nil && [options sdk] != nil) {
    // If specified test SDKs aren't provided, use whatever we got via -sdk.
    [self setTestSDK:[options sdk]];
  }

  for (NSDictionary *only in [self onlyListAsTargetsAndSenTestList]) {
    if ([xcodeSubjectInfo testableWithTarget:only[@"target"]] == nil) {
      *errorMessage = [NSString stringWithFormat:@"run-tests: '%@' is not a testing target in this scheme.", only[@"target"]];
      return NO;
    }
  }

  return YES;
}

- (BOOL)performActionWithOptions:(Options *)options xcodeSubjectInfo:(XcodeSubjectInfo *)xcodeSubjectInfo
{
  NSArray *testables = nil;

  if (self.onlyList.count == 0) {
    // Use whatever we found in the scheme, except for skipped tests.
    NSMutableArray *unskipped = [NSMutableArray array];
    for (Testable *testable in xcodeSubjectInfo.testables) {
      if (!testable.skipped) {
        [unskipped addObject:testable];
      }
    }
    testables = unskipped;
  } else {
    // Munge the list of testables from the scheme to only include those given.
    NSMutableArray *newTestables = [NSMutableArray array];
    for (NSDictionary *only in [self onlyListAsTargetsAndSenTestList]) {
      Testable *matchingTestable = [xcodeSubjectInfo testableWithTarget:only[@"target"]];

      if (matchingTestable) {
        Testable *newTestable = [[matchingTestable copy] autorelease];

        if (only[@"senTestList"] != [NSNull null]) {
          newTestable.senTestList = only[@"senTestList"];
          newTestable.senTestInvertScope = NO;
        }

        [newTestables addObject:newTestable];
      }
    }
    testables = newTestables;
  }

  if (![self runTestables:testables
                  options:options
         xcodeSubjectInfo:xcodeSubjectInfo]) {
    return NO;
  }

  return YES;
}

/**
 * @return Array on arrays in the form of: [test runner class, GC-enabled boolean]
 */
- (NSArray *)testConfigurationsForBuildSettings:(NSDictionary *)testableBuildSettings
{
  NSString *sdkName = testableBuildSettings[@"SDK_NAME"];
  BOOL isApplicationTest = testableBuildSettings[@"TEST_HOST"] != nil;

  // array of [class, (bool) GC Enabled]
  NSMutableArray *testConfigurations = [NSMutableArray array];

  if ([sdkName hasPrefix:@"iphonesimulator"]) {
    if (isApplicationTest) {
      [testConfigurations addObject:@[[OCUnitIOSAppTestRunner class], @NO]];
    } else {
      [testConfigurations addObject:@[[OCUnitIOSLogicTestRunner class], @NO]];
    }
  } else if ([sdkName hasPrefix:@"macosx"]) {
    Class testClass = {0};
    if (isApplicationTest) {
      testClass = [OCUnitOSXAppTestRunner class];
    } else {
      testClass = [OCUnitOSXLogicTestRunner class];
    }

    NSString *enableGC = testableBuildSettings[@"GCC_ENABLE_OBJC_GC"];

    if ([enableGC isEqualToString:@"required"]) {
      [testConfigurations addObject:@[testClass, @YES]];
    } else if ([enableGC isEqualToString:@"supported"]) {
      // If GC is marked as 'supported', Apple's normal unit-testing harness will run tests twice,
      // once with GC off and once with GC on.
      [testConfigurations addObject:@[testClass, @YES]];
      [testConfigurations addObject:@[testClass, @NO]];
    } else {
      [testConfigurations addObject:@[testClass, @NO]];
    }
  } else if ([sdkName hasPrefix:@"iphoneos"]) {
    [testConfigurations addObject:@[[OCUnitIOSDeviceTestRunner class], @NO]];
  } else {
    NSAssert(NO, @"Unexpected SDK: %@", sdkName);
  }

  return testConfigurations;
}

+ (NSDictionary *)commonOCUnitEventInfoFromTestableExecutionInfo:(TestableExecutionInfo *)testableExecutionInfo
                                        garbageCollectionEnabled:(BOOL)garbageCollectionEnabled
{
  NSMutableDictionary *result = [NSMutableDictionary dictionary];

  if (testableExecutionInfo.buildSettings) {
    BOOL isApplicationTest = testableExecutionInfo.buildSettings[@"TEST_HOST"] != nil;

    result[kReporter_BeginOCUnit_TestTypeKey] = isApplicationTest ? @"application-test" : @"logic-test";
    result[kReporter_BeginOCUnit_GCEnabledKey] = @(garbageCollectionEnabled);
    result[kReporter_BeginOCUnit_SDKNameKey] = testableExecutionInfo.buildSettings[@"SDK_NAME"];
    result[kReporter_BeginOCUnit_BundleNameKey] = testableExecutionInfo.buildSettings[@"FULL_PRODUCT_NAME"];
  }

  result[kReporter_BeginOCUnit_TargetNameKey] = testableExecutionInfo.testable.target;
  
  return result;
}

+ (NSDictionary *)eventForBeginOCUnitFromTestableExecutionInfo:(TestableExecutionInfo *)testableExecutionInfo
                                      garbageCollectionEnabled:(BOOL)garbageCollectionEnabled
{
  return EventDictionaryWithNameAndContent(kReporter_Events_BeginOCUnit,
                                           [self commonOCUnitEventInfoFromTestableExecutionInfo:testableExecutionInfo
                                                                       garbageCollectionEnabled:garbageCollectionEnabled]);
}

+ (NSDictionary *)eventForEndOCUnitFromTestableExecutionInfo:(TestableExecutionInfo *)testableExecutionInfo
                                    garbageCollectionEnabled:(BOOL)garbageCollectionEnabled
                                                   succeeded:(BOOL)succeeded
                                               failureReason:(NSString *)failureReason
{
  NSMutableDictionary *event =
  [NSMutableDictionary dictionaryWithDictionary:
   EventDictionaryWithNameAndContent(kReporter_Events_EndOCUnit,
  @{kReporter_EndOCUnit_SucceededKey: @(succeeded),
    kReporter_EndOCUnit_FailureReasonKey: (failureReason ?: [NSNull null])})];
  [event addEntriesFromDictionary:[self commonOCUnitEventInfoFromTestableExecutionInfo:testableExecutionInfo
                                                              garbageCollectionEnabled:garbageCollectionEnabled]];
  return event;
}

/**
 * Block used to run otest for a test bundle, with a specific test list.
 *
 * @param reporters An array of reporters to fire events to.
 * @return YES if tests ran and all passed.
 */
typedef BOOL (^TestableBlock)(NSArray *reporters);

/**
 * In some cases, we're not going to run the tests for this bundle, but we'd still
 * like to publish the usual begin-ocunit / end-ocunit events so that we have
 * a place to advertise errors.
 */
- (TestableBlock)blockToAdvertiseError:(NSString *)error
              forTestableExecutionInfo:(TestableExecutionInfo *)testableExecutionInfo
                             gcEnabled:(BOOL)garbageCollectionEnabled
{
  return [[^(NSArray *reporters){
    PublishEventToReporters(reporters,
                            [[self class] eventForBeginOCUnitFromTestableExecutionInfo:testableExecutionInfo
                                                              garbageCollectionEnabled:garbageCollectionEnabled]);

    PublishEventToReporters(reporters,
                            [[self class] eventForEndOCUnitFromTestableExecutionInfo:testableExecutionInfo
                                                            garbageCollectionEnabled:garbageCollectionEnabled
                                                                           succeeded:NO
                                                                       failureReason:error]);

    return NO;
  } copy] autorelease];
}

- (TestableBlock)blockForTestable:(Testable *)testable
                 focusedTestCases:(NSArray *)focusedTestCases
                     allTestCases:(NSArray *)allTestCases
            testableExecutionInfo:(TestableExecutionInfo *)testableExecutionInfo
                   testableTarget:(NSString *)testableTarget
                isApplicationTest:(BOOL)isApplicationTest
                        arguments:(NSArray *)arguments
                      environment:(NSDictionary *)environment
                  testRunnerClass:(Class)testRunnerClass
                        gcEnabled:(BOOL)garbageCollectionEnabled
{
  return [[^(NSArray *reporters) {
    OCUnitTestRunner *testRunner = [[[testRunnerClass alloc]
                                     initWithBuildSettings:testableExecutionInfo.buildSettings
                                     focusedTestCases:focusedTestCases
                                     allTestCases:allTestCases
                                     arguments:arguments
                                     environment:environment
                                     garbageCollection:garbageCollectionEnabled
                                     freshSimulator:self.freshSimulator
                                     freshInstall:self.freshInstall
                                     simulatorType:self.simulatorType
                                     reporters:reporters] autorelease];

    PublishEventToReporters(reporters,
                            [[self class] eventForBeginOCUnitFromTestableExecutionInfo:testableExecutionInfo
                                                      garbageCollectionEnabled:garbageCollectionEnabled]);

    NSString *error = nil;
    BOOL succeeded = [testRunner runTestsWithError:&error];

    PublishEventToReporters(reporters,
                            [[self class] eventForEndOCUnitFromTestableExecutionInfo:testableExecutionInfo
                                                    garbageCollectionEnabled:garbageCollectionEnabled
                                                                   succeeded:succeeded
                                                               failureReason:error]);

    return succeeded;
  } copy] autorelease];
}

- (BOOL)runTestables:(NSArray *)testables
             options:(Options *)options
    xcodeSubjectInfo:(XcodeSubjectInfo *)xcodeSubjectInfo
{
  dispatch_queue_t q = dispatch_queue_create("xctool.runtests",
                                             self.parallelize ? DISPATCH_QUEUE_CONCURRENT
                                                              : DISPATCH_QUEUE_SERIAL);
  dispatch_group_t group = dispatch_group_create();

  // Limits the number of outstanding operations.
  // Note that the operation must not acquire this resources in one block and
  // release in another block submitted to the same queue, as it may lead to
  // starvation since the queue may not run the release block.
  dispatch_semaphore_t jobLimiter = dispatch_semaphore_create([[NSProcessInfo processInfo] processorCount]);

  NSMutableArray *blocksToRunOnMainThread = [NSMutableArray array];
  NSMutableArray *blocksToRunOnDispatchQueue = [NSMutableArray array];

  NSArray *xcodebuildArguments = [options commonXcodeBuildArgumentsForSchemeAction:@"TestAction"
                                                                  xcodeSubjectInfo:xcodeSubjectInfo];

  NSMutableArray *testableExecutionInfos = [NSMutableArray array];

  ReportStatusMessageBegin(options.reporters, REPORTER_MESSAGE_INFO,
                           @"Collecting info for testables...");

  for (Testable *testable in testables) {
    dispatch_group_async(group, q, ^{
      dispatch_semaphore_wait(jobLimiter, DISPATCH_TIME_FOREVER);

      TestableExecutionInfo *info = [TestableExecutionInfo infoForTestable:testable
                                                          xcodeSubjectInfo:xcodeSubjectInfo
                                                       xcodebuildArguments:xcodebuildArguments
                                                                   testSDK:_testSDK];

      @synchronized (self) {
        [testableExecutionInfos addObject:info];
      }

      dispatch_semaphore_signal(jobLimiter);
    });
  }

  dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
  ReportStatusMessageEnd(options.reporters, REPORTER_MESSAGE_INFO,
                         @"Collecting info for testables...");

  for (TestableExecutionInfo *info in testableExecutionInfos) {
    if (info.buildSettingsError) {
      TestableBlock block = [self blockToAdvertiseError:info.buildSettingsError
                               forTestableExecutionInfo:info
                                              gcEnabled:NO];
      NSArray *annotatedBlock = @[block, info.testable.target];
      [blocksToRunOnDispatchQueue addObject:annotatedBlock];
      continue;
    }
    
    // array of [class, (bool) GC Enabled]
    NSArray *testConfigurations = [self testConfigurationsForBuildSettings:info.buildSettings];
    BOOL isApplicationTest = info.buildSettings[@"TEST_HOST"] != nil;

    NSArray *testCases = [OCUnitTestRunner filterTestCases:info.testCases
                                           withSenTestList:info.testable.senTestList
                                        senTestInvertScope:info.testable.senTestInvertScope];

    int bucketSize = isApplicationTest ? _appTestBucketSize : _logicTestBucketSize;
    NSArray *testChunks;

    if (_bucketBy == BucketByClass) {
      testChunks = BucketizeTestCasesByTestClass(testCases, bucketSize > 0 ? bucketSize : INT_MAX);
    } else if (_bucketBy == BucketByTestCase) {
      testChunks = BucketizeTestCasesByTestCase(testCases, bucketSize > 0 ? bucketSize : INT_MAX);
    } else {
      NSAssert(NO, @"Unexpected value for _bucketBy: %d", _bucketBy);
    }

    for (NSArray *testConfiguration in testConfigurations) {
      Class testRunnerClass = testConfiguration[0];
      BOOL garbageCollectionEnabled = [testConfiguration[1] boolValue];
      int bucketCount = 1;

      for (NSArray *senTestListChunk in testChunks) {

        TestableBlock block;
        NSString *blockAnnotation;

        if (info.testCasesQueryError != nil) {
          block = [self blockToAdvertiseError:[NSString stringWithFormat:
                                               @"Failed to query the list of test cases in the test bundle: %@", info.testCasesQueryError]
                     forTestableExecutionInfo:info
                                    gcEnabled:garbageCollectionEnabled];
          blockAnnotation = info.buildSettings[@"FULL_PRODUCT_NAME"];
        } else {
          block = [self blockForTestable:info.testable
                        focusedTestCases:senTestListChunk
                            allTestCases:info.testCases
                   testableExecutionInfo:info
                          testableTarget:info.testable.target
                       isApplicationTest:isApplicationTest
                               arguments:info.expandedArguments
                             environment:info.expandedEnvironment
                         testRunnerClass:testRunnerClass
                               gcEnabled:garbageCollectionEnabled];
          blockAnnotation = [NSString stringWithFormat:@"%@ (bucket #%d, %ld tests)",
                             info.buildSettings[@"FULL_PRODUCT_NAME"],
                             bucketCount,
                             [senTestListChunk count]];
        }
        NSArray *annotatedBlock = @[block, blockAnnotation];

        if (isApplicationTest) {
          [blocksToRunOnMainThread addObject:annotatedBlock];
        } else {
          [blocksToRunOnDispatchQueue addObject:annotatedBlock];
        }

        bucketCount++;
      }
    }
  }

  __block BOOL succeeded = YES;
  __block NSMutableArray *bundlesInProgress = [NSMutableArray array];

  void (^runTestableBlockAndSaveSuccess)(TestableBlock, NSString *) = ^(TestableBlock block, NSString *blockAnnotation) {
    NSArray *reporters;

    if (_parallelize) {
      @synchronized (self) {
        [bundlesInProgress addObject:blockAnnotation];
        ReportStatusMessage(options.reporters, REPORTER_MESSAGE_INFO, @"Starting %@", blockAnnotation);
      }
      // Buffer reporter output, and we'll make sure it gets flushed serially
      // when the block is done.
      reporters = [EventBuffer wrapSinks:options.reporters];
    } else {
      reporters = options.reporters;
    }

    BOOL blockSucceeded = block(reporters);

    @synchronized (self) {
      if (_parallelize) {
        [reporters makeObjectsPerformSelector:@selector(flush)];

        [bundlesInProgress removeObject:blockAnnotation];
        if ([bundlesInProgress count] > 0) {
          ReportStatusMessage(options.reporters, REPORTER_MESSAGE_INFO, @"In Progress [%@]", [bundlesInProgress componentsJoinedByString:@", "]);
        }
      }

      succeeded &= blockSucceeded;
    }
  };

  for (NSArray *annotatedBlock in blocksToRunOnDispatchQueue) {
    dispatch_group_async(group, q, ^{
      dispatch_semaphore_wait(jobLimiter, DISPATCH_TIME_FOREVER);

      TestableBlock block = annotatedBlock[0];
      NSString *blockAnnotation = annotatedBlock[1];
      runTestableBlockAndSaveSuccess(block, blockAnnotation);

      dispatch_semaphore_signal(jobLimiter);
    });
  }

  // Wait for logic tests to finish before we start running simulator tests.
  dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

  for (NSArray *annotatedBlock in blocksToRunOnMainThread) {
    TestableBlock block = annotatedBlock[0];
    NSString *blockAnnotation = annotatedBlock[1];
    runTestableBlockAndSaveSuccess(block, blockAnnotation);
  }

  dispatch_release(group);
  dispatch_release(jobLimiter);
  dispatch_release(q);

  return succeeded;
}

@end
