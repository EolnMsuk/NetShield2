#import "../Shared/NSStore.h"
#import "../Shared/NSDNSCache.h"
#import "../Shared/NSGlobalRule.h"
#import "../Shared/NSActivity.h"
#import "../Shared/NSDestination.h"
#import "../Shared/NSPermissionQueue.h"
#import "../Shared/NSNotifications.h"
#import "../App/NSFilterRestart.h"
#import "../FilterControl/NSPermissionNotifications.h"
#import "../FilterControl/NSDomainResolver.h"
#include <errno.h>

#define VERIFY(...)                                                                                          \
    do {                                                                                                     \
        if (!(__VA_ARGS__)) {                                                                                \
            NSLog(@"FAIL %s:%d: %s", __FILE__, __LINE__, #__VA_ARGS__);                                      \
            abort();                                                                                         \
        }                                                                                                    \
    } while (0)

static void TestDestinationSafety(void) {
    VERIFY([NSGlobalHostKey(@"::ffff:192.0.2.1") isEqual:@"ip:192.0.2.1"]);
    VERIFY([NSGlobalHostKey(@"[::ffff:c000:201]") isEqual:@"ip:192.0.2.1"]);
    VERIFY([NSGlobalHostKey(@"fe80::1%en0") isEqual:@"ip:fe80::1"]);
    VERIFY(!NSGlobalHostKey(@"example.com%en0"));
    NSMutableDictionary *document = [[NSPolicy defaultDocument] mutableCopy];
    document[@"globalRules"] = @{@"ip:::ffff:192.0.2.1" : @"block", @"ip:192.0.2.1" : @"allow"};
    NSPolicy *policy = [NSPolicy policyWithDocument:document error:NULL];
    VERIFY(policy && [policy.document[@"globalRules"] count] == 1);
    for (NSString *address in @[ @"192.0.2.1", @"::ffff:192.0.2.1" ]) {
        VERIFY(![policy allowsIdentity:@"com.apple.test"
                             direction:NSFlowDirectionOutbound
                           destination:@{@"address" : address}]);
    }
    VERIFY([policy needsSocketDestination:@{}]);
    VERIFY(![policy needsSocketDestination:@{@"address" : @"192.0.2.1"}]);
    for (NSString *key in @[ @"port:443", @"localPort:443" ]) {
        document[@"globalRules"] = @{key : @"block"};
        policy = [NSPolicy policyWithDocument:document error:NULL];
        VERIFY([policy needsSocketDestination:@{@"address" : @"192.0.2.1"}]);
        VERIFY(![policy needsSocketDestination:@{
            @"address" : @"192.0.2.1",
            @"port" : @443,
            @"localPort" : @443
        }]);
    }
    document[@"globalRules"] = @{};
    VERIFY(![[NSPolicy policyWithDocument:document error:NULL] needsSocketDestination:@{}]);
}

static void TestDNSReplacementAndPublication(void) {
    NSDate *now = NSDate.date;
    NSString *key = @"domain:www.example.com";
    NSMutableDictionary *document = [[NSPolicy defaultDocument] mutableCopy];
    document[@"globalRules"] = @{key : @"block"};
    document[@"globalDomainAddresses"] = @{key : @[ @"ip:192.0.2.1" ]};
    NSPolicy *legacy = [NSPolicy policyWithDocument:document error:NULL];
    VERIFY([legacy allowsIdentity:@"com.apple.test"
                        direction:NSFlowDirectionOutbound
                      destination:@{@"address" : @"192.0.2.1"}]);
    document[@"globalDomainExpirations"] = @{key : [now dateByAddingTimeInterval:120]};
    NSDictionary *pending = @{
        key : @{
            @"rule" : @"block",
            @"addresses" : @[ @"ip:192.0.2.2" ],
            @"expires" : [now dateByAddingTimeInterval:120]
        }
    };
    VERIFY(NSApplyDNSResults(document, pending, now));
    VERIFY([document[@"globalDomainAddresses"][key] isEqual:@[ @"ip:192.0.2.2" ]]);
    NSPolicy *policy = [NSPolicy policyWithDocument:document error:NULL];
    VERIFY([policy allowsIdentity:@"com.apple.test"
                        direction:NSFlowDirectionOutbound
                      destination:@{@"address" : @"192.0.2.1"}]);
    VERIFY(![policy allowsIdentity:@"com.apple.test"
                         direction:NSFlowDirectionOutbound
                       destination:@{@"address" : @"192.0.2.2"}]);
    VERIFY(NSApplyDNSResults(document, @{}, [now dateByAddingTimeInterval:121]));
    VERIFY([document[@"globalDomainAddresses"] count] == 0);
    VERIFY(!NSDNSExpiryIsLive([now dateByAddingTimeInterval:301], now));
    document[@"globalRules"] = @{key : @"allow"};
    VERIFY(!NSApplyDNSResults(document, pending, now));
    document[@"globalRules"] = @{key : @"block"};
    VERIFY(NSWriteDocument(document, NSPolicyFile, NULL));
    NSStoreLock *lock = [NSStoreLock tryLockURL:NSSharedURL(@"policy.lock") error:NULL];
    VERIFY(lock != nil);
    NSError *error = nil;
    VERIFY(!NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *current, NSError **unused) {
            return NSApplyDNSResults(current, pending, now);
        },
        &error));
    VERIFY([error.domain isEqual:NSPOSIXErrorDomain] && (error.code == EAGAIN || error.code == EWOULDBLOCK));
    [lock unlock];
    VERIFY(NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *current, NSError **unused) {
            return NSApplyDNSResults(current, pending, now);
        },
        NULL));
    VERIFY([NSReadPolicy(NULL).document[@"globalDomainAddresses"][key] isEqual:@[ @"ip:192.0.2.2" ]]);
}

