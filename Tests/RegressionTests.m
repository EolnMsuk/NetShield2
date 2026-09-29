#import <Foundation/Foundation.h>
#import "../Shared/NSStore.h"
#import "../Shared/NSActivity.h"
#import "../App/NSFilterRemoval.h"
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
    CHECK([first.document[@"filterSockets"] boolValue]);
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
static NSDictionary *ActivityEvent(NSString *identity, NSDictionary *destination, NSString *direction,
                                   NSString *action, NSTimeInterval time, unsigned long long received,
                                   unsigned long long sent) {
    return @{
        @"identity" : identity,
        @"destination" : destination,
        @"direction" : direction,
        @"action" : action,
        @"time" : [NSDate dateWithTimeIntervalSince1970:time],
        @"bytesIn" : @(received),
        @"bytesOut" : @(sent)
    };
}
static void TestActivityGrouping(void) {
    NSDictionary *peer = @{@"domain" : @"example.com", @"address" : @"192.0.2.1"};
    NSDictionary *old = ActivityEvent(@"app", peer, @"outbound", @"allow", 1, 10, 20);
    NSDictionary *middle = ActivityEvent(@"other.app", peer, @"outbound", @"allow", 2, 1, 2);
    NSDictionary *latest = ActivityEvent(@"app", peer, @"outbound", @"permission-allow", 3, 30, 40);
    NSArray *events = @[ old, middle, latest ];
    NSArray *groups = NSGroupedActivity(events);
    CHECK(groups.count == 2);
    CHECK([groups[0][@"identity"] isEqual:@"app"]);
    CHECK([groups[0][@"connections"] integerValue] == 2);
    CHECK([groups[0][@"bytesIn"] unsignedLongLongValue] == 40);
    CHECK([groups[0][@"bytesOut"] unsignedLongLongValue] == 60);
    CHECK([groups[0][@"time"] isEqual:latest[@"time"]]);
    CHECK(!old[@"connections"] && [old[@"bytesIn"] integerValue] == 10);
    CHECK([NSGroupedActivity(@[ latest, old, middle ]) isEqual:groups]);
    NSArray *trimmed = NSGroupedActivity(@[ middle, latest ]);
    CHECK([trimmed[0][@"connections"] integerValue] == 1);
    CHECK([trimmed[0][@"bytesIn"] integerValue] == 30);
    CHECK([trimmed[0][@"bytesOut"] integerValue] == 40);
    CHECK([trimmed[0][@"groupKey"] isEqual:groups[0][@"groupKey"]]);
    CHECK([NSGroupedActivity(@[ old, middle ])[0][@"identity"] isEqual:@"other.app"]);
    CHECK(NSGroupedActivity(@[]).count == 0);
    NSMutableArray *separate = [events mutableCopy];
    [separate addObject:ActivityEvent(@"app", peer, @"inbound", @"allow", 4, 1, 1)];
    [separate addObject:ActivityEvent(@"app", peer, @"outbound", @"block", 5, 0, 0)];
    [separate addObject:ActivityEvent(@"app", @{@"domain" : @"different.com", @"address" : @"192.0.2.1"},
                                      @"outbound", @"allow", 6, 1, 1)];
    [separate addObject:ActivityEvent(@"app", @{@"domain" : @"example.com", @"address" : @"192.0.2.2"},
                                      @"outbound", @"allow", 7, 1, 1)];
    CHECK(NSGroupedActivity(separate).count == 6);
    [separate addObject:ActivityEvent(@"app", peer, @"outbound", @"permission-block", 8, 0, 0)];
    groups = NSGroupedActivity(separate);
    CHECK(groups.count == 6 && [groups[0][@"connections"] integerValue] == 2);
    CHECK([groups[0][@"action"] isEqual:@"block"]);
    CHECK([NSGroupedActivity(@[ ActivityEvent(@"", @{}, @"unknown", @"other", 0, 0, 0) ])[0][@"action"]
        isEqual:@"other"]);
}
static void TestDirectionalPermissionAnswers(void) {
    for (NSString *rule in @[ @"block-inbound", @"block-outbound" ]) {
        CHECK(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
        NSPermissionQueue *queue = [NSPermissionQueue new];
        NSDictionary *destination = @{@"domain" : @"incoming.example"};
        NSDictionary *request = [queue enqueueIdentity:@"incoming.app"
                                             direction:NSFlowDirectionOutbound
                                           destination:destination
                                                   now:0
                                                  date:NSDate.date
                                            completion:^(BOOL allow){
                                            }];
        CHECK(
            NSWriteDocument(Monitor(queue.requests, YES, NSEngineVersion, NSDate.date), NSMonitorFile, NULL));
        CHECK(!NSAnswerPermissionRequestWithRule(request, @"invalid", NULL));
        NSMutableDictionary *forged = [request mutableCopy];
        forged[@"token"] = @"stale-token";
        CHECK(!NSAnswerPermissionRequestWithRule(forged, rule, NULL));
        CHECK(!NSReadPolicy(NULL).document[@"rules"][@"incoming.app"]);
        forged = [request mutableCopy];
        forged[@"destination"] = @{@"domain" : @"forged.example"};
        CHECK(NSAnswerPermissionRequestWithRule(forged, rule, NULL));
        NSPolicy *policy = NSReadPolicy(NULL);
        CHECK([policy.document[@"rules"][@"incoming.app"] isEqual:rule]);
        CHECK([policy.document[@"ruleDestinations"][@"incoming.app"] isEqual:destination]);
        CHECK([policy allowsIdentity:@"incoming.app"
                           direction:NSFlowDirectionInbound] == [rule isEqual:@"block-outbound"]);
        CHECK([policy allowsIdentity:@"incoming.app"
                           direction:NSFlowDirectionOutbound] == [rule isEqual:@"block-inbound"]);
        CHECK(!NSAnswerPermissionRequestWithRule(request, rule, NULL));
    }
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
    CHECK([document[@"allowAppleSystemProcesses"] boolValue]);
    [document removeObjectForKey:@"filterSockets"];
    CHECK([NSPolicy policyWithDocument:document error:NULL] != nil);
    CHECK([[NSPolicy policyWithDocument:document error:NULL].document[@"filterSockets"] boolValue]);
    CHECK(document[@"filterSockets"] == nil);
    document[@"filterSockets"] = @NO;
    CHECK(![[NSPolicy policyWithDocument:document error:NULL].document[@"filterSockets"] boolValue]);
    document[@"filterSockets"] = @"yes";
    CHECK([NSPolicy policyWithDocument:document error:NULL] == nil);
    document[@"filterSockets"] = @YES;
    document[@"allowAppleSystemProcesses"] = @NO;
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
    CHECK(NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *current, NSError **error) {
            current[@"filterSockets"] = @NO;
            return YES;
        },
        NULL));
    SaveRule(@"reset.app", @"block");
    NSStoreLock *running = NSAcquireProviderLock(NULL);
    CHECK(running != nil);
    CHECK(!NSResetSharedStateWithOptions(NO, YES, NULL));
    CHECK(NSReadPolicy(NULL).document[@"rules"][@"reset.app"] != nil);
    CHECK(![NSReadPolicy(NULL).document[@"filterSockets"] boolValue]);
    [running unlock];
    CHECK(NSResetSharedStateWithOptions(NO, YES, NULL));
    CHECK([NSReadPolicy(NULL).document[@"rules"] count] == 0);
    CHECK(NSReadMonitor().count == 0);
    CHECK([NSReadPolicy(NULL).document[@"filterSockets"] boolValue]);
    CHECK([NSReadPolicy(NULL).document[@"allowAppleSystemProcesses"] boolValue]);
    CHECK([NSReadPolicy(NULL).document[@"unattributed"] isEqual:@"block"]);
    CHECK(NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *current, NSError **error) {
            current[@"filterSockets"] = @NO;
            return YES;
        },
        NULL));
    CHECK(NSResetSharedState(NO, NULL));
    CHECK([NSReadPolicy(NULL).document[@"filterSockets"] boolValue]);
    CHECK([NSReadPolicy(NULL).document[@"allowAppleSystemProcesses"] boolValue]);
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
    CHECK([banner.content.title isEqual:@"notify.app"]);
    CHECK([banner.content.body
        isEqual:@"Wants network access. Long-press this banner to allow, block incoming or keep blocking."]);
    CHECK(banner.content.subtitle.length == 0);
    CHECK(banner.content.attachments.count == 0);
    CHECK([banner.content.userInfo isEqual:@{@"token" : @"old-token", @"identity" : @"notify.app"}]);
    CHECK([request[@"destination"][@"domain"] isEqual:@"notify.example"]);
    CHECK([request[@"destination"][@"address"] isEqual:@"192.0.2.1"]);
    CHECK(![banner.content.body containsString:@"notify.example"]);
    CHECK(![banner.content.body containsString:@"192.0.2.1"]);
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
@interface FakeFilterRemovalManager : NSObject <NSFilterRemovalManager>
@property(nonatomic, strong) id providerConfiguration;
@property(nonatomic, getter=isEnabled) BOOL enabled;
@property(nonatomic, strong) NSError *loadError;
@property(nonatomic, strong) NSError *removeError;
@property(nonatomic, strong) NSError *verifyError;
@property(nonatomic) BOOL retainConfiguration;
@property(nonatomic) BOOL retainEnabled;
@property(nonatomic) NSUInteger loads;
@property(nonatomic) NSUInteger removals;
@end
@implementation FakeFilterRemovalManager
- (void)loadFromPreferencesWithCompletionHandler:(void (^)(NSError *))completion {
    self.loads++;
    if (self.loads > 1 && !self.verifyError && !self.removeError) {
        if (!self.retainConfiguration) {
            self.providerConfiguration = nil;
        }
        self.enabled = self.retainEnabled;
    }
    completion(self.loads == 1 ? self.loadError : self.verifyError);
}
- (void)removeFromPreferencesWithCompletionHandler:(void (^)(NSError *))completion {
    self.removals++;
    // Like NEFilterManager, leave the cached configuration until reload.
    completion(self.removeError);
}
@end
static void TestFilterRemoval(void) {
    NSError *failure = [NSError errorWithDomain:@"test.removal" code:1 userInfo:nil];
    for (NSUInteger scenario = 0; scenario < 8; scenario++) {
        FakeFilterRemovalManager *manager = [FakeFilterRemovalManager new];
        manager.providerConfiguration = scenario == 0 ? nil : @{};
        manager.enabled = scenario != 0 && scenario != 7;
        manager.loadError = scenario == 2 ? failure : nil;
        manager.removeError = scenario == 3 ? failure : nil;
        manager.verifyError = scenario == 4 ? failure : nil;
        manager.retainConfiguration = scenario == 5;
        manager.retainEnabled = scenario == 6;
        __block NSUInteger completions = 0;
        __block NSError *result = nil;
        NSRemoveInstalledFilter(manager, ^(NSError *error) {
            completions++;
            result = error;
        });
        CHECK(completions == 1);
        CHECK((result == nil) == (scenario == 0 || scenario == 1 || scenario == 7));
        CHECK(manager.removals == (scenario == 0 || scenario == 2 ? 0 : 1));
        CHECK(manager.loads == (scenario == 0 || scenario == 2 || scenario == 3 ? 1 : 2));
        if (scenario >= 2 && scenario <= 4) {
            CHECK(result == failure);
        }
    }
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
        TestActivityGrouping();
        TestDirectionalPermissionAnswers();
        TestAnswersAndReset();
        TestSocketSettingsAndDestinations();
        TestLateNotifications();
        TestFilterRemoval();
        CHECK([NSFileManager.defaultManager removeItemAtURL:root error:NULL]);
        NSLog(@"Passed %lu regression checks", (unsigned long)checks);
    }
    return 0;
}
