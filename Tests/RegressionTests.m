#import <Foundation/Foundation.h>
#import "../Shared/NSStore.h"
#import "../Shared/NSDestination.h"
#import "../Shared/NSPermissionQueue.h"
#import "../FilterControl/NSPermissionNotifications.h"
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>

static NSUInteger checks;
#define CHECK(...)                                                                                           \
    do {                                                                                                     \
        checks++;                                                                                            \
        if (!(__VA_ARGS__)) {                                                                                \
            NSLog(@"FAIL %s:%d: %s", __FILE__, __LINE__, #__VA_ARGS__);                                      \
            abort();                                                                                         \
        }                                                                                                    \
    } while (0)

static NSPolicy *Policy(NSDictionary *rules) {
    NSMutableDictionary *document = [[NSPolicy defaultDocument] mutableCopy];
    document[@"rules"] = rules;
    return [NSPolicy policyWithDocument:document error:NULL];
}
static NSDictionary *Monitor(NSArray *requests, BOOL running, NSInteger engine, NSDate *updated) {
    return @{
        @"schema" : @2,
        @"engine" : @(engine),
        @"updated" : updated,
        @"lastReport" : updated,
        @"controlRunning" : @(running),
        @"policyError" : @"",
        @"events" : @[],
        @"requests" : requests
    };
}
static void SaveRule(NSString *identity, NSString *action) {
    CHECK(NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *document, NSError **error) {
            document[@"rules"][identity] = action;
            return YES;
        },
        NULL));
}
static void TestPolicyAndCache(void) {
    CHECK(NSEnsurePolicy(NULL));
    NSPolicy *first = NSReadPolicy(NULL);
    CHECK(first != nil);
    CHECK(first == NSReadPolicy(NULL));
    SaveRule(@"test.app", @"block");
    CHECK(![NSReadPolicy(NULL) allowsIdentity:@"test.app" direction:NSFlowDirectionOutbound]);
    CHECK([first requiresPermissionForIdentity:@"test.app"]);
    CHECK(NSReadPolicy(NULL) != first);
    CHECK(!NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *document, NSError **error) {
            document[@"default"] = @"invalid";
            return YES;
        },
        NULL));
    CHECK([NSReadPolicy(NULL).document[@"rules"][@"test.app"] isEqual:@"block"]);
}