@interface TestDNSOperation : NSObject <NSDNSOperation>
@property(nonatomic) BOOL cancelled;
@property(nonatomic, copy) NSString *key;
@property(nonatomic, copy) void (^completion)(NSDictionary *, NSError *);
@end
@implementation TestDNSOperation
- (void)cancel {
    self.cancelled = YES;
}
@end

static void TestBoundedResolver(void) {
    dispatch_queue_t queue = dispatch_queue_create("test.dns", DISPATCH_QUEUE_SERIAL);
    NSMutableArray<TestDNSOperation *> *operations = [NSMutableArray new];
    __block NSTimeInterval clock = 100;
    __block NSUInteger delivered = 0;
    NSDomainResolver *resolver = [[NSDomainResolver alloc] initWithQueue:queue
        clock:^NSTimeInterval {
            return clock;
        }
        lookup:^id<NSDNSOperation>(NSString *key, dispatch_queue_t unused,
                                   void (^completion)(NSDictionary *, NSError *)) {
            TestDNSOperation *operation = [TestDNSOperation new];
            operation.key = key;
            operation.completion = completion;
            [operations addObject:operation];
            return operation;
        }
        completion:^(NSString *key, NSString *rule, NSDictionary *result, NSError *error) {
            delivered++;
        }];
    NSMutableDictionary *rules = [NSMutableDictionary new];
    for (NSUInteger i = 0; i < 6; i++) {
        rules[[NSString stringWithFormat:@"domain:d%lu.test", (unsigned long)i]] = @"block";
    }
    [resolver refreshRules:rules];
    dispatch_sync(queue, ^{
        VERIFY(operations.count == 4);
    });
    NSDictionary *answer =
        @{@"addresses" : @[ @"ip:192.0.2.1" ],
          @"expires" : [NSDate dateWithTimeIntervalSinceNow:120]};
    dispatch_sync(queue, ^{
        operations[0].completion(answer, nil);
        VERIFY(operations.count == 5 && delivered == 1);
        // An old callback cannot remove the replacement or deliver twice.
        operations[0].completion(answer, nil);
        VERIFY(operations.count == 5 && delivered == 1);
    });
    [resolver refreshRules:@{}];
    dispatch_sync(queue, ^{
        for (NSUInteger i = 1; i < operations.count; i++) {
            VERIFY(operations[i].cancelled);
            operations[i].completion(answer, nil);
        }
        VERIFY(delivered == 1);
    });
    [resolver refreshRules:@{@"domain:retry.test" : @"block"}];
    dispatch_sync(queue, ^{
        VERIFY(operations.count == 6);
        operations.lastObject.completion(nil, [NSError errorWithDomain:@"test" code:1 userInfo:nil]);
        VERIFY(delivered == 2);
    });
    [resolver refreshRules:@{@"domain:retry.test" : @"block"}];
    dispatch_sync(queue, ^{
        VERIFY(operations.count == 6);
        clock += 6;
    });
    [resolver refreshRules:@{@"domain:retry.test" : @"block"}];
    dispatch_sync(queue, ^{
        VERIFY(operations.count == 7);
    });
    [resolver stop];
    [resolver refreshRules:rules];
    dispatch_sync(queue, ^{
        VERIFY(operations.lastObject.cancelled && operations.count == 7);
        operations.lastObject.completion(answer, nil);
        VERIFY(delivered == 2);
    });
}

