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

#import "OCUnitTestQueryRunner.h"

#import "TaskUtil.h"
#import "XCToolUtil.h"

@implementation OCUnitTestQueryRunner

// Designated initializer.
- (instancetype)initWithBuildSettings:(NSDictionary *)buildSettings
{
  if (self = [super init]) {
    _buildSettings = [buildSettings retain];
    _cpuType = CPU_TYPE_ANY;
  }
  return self;
}

- (void)dealloc
{
  [_buildSettings release];
  [super dealloc];
}

- (NSString *)bundlePath
{
  NSString *builtProductsDir = _buildSettings[@"BUILT_PRODUCTS_DIR"];
  NSString *fullProductName = _buildSettings[@"FULL_PRODUCT_NAME"];
  NSString *bundlePath = [builtProductsDir stringByAppendingPathComponent:fullProductName];
  return bundlePath;
}

- (NSString *)testHostPath
{
  // TEST_HOST will sometimes be wrapped in "quotes".
  NSString *testHost = [_buildSettings[@"TEST_HOST"]
                        stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
  return testHost;
}

- (NSTask *)createTaskForQuery
{
  return nil;
}

- (NSArray *)runQueryWithError:(NSString **)error
{
  BOOL bundleIsDir = NO;
  BOOL bundleExists = [[NSFileManager defaultManager] fileExistsAtPath:[self bundlePath] isDirectory:&bundleIsDir];
  if (!IsRunningUnderTest() && !(bundleExists && bundleIsDir)) {
    *error = [NSString stringWithFormat:@"Test bundle not found at: %@", [self bundlePath]];
    return nil;
  }

  if ([self testHostPath]) {
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:[self testHostPath]]) {
      *error = [NSString stringWithFormat:@"The test host executable is missing: '%@'", [self testHostPath]];
      return nil;
    }
  }

  NSTask *task = [self createTaskForQuery];
  NSDictionary *output = LaunchTaskAndCaptureOutput(task, @"running otest-query");
  [task release];

  if ([task terminationStatus] != 0) {
    *error = output[@"stderr"];
    return nil;
  } else {
    NSString *jsonOutput = output[@"stdout"];

    NSError *parseError = nil;
    NSArray *list = [NSJSONSerialization JSONObjectWithData:[jsonOutput dataUsingEncoding:NSUTF8StringEncoding]
                                                    options:0
                                                      error:&parseError];
    if (list) {
      return list;
    } else {
      *error = [NSString stringWithFormat:@"Error while parsing JSON: %@: %@",
                [parseError localizedFailureReason],
                jsonOutput];
      return nil;
    }
  }
}

@end