static void TestStorageFailureAndRecovery(void) {
    NSURL *url = NSSharedURL(NSPolicyFile);
    CHECK([[@"broken" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url atomically:YES]);
    CHECK(NSReadPolicy(NULL) == nil);
    CHECK(!NSEnsurePolicy(NULL));
    CHECK(!NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *document, NSError **error) {
            return YES;
        },
        NULL));
    CHECK(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
    CHECK(NSReadPolicy(NULL) != nil);
    CHECK([NSFileManager.defaultManager removeItemAtURL:url error:NULL]);
    CHECK(NSReadPolicy(NULL) == nil);
    CHECK(NSEnsurePolicy(NULL));
    if (geteuid() != 0) {
        CHECK(chmod(url.fileSystemRepresentation, 0000) == 0);
        NSError *accessError = nil;
        CHECK(NSReadPolicy(&accessError) == nil);
        CHECK([accessError.domain isEqual:NSPOSIXErrorDomain] && accessError.code == EACCES);
        CHECK(chmod(url.fileSystemRepresentation, 0600) == 0);
        CHECK(NSReadPolicy(NULL) != nil);
    }
    NSPolicy *policy = NSReadPolicy(NULL);
    NSMutableDictionary *replacement = [policy.document mutableCopy];
    replacement[@"default"] = @"block";
    // Even an external replacement that reuses the revision must invalidate the cache.
    CHECK(NSWriteDocument(replacement, NSPolicyFile, NULL));
    CHECK(NSReadPolicy(NULL) != policy);
    CHECK(![NSReadPolicy(NULL) allowsIdentity:@"new.app" direction:NSFlowDirectionOutbound]);
    NSMutableData *oversized = [NSMutableData dataWithLength:NSMaximumDocumentBytes + 1];
    CHECK([oversized writeToURL:url atomically:YES]);
    CHECK(NSReadPolicy(NULL) == nil);
    CHECK(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
}
static void TestConcurrentMutations(void) {
    dispatch_apply(32, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t index) {
        @autoreleasepool {
            BOOL saved = NO;
            for (NSUInteger attempt = 0; attempt < 10000 && !saved; attempt++) {
                NSError *error = nil;
                saved = NSUpdatePolicy(
                    ^BOOL(NSMutableDictionary *document, NSError **mutationError) {
                        document[@"rules"][[NSString stringWithFormat:@"parallel.%zu", index]] = @"block";
                        return YES;
                    },
                    &error);
                if (!saved) {
                    if (![error.domain isEqual:NSPOSIXErrorDomain] || error.code != EWOULDBLOCK) {
                        abort();
                    }
                    usleep(1000);
                }
            }
            if (!saved) {
                abort();
            }
        }
    });
    for (NSUInteger index = 0; index < 32; index++) {
        CHECK([NSReadPolicy(NULL).document[@"rules"][
            [NSString stringWithFormat:@"parallel.%lu", (unsigned long)index]] isEqual:@"block"]);
    }
}
static void TestPermissionQueue(void) {
    NSPermissionQueue *queue = [NSPermissionQueue new];
    __block NSUInteger completions = 0;
    for (NSUInteger index = 0; index < NSMaximumActiveRequests; index++) {
        CHECK([queue enqueueIdentity:[NSString stringWithFormat:@"app.%lu", (unsigned long)index]
                           direction:NSFlowDirectionOutbound
                                 now:0
                                date:NSDate.date
                          completion:^(BOOL allow) {
                              CHECK(!allow);
                              completions++;
                          }] != nil);
    }
    CHECK([queue enqueueIdentity:@"overflow"
                       direction:NSFlowDirectionOutbound
                             now:1
                            date:NSDate.date
                      completion:^(BOOL allow) {
                          CHECK(!allow);
                          completions++;
                      }] == nil);
    CHECK(queue.overflowCount == 1);
    [queue resolveWithPolicy:Policy(@{}) now:NSPermissionTimeout];
    CHECK(completions == NSMaximumActiveRequests + 1);
    CHECK(queue.waitingCount == 0);
    CHECK(queue.requests.count == NSMaximumRequestHistory);
    NSDictionary *fresh = [queue enqueueIdentity:@"fresh"
                                       direction:NSFlowDirectionOutbound
                                             now:31
                                            date:NSDate.date
                                      completion:^(BOOL allow) {
                                          CHECK(!allow);
                                          completions++;
                                      }];
    CHECK(fresh != nil);
    CHECK(queue.waitingCount == 1);
    CHECK(queue.requests.count == NSMaximumRequestHistory + 1);
    CHECK(NSWriteDocument(Monitor(queue.requests, YES, NSEngineVersion, NSDate.date), NSMonitorFile, NULL));
    CHECK([NSReadMonitor()[@"requests"] count] == NSMaximumRequestHistory + 1);
    [queue resolveWithPolicy:Policy(@{}) now:61];
    CHECK(queue.requests.count == NSMaximumRequestHistory);
    CHECK(queue.evictedRequestCount == 1);
    CHECK(![[queue.requests valueForKey:@"identity"] containsObject:@"app.0"]);
    [queue resolveWithPolicy:Policy(@{@"fresh" : @"allow"}) now:62];
    CHECK(![[queue.requests valueForKey:@"identity"] containsObject:@"fresh"]);
    NSUInteger finished = completions;
    [queue cancelAll];
    [queue cancelAll];
    CHECK(completions == finished);
    CHECK(queue.requests.count == 0);

    __block NSUInteger directional = 0;
    [queue enqueueIdentity:@"directional"
                 direction:NSFlowDirectionInbound
                       now:100
                      date:NSDate.date
                completion:^(BOOL allow) {
                    CHECK(!allow);
                    directional++;
                }];
    [queue enqueueIdentity:@"directional"
                 direction:NSFlowDirectionOutbound
                       now:100
                      date:NSDate.date
                completion:^(BOOL allow) {
                    CHECK(allow);
                    directional++;
                }];
    [queue resolveWithPolicy:Policy(@{@"directional" : @"block-inbound"}) now:129];
    [queue cancelAll];
    CHECK(directional == 2);

    __block NSUInteger timeout = 0;
    [queue enqueueIdentity:@"deadline"
                 direction:NSFlowDirectionOutbound
                       now:200
                      date:NSDate.date
                completion:^(BOOL allow) {
                    CHECK(!allow);
                    timeout++;
                }];
    [queue resolveWithPolicy:Policy(@{@"deadline" : @"allow"}) now:230];
    [queue cancelAll];
    CHECK(timeout == 1);
}
static void TestQueueLimitsAndCancellation(void) {
    NSPermissionQueue *queue = [NSPermissionQueue new];
    __block NSUInteger finished = 0;
    for (NSUInteger identity = 0; identity < NSMaximumWaiters / NSMaximumWaitersPerIdentity; identity++) {
        for (NSUInteger waiter = 0; waiter < NSMaximumWaitersPerIdentity; waiter++) {
            [queue enqueueIdentity:[NSString stringWithFormat:@"busy.%lu", (unsigned long)identity]
                         direction:NSFlowDirectionOutbound
                               now:0
                              date:NSDate.date
                        completion:^(BOOL allow) {
                            CHECK(!allow);
                            finished++;
                        }];
        }
    }
    CHECK(queue.waitingCount == NSMaximumWaiters);
    [queue enqueueIdentity:@"busy.0"
                 direction:NSFlowDirectionOutbound
                       now:1
                      date:NSDate.date
                completion:^(BOOL allow) {
                    CHECK(!allow);
                    finished++;
                }];
    [queue enqueueIdentity:@"new.identity"
                 direction:NSFlowDirectionOutbound
                       now:1
                      date:NSDate.date
                completion:^(BOOL allow) {
                    CHECK(!allow);
                    finished++;
                }];
    CHECK(queue.overflowCount == 2);
    CHECK(finished == 2);
    [queue cancelAll];
    [queue cancelAll];
    CHECK(finished == NSMaximumWaiters + 2);
    CHECK(queue.waitingCount == 0);
    CHECK(queue.requests.count == 0);
    [queue enqueueIdentity:@"invalid-policy"
                 direction:NSFlowDirectionOutbound
                       now:2
                      date:NSDate.date
                completion:^(BOOL allow) {
                    CHECK(!allow);
                    finished++;
                }];
    [queue resolveWithPolicy:nil now:3];
    CHECK(queue.requests.count == 0);
    CHECK(finished == NSMaximumWaiters + 3);
}
static void TestLargePolicyCache(void) {
    NSMutableDictionary *document = [[NSPolicy defaultDocument] mutableCopy];
    NSMutableDictionary *rules = [NSMutableDictionary new];
    for (NSUInteger index = 0; index < NSMaximumRules; index++) {
        rules[[NSString stringWithFormat:@"large.%lu", (unsigned long)index]] = @"block";
    }
    document[@"rules"] = rules;
    CHECK(NSWriteDocument(document, NSPolicyFile, NULL));
    NSPolicy *snapshot = NSReadPolicy(NULL);
    CHECK(snapshot != nil);
    for (NSUInteger index = 0; index < 100; index++) {
        CHECK(NSReadPolicy(NULL) == snapshot);
    }
    NSInvalidatePolicyCache();
    CHECK(NSReadPolicy(NULL) != snapshot);
    CHECK(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
}
static void TestAnswersAndReset(void) {
    CHECK(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
    NSPermissionQueue *queue = [NSPermissionQueue new];
    NSDictionary *request = [queue enqueueIdentity:@"answered"
                                         direction:NSFlowDirectionOutbound
                                               now:0
                                              date:NSDate.date
                                        completion:^(BOOL allow){
                                        }];
    CHECK(NSWriteDocument(Monitor(queue.requests, YES, NSEngineVersion, NSDate.date), NSMonitorFile, NULL));
    NSPolicy *oldDashboardSnapshot = NSReadPolicy(NULL);
    CHECK(NSAnswerPermissionRequest(request, YES, NULL));
    CHECK(!oldDashboardSnapshot.document[@"rules"][@"answered"]);
    SaveRule(@"edited", @"block");
    CHECK([NSReadPolicy(NULL).document[@"rules"][@"answered"] isEqual:@"allow"]);
    CHECK([NSReadPolicy(NULL).document[@"rules"][@"edited"] isEqual:@"block"]);
    CHECK(!NSAnswerPermissionRequest(request, NO, NULL));
    NSString *revision = NSReadPolicy(NULL).document[@"revision"];
    NSStoreLock *running = NSAcquireProviderLock(NULL);
    CHECK(running != nil);
    CHECK(NSWriteDocument(Monitor(@[], YES, NSEngineVersion, [NSDate dateWithTimeIntervalSinceNow:-60]),
                          NSMonitorFile, NULL));
    CHECK(!NSResetSharedState(NO, NULL));
    CHECK([NSReadPolicy(NULL).document[@"revision"] isEqual:revision]);
    CHECK([NSFileManager.defaultManager removeItemAtURL:NSSharedURL(NSMonitorFile) error:NULL]);
    CHECK(!NSResetSharedState(NO, NULL));
    [running unlock];
    CHECK(NSResetSharedState(NO, NULL));
    CHECK([NSReadPolicy(NULL).document[@"rules"] count] == 0);
    CHECK(NSReadMonitor().count == 0);
    CHECK(!NSResetSharedState(YES, NULL));
    CHECK(!NSAnswerPermissionRequest(request, YES, NULL));
    CHECK(NSWriteDocument(Monitor(@[], YES, 20013, [NSDate dateWithTimeIntervalSinceNow:-60]), NSMonitorFile,
                          NULL));
    CHECK(!NSResetSharedState(NO, NULL));
    CHECK(NSWriteDocument(Monitor(@[], NO, 20013, NSDate.date), NSMonitorFile, NULL));
    CHECK(NSResetSharedState(NO, NULL));
}

static void TestSocketSettingsAndDestinations(void) {
    NSMutableDictionary *document = [[NSPolicy defaultDocument] mutableCopy];
    CHECK([document[@"filterSockets"] boolValue]);
    [document removeObjectForKey:@"filterSockets"];
    CHECK([NSPolicy policyWithDocument:document error:NULL] != nil);
    CHECK([[NSPolicy policyWithDocument:document error:NULL].document[@"filterSockets"] boolValue]);
    CHECK(document[@"filterSockets"] == nil);
    document[@"filterSockets"] = @NO;
    CHECK(![[NSPolicy policyWithDocument:document error:NULL].document[@"filterSockets"] boolValue]);
    document[@"filterSockets"] = @"yes";
    CHECK([NSPolicy policyWithDocument:document error:NULL] == nil);
    document[@"filterSockets"] = @YES;
    document[@"allowAppleSystemProcesses"] = @YES;
    document[@"unattributed"] = @"block";
    CHECK(NSWriteDocument(document, NSPolicyFile, NULL));
    CHECK([NSReadPolicy(NULL).document[@"filterSockets"] boolValue]);
    CHECK([NSCleanDestinationHost(@"example.com/path?secret") isEqual:@""]);
    CHECK([NSCleanDestinationHost(@"bad\nexample.com") isEqual:@""]);
    CHECK([NSDestinationSummary(nil) isEqual:@"Destination unavailable from iOS"]);
    CHECK(!NSValidDestination(@{@"address" : @123}));
    NSDictionary *destination = @{@"domain" : @"example.com", @"address" : @"2001:db8::1"};
    CHECK([NSDestinationSummary(destination) containsString:@"2001:db8::1"]);
    NSPermissionQueue *queue = [NSPermissionQueue new];
    NSDictionary *request = [queue enqueueIdentity:@"destination.app"
                                         direction:NSFlowDirectionOutbound
                                       destination:destination
                                               now:0
                                              date:NSDate.date
                                        completion:^(BOOL allow){
                                        }];
    [queue enqueueIdentity:@"destination.app"
                 direction:NSFlowDirectionOutbound
               destination:@{@"domain" : @"second.example"}
                       now:1
                      date:NSDate.date
                completion:^(BOOL allow){
                }];
    CHECK([queue.requests.firstObject[@"destination"] isEqual:destination]);
    [queue resolveWithPolicy:NSReadPolicy(NULL) now:31];
    CHECK([queue.requests.firstObject[@"destination"] isEqual:destination]);
    CHECK([queue.requests.firstObject[@"expired"] boolValue]);
    CHECK(NSWriteDocument(Monitor(queue.requests, YES, NSEngineVersion, NSDate.date), NSMonitorFile, NULL));
    NSMutableDictionary *forged = [request mutableCopy];
    forged[@"destination"] = @{@"domain" : @"forged.example"};
    CHECK(NSAnswerPermissionRequest(forged, YES, NULL));
    CHECK([NSReadPolicy(NULL).document[@"ruleDestinations"][@"destination.app"] isEqual:destination]);
    CHECK(NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *current, NSError **error) {
            [current[@"rules"] removeObjectForKey:@"destination.app"];
            return YES;
        },
        NULL));
    CHECK(!NSReadPolicy(NULL).document[@"ruleDestinations"][@"destination.app"]);
    SaveRule(@"reset.app", @"block");
    NSStoreLock *running = NSAcquireProviderLock(NULL);
    CHECK(running != nil);
    CHECK(!NSResetSharedStateWithOptions(NO, YES, NULL));
    CHECK(NSReadPolicy(NULL).document[@"rules"][@"reset.app"] != nil);
    [running unlock];
    CHECK(NSResetSharedStateWithOptions(NO, YES, NULL));
    CHECK([NSReadPolicy(NULL).document[@"rules"] count] == 0);
    CHECK(NSReadMonitor().count == 0);
    CHECK([NSReadPolicy(NULL).document[@"filterSockets"] boolValue]);
    CHECK([NSReadPolicy(NULL).document[@"allowAppleSystemProcesses"] boolValue]);
    CHECK([NSReadPolicy(NULL).document[@"unattributed"] isEqual:@"block"]);
    CHECK(NSResetSharedState(NO, NULL));
    CHECK([NSReadPolicy(NULL).document[@"filterSockets"] boolValue]);
    CHECK(![NSReadPolicy(NULL).document[@"allowAppleSystemProcesses"] boolValue]);
    CHECK([NSReadPolicy(NULL).document[@"unattributed"] isEqual:@"allow"]);
}