static void TestExplicitAskAgain(void) {
    VERIFY(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
    NSPermissionQueue *queue = [NSPermissionQueue new];
    __block NSUInteger blocked = 0;
    NSDictionary *old = [queue enqueueIdentity:@"ask.app"
                                     direction:NSFlowDirectionOutbound
                                           now:0
                                          date:NSDate.date
                                    completion:^(BOOL allow) {
                                        VERIFY(!allow);
                                        blocked++;
                                    }];
    [queue resolveWithPolicy:NSReadPolicy(NULL) now:31];
    VERIFY(blocked == 1 && queue.requests.count == 1);
    NSDictionary *monitor = @{
        @"schema" : @2,
        @"engine" : @(NSEngineVersion),
        @"updated" : NSDate.date,
        @"lastReport" : NSDate.date,
        @"controlRunning" : @YES,
        @"policyError" : @"",
        @"events" : @[],
        @"requests" : queue.requests
    };
    VERIFY(NSWriteDocument(monitor, NSMonitorFile, NULL));
    VERIFY(NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *document, NSError **error) {
            return NSUseDefaultRule(document, @"ask.app", error);
        },
        NULL));
    // The old monitor is still fresh, but its generation must not answer a new request.
    VERIFY(!NSAnswerPermissionRequest(old, YES, NULL));
    [queue resolveWithPolicy:NSReadPolicy(NULL) now:32];
    VERIFY(queue.requests.count == 0);
    NSDictionary *fresh = [queue enqueueIdentity:@"ask.app"
                                       direction:NSFlowDirectionOutbound
                                             now:32
                                            date:NSDate.date
                                      completion:^(BOOL allow) {
                                          VERIFY(!allow);
                                          blocked++;
                                      }];
    VERIFY(fresh && ![fresh[@"token"] isEqual:old[@"token"]]);
    VERIFY(NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *document, NSError **error) {
            document[@"rules"][@"other.app"] = @"block";
            return YES;
        },
        NULL));
    [queue resolveWithPolicy:NSReadPolicy(NULL) now:33];
    VERIFY([queue.requests.firstObject[@"token"] isEqual:fresh[@"token"]]);
    // Save and immediately remove before the provider observes the saved rule.
    VERIFY(NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *document, NSError **error) {
            document[@"rules"][@"ask.app"] = @"allow";
            return YES;
        },
        NULL));
    VERIFY(NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *document, NSError **error) {
            return NSUseDefaultRule(document, @"ask.app", error);
        },
        NULL));
    [queue resolveWithPolicy:NSReadPolicy(NULL) now:34];
    VERIFY(blocked == 2 && queue.requests.count == 0);
    [queue cancelAll];
}

@interface RecoveryNotificationCenter : NSObject <NSPermissionNotificationCenter>
@property(nonatomic, strong) NSMutableArray *requests;
@property(nonatomic, strong) NSMutableArray *removed;
@property(nonatomic, strong) NSMutableArray *callbacks;
@property(nonatomic, copy) void (^pendingEnumeration)(NSArray<UNNotificationRequest *> *);
@property(nonatomic, copy) void (^deliveredEnumeration)(NSArray<UNNotification *> *);
@end
@implementation RecoveryNotificationCenter
- (instancetype)init {
    if ((self = [super init])) {
        _requests = [NSMutableArray new];
        _removed = [NSMutableArray new];
        _callbacks = [NSMutableArray new];
    }
    return self;
}
- (void)addNotificationRequest:(UNNotificationRequest *)request
         withCompletionHandler:(void (^)(NSError *))completion {
    [self.requests addObject:request];
    [self.callbacks addObject:[completion copy]];
}
- (void)removePendingNotificationRequestsWithIdentifiers:(NSArray *)identifiers {
    [self.removed addObjectsFromArray:identifiers];
}
- (void)removeDeliveredNotificationsWithIdentifiers:(NSArray *)identifiers {
    [self.removed addObjectsFromArray:identifiers];
}
- (void)getNotificationSettingsWithCompletionHandler:(void (^)(UNNotificationSettings *))completion {
}
- (void)getPendingNotificationRequestsWithCompletionHandler:
    (void (^)(NSArray<UNNotificationRequest *> *))completion {
    self.pendingEnumeration = completion;
}
- (void)getDeliveredNotificationsWithCompletionHandler:(void (^)(NSArray<UNNotification *> *))completion {
    self.deliveredEnumeration = completion;
}
@end