@interface FakeNotificationCenter : NSObject <NSPermissionNotificationCenter>
@property(nonatomic, strong) NSMutableArray *requests;
@property(nonatomic, strong) NSMutableArray *completions;
@property(nonatomic, strong) NSMutableArray *settingsCompletions;
@property(nonatomic, strong) NSMutableArray *removed;
- (void)finish:(NSUInteger)index error:(NSError *)error;
@end
@implementation FakeNotificationCenter
- (instancetype)init {
    if ((self = [super init])) {
        _requests = [NSMutableArray new];
        _completions = [NSMutableArray new];
        _settingsCompletions = [NSMutableArray new];
        _removed = [NSMutableArray new];
    }
    return self;
}
- (void)addNotificationRequest:(UNNotificationRequest *)request
         withCompletionHandler:(void (^)(NSError *))completion {
    [self.requests addObject:request];
    [self.completions addObject:[completion copy]];
}
- (void)finish:(NSUInteger)index error:(NSError *)error {
    void (^completion)(NSError *) = self.completions[index];
    self.completions[index] = NSNull.null;
    completion(error);
}
- (void)removePendingNotificationRequestsWithIdentifiers:(NSArray<NSString *> *)identifiers {
    [self.removed addObjectsFromArray:identifiers];
}
- (void)removeDeliveredNotificationsWithIdentifiers:(NSArray<NSString *> *)identifiers {
    [self.removed addObjectsFromArray:identifiers];
}
- (void)getNotificationSettingsWithCompletionHandler:(void (^)(UNNotificationSettings *))completion {
    [self.settingsCompletions addObject:[completion copy]];
}
@end
static void TestLateNotifications(void) {
    CHECK(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
    NSDictionary *request = @{
        @"token" : @"old-token",
        @"identity" : @"notify.app",
        @"destination" : @{@"domain" : @"notify.example", @"address" : @"192.0.2.1"}
    };
    FakeNotificationCenter *center = [FakeNotificationCenter new];
    NSPermissionNotifications *old = [[NSPermissionNotifications alloc] initWithCenter:center];
    [old updateRequests:@[ request ] policy:NSReadPolicy(NULL) retryRevision:nil];
    CHECK(center.requests.count == 1);
    UNNotificationRequest *banner = center.requests.firstObject;
    CHECK([banner.content.body containsString:@"notify.example"]);
    CHECK([banner.content.body containsString:@"192.0.2.1"]);
    [old updateRequests:@[] policy:NSReadPolicy(NULL) retryRevision:nil];
    [center.removed removeAllObjects];
    [center finish:0 error:nil];
    CHECK([center.removed containsObject:@"old-token"]);
    CHECK(old.deliveryIssue.length == 0);

    NSPermissionNotifications *current = [[NSPermissionNotifications alloc] initWithCenter:center];
    NSDictionary *next = @{@"token" : @"new-token", @"identity" : @"notify.app"};
    [current updateRequests:@[ next ] policy:NSReadPolicy(NULL) retryRevision:nil];
    [center finish:1 error:nil];
    CHECK(center.settingsCompletions.count == 1);
    [current stop];
    void (^settings)(UNNotificationSettings *) = center.settingsCompletions.firstObject;
    [center.settingsCompletions removeAllObjects];
    settings(nil);
    CHECK(current.deliveryIssue.length == 0);

    NSPermissionNotifications *stopped = [[NSPermissionNotifications alloc] initWithCenter:center];
    [stopped updateRequests:@[ request ] policy:NSReadPolicy(NULL) retryRevision:nil];
    [stopped stop];
    [center.removed removeAllObjects];
    [center finish:2 error:[NSError errorWithDomain:@"test" code:1 userInfo:nil]];
    CHECK([center.removed containsObject:@"old-token"]);
    CHECK(stopped.deliveryIssue.length == 0);

    NSPermissionNotifications *released = [[NSPermissionNotifications alloc] initWithCenter:center];
    [released updateRequests:@[ request ] policy:NSReadPolicy(NULL) retryRevision:nil];
    released = nil;
    [center.removed removeAllObjects];
    [center finish:3 error:nil];
    CHECK([center.removed containsObject:@"old-token"]);
    [old stop];
}
int main(void) {
    @autoreleasepool {
        NSURL *root = [NSURL
            fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                isDirectory:YES];
        CHECK([NSFileManager.defaultManager createDirectoryAtURL:root
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:NULL]);
        NSSetTestContainer(root);
        TestPolicyAndCache();
        TestStorageFailureAndRecovery();
        TestConcurrentMutations();
        TestPermissionQueue();
        TestQueueLimitsAndCancellation();
        TestLargePolicyCache();
        TestAnswersAndReset();
        TestSocketSettingsAndDestinations();
        TestLateNotifications();
        CHECK([NSFileManager.defaultManager removeItemAtURL:root error:NULL]);
        NSLog(@"Passed %lu regression checks", (unsigned long)checks);
    }
    return 0;
}