static void TestNotificationPublicationAndOrphans(void) {
    VERIFY(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
    RecoveryNotificationCenter *center = [RecoveryNotificationCenter new];
    NSPermissionNotifications *dispatcher = [[NSPermissionNotifications alloc] initWithCenter:center];
    NSDictionary *request = @{
        @"token" : @"live",
        @"identity" : @"test.app",
        @"created" : NSDate.date,
        @"expires" : [NSDate dateWithTimeIntervalSinceNow:30],
        @"waiting" : @1,
        @"expired" : @NO
    };
    NSDictionary *snapshot = @{
        @"schema" : @2,
        @"controlRunning" : @YES,
        @"updated" : NSDate.date,
        @"lastReport" : NSDate.date,
        @"policyError" : @"",
        @"requests" : @[ request ],
        @"events" : @[]
    };
    NSURL *monitorURL = NSSharedURL(NSMonitorFile);
    [NSFileManager.defaultManager removeItemAtURL:monitorURL error:NULL];
    VERIFY([NSFileManager.defaultManager createDirectoryAtURL:monitorURL
                                  withIntermediateDirectories:NO
                                                   attributes:nil
                                                        error:NULL]);
    NSError *error = nil;
    VERIFY(![dispatcher publishSnapshot:snapshot policy:NSReadPolicy(NULL) retryRevision:nil error:&error]);
    VERIFY(error && center.requests.count == 0);
    VERIFY([NSFileManager.defaultManager removeItemAtURL:monitorURL error:NULL]);
    VERIFY([dispatcher publishSnapshot:snapshot policy:NSReadPolicy(NULL) retryRevision:nil error:NULL]);
    VERIFY(center.requests.count == 1 && [NSReadMonitor()[@"requests"] count] == 1);
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.categoryIdentifier = NSPermissionCategory;
    UNNotificationRequest *orphan = [UNNotificationRequest requestWithIdentifier:@"orphan"
                                                                         content:content
                                                                         trigger:nil];
    center.pendingEnumeration(@[ orphan, center.requests.firstObject ]);
    VERIFY([center.removed containsObject:@"orphan"] && ![center.removed containsObject:@"live"]);
    // Storage fails after submitting; a late successful submit must be withdrawn.
    VERIFY([NSFileManager.defaultManager removeItemAtURL:monitorURL error:NULL]);
    VERIFY([NSFileManager.defaultManager createDirectoryAtURL:monitorURL
                                  withIntermediateDirectories:NO
                                                   attributes:nil
                                                        error:NULL]);
    VERIFY(![dispatcher publishSnapshot:snapshot policy:NSReadPolicy(NULL) retryRevision:nil error:NULL]);
    void (^late)(NSError *) = center.callbacks.firstObject;
    late(nil);
    VERIFY([center.removed containsObject:@"live"]);
    [dispatcher stop];
    VERIFY([NSFileManager.defaultManager removeItemAtURL:monitorURL error:NULL]);
}

@interface RestartManager : NSObject <NSFilterRestartManager>
@property(nonatomic, strong) id providerConfiguration;
@property(nonatomic, getter=isEnabled) BOOL enabled;
@property(nonatomic, copy) NSString *localizedDescription;
@property(nonatomic, strong) id saved;
@property(nonatomic) BOOL savedEnabled;
@property(nonatomic) NSUInteger loads;
@property(nonatomic) NSUInteger saves;
@property(nonatomic) NSUInteger failingLoad;
@property(nonatomic, copy) NSSet *failingSaves;
@property(nonatomic, strong) NSMutableArray *callbacks;
@end
@implementation RestartManager
- (instancetype)init {
    if ((self = [super init])) {
        _saved = @{@"name" : @"old"};
        _savedEnabled = YES;
        _callbacks = [NSMutableArray new];
    }
    return self;
}
- (NSError *)failure {
    return [NSError errorWithDomain:@"test"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : @"Injected failure"}];
}
- (void)loadFromPreferencesWithCompletionHandler:(void (^)(NSError *))completion {
    self.loads++;
    [self.callbacks addObject:[completion copy]];
    self.providerConfiguration = self.saved;
    self.enabled = self.savedEnabled;
    completion(self.loads == self.failingLoad ? self.failure : nil);
}
- (void)saveToPreferencesWithCompletionHandler:(void (^)(NSError *))completion {
    self.saves++;
    [self.callbacks addObject:[completion copy]];
    BOOL failed = [self.failingSaves containsObject:@(self.saves)];
    if (!failed) {
        self.saved = self.providerConfiguration;
        self.savedEnabled = self.enabled;
    }
    completion(failed ? self.failure : nil);
}
@end

static void TestRestartRecovery(void) {
    for (NSUInteger scenario = 0; scenario < 8; scenario++) {
        RestartManager *manager = [RestartManager new];
        if (scenario == 7) {
            manager.savedEnabled = NO;
        }
        if (scenario == 1 || scenario == 6) {
            manager.failingSaves =
                scenario == 6 ? [NSSet setWithArray:@[ @2, @3 ]] : [NSSet setWithObject:@2];
        }
        if (scenario == 2) {
            manager.failingLoad = 2;
        }
        NSFilterRestart *restart = [NSFilterRestart new];
        restart.manager = manager;
        __block NSUInteger builds = 0;
        restart.configuration = ^id(id previous, BOOL restoring, NSError **error) {
            builds++;
            if (scenario == 5 && builds == 2) {
                if (error) {
                    *error = manager.failure;
                }
                return nil;
            }
            return restoring ? previous : @{@"name" : @"new"};
        };
        __block NSUInteger stopChecks = 0;
        restart.isStopped = ^BOOL(BOOL previouslyEnabled) {
            return scenario != 4 && !manager.savedEnabled && ++stopChecks > 1;
        };
        restart.isRunning = ^BOOL(id configuration) {
            return manager.savedEnabled && [manager.saved isEqual:configuration] &&
                   !(scenario == 3 && [configuration[@"name"] isEqual:@"new"]);
        };
        NSMutableArray *scheduled = [NSMutableArray new];
        restart.schedule = ^(NSTimeInterval delay, void (^work)(void)) {
            [scheduled addObject:[work copy]];
        };
        __block NSUInteger completed = 0;
        __block NSError *result = nil;
        [restart start:^(NSError *error) {
            completed++;
            result = error;
        }];
        NSUInteger steps = 0;
        while (scheduled.count) {
            VERIFY(steps++ < 200);
            void (^work)(void) = scheduled.firstObject;
            [scheduled removeObjectAtIndex:0];
            work();
        }
        VERIFY(completed == 1);
        VERIFY((result == nil) == (scenario == 0 || scenario == 7));
        if (scenario != 4 && scenario != 6) {
            VERIFY(manager.savedEnabled);
            VERIFY([manager.saved[@"name"] isEqual:scenario == 0 || scenario == 7 ? @"new" : @"old"]);
        }
        NSUInteger saves = manager.saves;
        for (void (^callback)(NSError *) in manager.callbacks) {
            callback(nil);
        }
        VERIFY(completed == 1 && saves == manager.saves);
    }
}

static void TestDistinctFlowActivity(void) {
    NSDate *now = NSDate.date;
    NSDictionary * (^event)(NSString *, NSString *, NSString *, NSUInteger, NSUInteger) = ^NSDictionary *(
        NSString *flow, NSString *domain, NSString *action, NSUInteger seconds, NSUInteger bytes) {
        return @{
            @"flow" : flow,
            @"identity" : @"app",
            @"action" : action,
            @"direction" : @"outbound",
            @"time" : [now dateByAddingTimeInterval:seconds],
            @"bytesIn" : @(bytes),
            @"bytesOut" : @0,
            @"destination" : @{@"domain" : domain, @"localPort" : @1234, @"port" : @443}
        };
    };
    NSArray *groups = NSGroupedActivity(@[
        event(@"one", @"a.test", @"permission-allow", 0, 0), event(@"one", @"a.test", @"allow", 1, 0),
        event(@"one", @"a.test", @"allow", 2, 100), event(@"one", @"a.test", @"allow", 3, 100),
        event(@"two", @"b.test", @"allow", 4, 50)
    ]);
    VERIFY(groups.count == 2);
    VERIFY([groups[1][@"connections"] integerValue] == 1 && [groups[1][@"bytesIn"] integerValue] == 100);
    VERIFY([groups[0][@"destination"][@"domain"] isEqual:@"b.test"]);
    NSString *summary = NSDestinationSummary(groups[0][@"destination"]);
    VERIFY([summary rangeOfString:@"Local port:"].location <
           [summary rangeOfString:@"Remote port:"].location);
    groups = NSGroupedActivity(@[
        event(@"one", @"a.test", @"allow", 0, 100), event(@"one", @"a.test", @"permission-block", 1, 0),
        event(@"two", @"a.test", @"allow", 2, 50), event(@"two", @"a.test", @"allow", 3, 50)
    ]);
    VERIFY(groups.count == 1);
    VERIFY([groups[0][@"connections"] integerValue] == 2);
    VERIFY([groups[0][@"bytesIn"] integerValue] == 150);
    VERIFY([groups[0][@"action"] isEqual:@"allow"]);
    groups = NSGroupedActivity(@[
        event(@"one", @"a.test", @"allow", 0, 100), event(@"one", @"a.test", @"permission-block", 3, 0),
        event(@"two", @"a.test", @"allow", 2, 50)
    ]);
    VERIFY(groups.count == 1 && [groups[0][@"connections"] integerValue] == 2);
    VERIFY([groups[0][@"bytesIn"] integerValue] == 150);
    VERIFY([groups[0][@"action"] isEqual:@"block"]);
}

void NSRunRecoveryTests(void) {
    TestDestinationSafety();
    TestDNSReplacementAndPublication();
    TestBoundedResolver();
    TestExplicitAskAgain();
    TestNotificationPublicationAndOrphans();
    TestRestartRecovery();
    TestDistinctFlowActivity();
    NSLog(
        @"Passed recovery, destination, DNS lifetime, notification publication, and flow aggregation checks");
}
