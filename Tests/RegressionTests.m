#import "../Shared/NSNotifications.h"
#import "../Shared/NSRuleChoices.h"
#import <Foundation/Foundation.h>
#import "../Shared/NSStore.h"
#import "../Shared/NSActivity.h"
#import "../Shared/NSExport.h"
#import "../Shared/NSGlobalRule.h"
#import "../Shared/NSReleaseVersion.h"
#import "../Shared/NSAppPreferences.h"
#import "../Shared/NSIdentityDisplay.h"
#import "../Shared/NSDNSCache.h"
#import "../App/NSFilterRemoval.h"
#import "../App/NSFilterBootPolicy.h"
#import "../Shared/NSDestination.h"
#import "../Shared/NSPermissionQueue.h"
#import "../Shared/NSMonitorSchema.h"
#import "../Shared/NSNotificationPolicy.h"
#import "../FilterControl/NSPermissionNotifications.h"
#import "RuleFixtures.h"
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
    document[@"rules"] = NSFixtureRules(rules);
    document[@"ruleSetEpoch"] = NSReadPolicy(NULL).document[@"ruleSetEpoch"] ?: @"fixture-rules";
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
            document[@"rules"][identity] = NSAppRuleBySelecting(nil, action);
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
    CHECK([NSReadPolicy(NULL).document[@"rules"][@"test.app"] isEqual:NSAppRuleBySelecting(nil, @"block")]);
}

static NSURL *StageExport(NSData *data, NSURL *container) {
    NSError *error = nil;
    NSURL *url = NSStageRulesAndActivityExport(data, container, &error);
    if (!url) {
        NSLog(@"Export staging failed: %@", error);
    }
    CHECK(url != nil);
    return url;
}

static void TestRulesAndActivityExport(void) {
    NSArray *systemIdentities = @[ @"com.apple.test", @".com.apple.test", @"Apple.com.apple.test" ];
    CHECK(!NSIsAppleSystemIdentity(nil) && !NSIsAppleSystemIdentity(@"com.appleish.test"));
    NSMutableDictionary *rules = [@{@"test.app" : @"block-outbound"} mutableCopy];
    for (NSString *identity in systemIdentities) {
        rules[identity] = @"block";
    }
    NSDictionary *event = @{
        @"identity" : @"test.app",
        @"time" : [NSDate dateWithTimeIntervalSince1970:0],
        @"action" : @"block",
        @"direction" : @"outbound",
        @"bytesIn" : @0,
        @"bytesOut" : @4294967296ULL,
        @"destination" : @{@"domain" : @"example.com", @"port" : @443}
    };
    for (NSNumber *allowSystem in @[ @YES, @NO ]) {
        NSMutableDictionary *document = [[NSPolicy defaultDocument] mutableCopy];
        document[@"rules"] = NSFixtureRules(rules);
        document[@"allowAppleSystemProcesses"] = allowSystem;
        document[@"globalRules"] = @{NSFixtureGlobal(@[], @"", @"443", @"", @"any", @"block") : @"block"};
        NSPolicy *policy = [NSPolicy policyWithDocument:document error:NULL];
        CHECK(policy);
        NSError *error = nil;
        NSData *data = NSRulesAndActivityJSON(policy, @[ event ], @"2.8.9", &error);
        CHECK(data && !error && data.length <= NSMaximumRuleTransferBytes);
        NSDictionary *export = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        CHECK([export[@"schemaVersion"] isEqual:@(NSExportSchemaVersion)]);
        NSRuleImportResult *parsed = NSParseRulesJSON(data, &error);
        CHECK(parsed && !error && [parsed.identityRules isEqual:document[@"rules"]]);
        CHECK([parsed.globalRules isEqual:document[@"globalRules"]]);
        CHECK([parsed.acceptedCounts[@"appRules"] isEqual:@1] &&
              [parsed.acceptedCounts[@"systemRules"] isEqual:@3]);
        CHECK(!export[@"ruleDestinations"]);
        CHECK([export[@"recentActivity"][0][@"time"] isEqual:@"1970-01-01T00:00:00Z"]);
        CHECK([export[@"recentActivity"][0][@"bytesOut"] isEqual:event[@"bytesOut"]]);
        CHECK([event[@"time"] isKindOfClass:NSDate.class]);
    }
    NSData *empty = NSRulesAndActivityJSON(Policy(@{}), @[], @"2.2.6", NULL);
    NSDictionary *export = [NSJSONSerialization JSONObjectWithData:empty options:0 error:NULL];
    CHECK([export[@"appRules"] count] == 0 && [export[@"systemRules"] count] == 0);
    CHECK([export[@"recentActivity"] count] == 0);

    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *container = NSSharedURL(@"");
    NSURL *sentinel = NSSharedURL(@"export-sentinel.json");
    CHECK([empty writeToURL:sentinel options:NSDataWritingAtomic error:NULL]);
    NSError *error = nil;
    CHECK(NSStageRulesAndActivityExport(empty, nil, &error) == nil && error != nil);
    error = nil;
    CHECK(NSStageRulesAndActivityExport(empty, [NSURL URLWithString:@"https://example.com"], &error) == nil);
    CHECK(error != nil);
    error = nil;
    CHECK(NSStageRulesAndActivityExport(empty, sentinel, &error) == nil && error != nil);
    NSURL *first = StageExport(empty, container);
    NSURL *second = StageExport(empty, container);
    CHECK(![first isEqual:second]);
    CHECK([first.lastPathComponent isEqual:@"NetShield2-Rules-and-Recent-Activity.json"]);
    CHECK([[NSData dataWithContentsOfURL:first] isEqual:empty]);
    CHECK(NSRemoveStagedExport(container, first, NULL));
    CHECK(![files fileExistsAtPath:first.path] && [files fileExistsAtPath:second.path]);
    CHECK(!NSRemoveStagedExport(container, sentinel, NULL));
    CHECK([files fileExistsAtPath:sentinel.path]);

    // The same container can have multiple path spellings (e.g. /var and
    // /private/var). Stage through a parent alias, then prune via the original.
    NSURL *parentAlias = [container URLByAppendingPathComponent:@"export-parent-alias"];
    CHECK([files createSymbolicLinkAtPath:parentAlias.path
                      withDestinationPath:container.URLByDeletingLastPathComponent.path
                                    error:NULL]);
    NSURL *aliasedContainer = [parentAlias URLByAppendingPathComponent:container.lastPathComponent
                                                           isDirectory:YES];
    NSURL *aliased = StageExport(empty, aliasedContainer);

    NSURL *cache = NSExportCacheURL(container, NO, NULL);
    NSURL *abandoned = [cache
        URLByAppendingPathComponent:[@"NetShield2-Export-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSURL *link = [cache
        URLByAppendingPathComponent:[@"NetShield2-Export-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    CHECK([files createDirectoryAtURL:abandoned withIntermediateDirectories:NO attributes:nil error:NULL]);
    CHECK([files createSymbolicLinkAtPath:link.path withDestinationPath:container.path error:NULL]);
    NSDictionary *old = @{NSFileModificationDate : [NSDate dateWithTimeIntervalSinceNow:-2 * 24 * 60 * 60]};
    CHECK([files setAttributes:old ofItemAtPath:abandoned.path error:NULL]);
    CHECK([files setAttributes:old ofItemAtPath:second.URLByDeletingLastPathComponent.path error:NULL]);
    CHECK([files setAttributes:old ofItemAtPath:aliased.URLByDeletingLastPathComponent.path error:NULL]);
    NSURL *third = StageExport(empty, container);
    CHECK(![files fileExistsAtPath:abandoned.path]);
    CHECK([files fileExistsAtPath:second.path]);
    CHECK([files fileExistsAtPath:aliased.path]);
    CHECK([files fileExistsAtPath:sentinel.path]);
    CHECK([[files attributesOfItemAtPath:link.path error:NULL][NSFileType] isEqual:NSFileTypeSymbolicLink]);
    CHECK(NSRemoveStagedExport(container, second, NULL));
    CHECK(NSRemoveStagedExport(aliasedContainer, aliased, NULL));
    CHECK(NSRemoveStagedExport(container, third, NULL));
    CHECK([files removeItemAtURL:parentAlias error:NULL]);
    CHECK([files removeItemAtURL:link error:NULL]);
    CHECK([files removeItemAtURL:cache error:NULL]);

    // A symlink in the cache path must not redirect staging or shared cleanup.
    CHECK([files createSymbolicLinkAtPath:cache.path withDestinationPath:container.path error:NULL]);
    error = nil;
    CHECK(NSStageRulesAndActivityExport(empty, container, &error) == nil && error != nil);
    CHECK(!NSResetSharedState(NO, NULL));
    CHECK(!NSRemoveSharedStateAfterFilterRemoval(NULL));
    CHECK([files fileExistsAtPath:sentinel.path]);
    CHECK([files removeItemAtURL:cache error:NULL]);
    CHECK([files removeItemAtURL:sentinel error:NULL]);
    CHECK(NSEnsurePolicy(NULL));
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
                        document[@"rules"][[NSString stringWithFormat:@"parallel.%zu", index]] =
                            NSAppRuleBySelecting(nil, @"block");
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
    NSPolicy *policy = NSReadPolicy(NULL);
    CHECK(policy != nil);
    for (NSUInteger index = 0; index < 32; index++) {
        NSString *identity = [NSString stringWithFormat:@"parallel.%lu", (unsigned long)index];
        CHECK([policy.document[@"rules"][identity] isEqual:@{@"both" : @"block"}]);
        CHECK(![policy allowsIdentity:identity direction:NSFlowDirectionInbound]);
        CHECK(![policy allowsIdentity:identity direction:NSFlowDirectionOutbound]);
    }
}
static void TestPermissionQueue(void) {
    NSPermissionQueue *queue = [NSPermissionQueue new];
    [queue resolveWithPolicy:NSReadPolicy(NULL) now:0];
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
                    CHECK(!allow);
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
    [queue resolveWithPolicy:NSReadPolicy(NULL) now:0];
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
    document[@"rules"] = NSFixtureRules(rules);
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
    CHECK(NSGroupedActivity(separate).count == 3);
    NSDictionary *merged = NSGroupedActivity(separate)[0];
    CHECK([merged[@"connections"] integerValue] == 5);
    CHECK([merged[@"destination"][@"domain"] isEqual:@"example.com"]);
    CHECK([merged[@"destination"][@"address"] isEqual:@"192.0.2.2"]);
    CHECK([merged[@"bytesIn"] integerValue] == 42);
    CHECK([merged[@"bytesOut"] integerValue] == 62);
    [separate addObject:ActivityEvent(@"app", peer, @"outbound", @"permission-block", 8, 0, 0)];
    groups = NSGroupedActivity(separate);
    CHECK(groups.count == 3 && [groups[0][@"connections"] integerValue] == 6);
    CHECK([groups[0][@"action"] isEqual:@"mixed"]);
    CHECK([groups[0][@"time"] isEqual:separate.lastObject[@"time"]]);
    CHECK([groups[0][@"bytesIn"] integerValue] == 42);
    for (NSNumber *port in @[ @80, @443 ]) {
        NSMutableDictionary *portedPeer = [peer mutableCopy];
        portedPeer[@"port"] = port;
        [separate addObject:ActivityEvent(@"app", portedPeer, @"outbound", @"allow", 9, 1, 1)];
        CHECK([NSDestinationSummary(portedPeer)
            containsString:[NSString stringWithFormat:@"Remote port: %@", port]]);
    }
    CHECK(NSGroupedActivity(separate).count == 5);
    for (NSNumber *localPort in @[ @50000, @50001 ]) {
        NSDictionary *localPeer = @{@"address" : @"192.0.2.1", @"port" : @443, @"localPort" : localPort};
        [separate
            addObject:ActivityEvent(@"app", localPeer, @"outbound", @"allow", localPort.doubleValue, 2, 3)];
        CHECK([NSDestinationSummary(localPeer)
            containsString:[NSString stringWithFormat:@"Local port: %@ / Remote port: 443", localPort]]);
    }
    CHECK(NSGroupedActivity(separate).count == 5);
    NSDictionary *localEvent = separate.lastObject;
    [separate addObject:localEvent];
    NSArray *localGroups = NSGroupedActivity(separate);
    CHECK(localGroups.count == 5);
    CHECK([localGroups[0][@"connections"] integerValue] == 4);
    CHECK([localGroups[0][@"bytesIn"] integerValue] == 7);
    CHECK([localGroups[0][@"bytesOut"] integerValue] == 10);
    CHECK([localGroups[0][@"action"] isEqual:@"allow"]);
    CHECK([localGroups[0][@"destination"] isEqual:localEvent[@"destination"]]);
    NSDictionary *bridge = ActivityEvent(@"app", @{@"domain" : @"A.TEST.", @"address" : @"192.0.2.1"},
                                         @"outbound", @"allow", 1, 10, 20);
    NSDictionary *byDomain = ActivityEvent(@"app", @{@"domain" : @"a.test", @"address" : @"192.0.2.2"},
                                           @"outbound", @"allow", 2, 30, 40);
    NSDictionary *byIP = ActivityEvent(@"app", @{@"domain" : @"b.test", @"address" : @"::ffff:192.0.2.1"},
                                       @"outbound", @"block", 3, 50, 60);
    NSArray *linked = NSGroupedActivity(@[ bridge, byDomain, byIP ]);
    CHECK(linked.count == 1);
    CHECK([linked[0][@"connections"] integerValue] == 3);
    CHECK([linked[0][@"bytesIn"] integerValue] == 90);
    CHECK([linked[0][@"bytesOut"] integerValue] == 120);
    CHECK([linked[0][@"destination"] isEqual:byIP[@"destination"]]);
    CHECK([linked[0][@"action"] isEqual:@"mixed"]);
    CHECK([linked[0][@"outcomeCounts"][@"block"] isEqual:@1]);
    CHECK([linked[0][@"outcomeCounts"][@"allow"] isEqual:@2]);
    CHECK([linked[0][@"hostCount"] isEqual:@2]);
    CHECK([linked isEqual:NSGroupedActivity(@[ byIP, bridge, byDomain ])]);
    CHECK(NSGroupedActivity(@[ byDomain, byIP ]).count == 2);
    NSArray *hostOnly = NSGroupedActivity(@[
        ActivityEvent(@"app", @{@"domain" : @"A.TEST."}, @"outbound", @"block", 1, 1, 2),
        ActivityEvent(@"app", @{@"domain" : @"a.test"}, @"outbound", @"allow", 2, 3, 4),
        ActivityEvent(@"app", @{@"domain" : @"b.test"}, @"outbound", @"allow", 3, 5, 6),
        ActivityEvent(@"app", @{}, @"outbound", @"allow", 4, 7, 8),
        ActivityEvent(@"app", @{}, @"outbound", @"allow", 5, 9, 10)
    ]);
    CHECK(hostOnly.count == 4);
    CHECK([hostOnly[3][@"connections"] integerValue] == 2);
    CHECK([hostOnly[3][@"action"] isEqual:@"mixed"]);
    CHECK(![hostOnly[0][@"groupKey"] isEqual:hostOnly[1][@"groupKey"]]);
    CHECK([NSGroupedActivity(@[ ActivityEvent(@"", @{}, @"unknown", @"other", 0, 0, 0) ])[0][@"action"]
        isEqual:@"other"]);
}
static void TestIdentityDisplay(void) {
    CHECK([NSIdentityDisplayName(@"53Q6R32WPB.com.hammerandchisel.discord")
        isEqual:@"hammerandchisel.discord (main)"]);
    CHECK([NSIdentityDisplayName(@"2TDUX39LX8.com.reddit.Reddit") isEqual:@"reddit.Reddit (main)"]);
    CHECK([NSIdentityDisplayName(@".2TDUX39LX8.com.reddit.Reddit") isEqual:@"reddit.Reddit (main)"]);
    CHECK([NSIdentityDisplayName(@"Apple.com.apple.mobilemail") isEqual:@"apple.mobilemail (main)"]);
    CHECK([NSIdentityDisplayName(@".Apple.com.apple.mobilemail") isEqual:@"apple.mobilemail (main)"]);
    CHECK([NSIdentityDisplayName(@"OtherApple.com.example.app") isEqual:@"example.app (main)"]);
    CHECK([NSIdentityDisplayName(@"apple.com.example.app") isEqual:@"example.app (main)"]);
    CHECK([NSIdentityDisplayName(@"12.com.example.app") isEqual:@"example.app (main)"]);
    CHECK([NSIdentityDisplayName(@"-.com.example.app") isEqual:@"example.app"]);
    CHECK([NSIdentityDisplayName(@"Apple.com") isEqual:@"Apple.com"]);
    CHECK([NSIdentityDisplayName(@".Apple.com") isEqual:@"Apple.com"]);
    CHECK([NSIdentityDisplayName(@"TEAM.telecom.helper.com") isEqual:@"telecom.helper.com"]);
    CHECK([NSIdentityDisplayName(@"TEAM.com.example.com") isEqual:@"example.com (main)"]);
    CHECK([NSIdentityDisplayName(@"TEAM.com.com.example.app") isEqual:@"example.app (main)"]);
    CHECK([NSIdentityDisplayName(@".com.reddit.Reddit") isEqual:@"reddit.Reddit"]);
    CHECK([NSIdentityDisplayName(@"com.example.app") isEqual:@"example.app"]);
    CHECK([NSIdentityDisplayName(@".com.apple.test") isEqual:@"apple.test"]);
    CHECK([NSIdentityDisplayName(@"networkd") isEqual:@"networkd"]);
    CHECK([NSIdentityDisplayName(@"prefix.") isEqual:@"Unidentified app"]);
    CHECK([NSIdentityDisplayName(nil) isEqual:@"Unidentified app"]);
    CHECK([NSIdentityDisplayName(@42) isEqual:@"Unidentified app"]);
    // Display collisions must never collapse distinct firewall decisions.
    NSString *first = @"TEAMONE.com.example.app", *second = @"TEAMTWO.com.example.app";
    CHECK([NSIdentityDisplayName(first) isEqual:NSIdentityDisplayName(second)]);
    NSPolicy *policy = Policy(@{first : @"allow", second : @"block"});
    CHECK([policy allowsIdentity:first direction:NSFlowDirectionOutbound]);
    CHECK(![policy allowsIdentity:second direction:NSFlowDirectionOutbound]);
    CHECK(NSCompareIdentityDisplayNames(@"ZZZ.com.Alpha", @"AAA.com.beta") == NSOrderedAscending);
    CHECK(NSCompareIdentityDisplayNames(first, second) == NSOrderedAscending);
    CHECK(NSCompareIdentityDisplayNames(@"com.Alpha", @"com.alpha") == NSOrderedAscending);

    NSString *rawIdentity = @".com.apple.mobilemail";
    NSString *fullName = @"com.apple.mobilemail";
    NSDictionary *connection = @{@"identity" : rawIdentity};
    NSArray<NSString *> *processRow = NSActivityDetailRows(connection).firstObject;
    CHECK([processRow[1] isEqual:fullName]);
    CHECK([NSActivityClipboardLine(connection) hasPrefix:@"Process name: com.apple.mobilemail / "]);
    CHECK(NSActivityMatchesQuery(connection, rawIdentity));
    CHECK(NSActivityMatchesQuery(connection, fullName));
    CHECK([connection[@"identity"] isEqual:rawIdentity]);
    NSString *key = NSFixtureGlobal(connection[@"identity"], @"", @"", @"", @"any", @"block");
    CHECK([[NSGlobalRuleCondition(key)[@"identities"] firstObject] isEqual:rawIdentity]);
    CHECK(![key isEqual:NSFixtureGlobal(fullName, @"", @"", @"", @"any", @"block")]);
}
static BOOL RuleOverlap(NSString *left, NSString *right) {
    NSDictionary *a = NSCompileGlobalCondition(NSGlobalRuleCondition(left));
    NSDictionary *b = NSCompileGlobalCondition(NSGlobalRuleCondition(right));
    CHECK(a && b);
    CHECK(NSGlobalConditionsIntersect(a, b) == NSGlobalConditionsIntersect(b, a));
    return NSGlobalConditionsIntersect(a, b);
}
static void TestGlobalRules(void) {
    NSString *base = NSFixtureGlobal(@[ @"app", @"other" ], @"example.com, 192.0.2.0/24", @"100-200",
                                     @"300-400", @"tcp+udp", @"allow-outbound");
    CHECK(NSValidGlobalRuleKey(base));
    NSArray *cases = @[
        @[ NSFixtureGlobal(@"app", @"example.com", @"200-250", @"400", @"tcp", @"block"), @YES ],
        @[ NSFixtureGlobal(@[], @"192.0.2.128/25", @"150", @"350", @"udp", @"allow-outbound"), @YES ],
        @[ NSFixtureGlobal(@"different", @"", @"", @"", @"any", @"block"), @NO ],
        @[ NSFixtureGlobal(@"app", @"different.test & 198.51.100.0/24", @"", @"", @"any", @"block"), @NO ],
        @[ NSFixtureGlobal(@"app", @"", @"201-300", @"", @"any", @"block"), @NO ],
        @[ NSFixtureGlobal(@"app", @"", @"", @"401-500", @"any", @"block"), @NO ],
        @[ NSFixtureGlobal(@"app", @"", @"", @"", @"other", @"block"), @NO ],
        @[ NSFixtureGlobal(@"app", @"", @"", @"", @"tcp", @"block-inbound"), @NO ],
        @[ NSFixtureGlobal(@"app", @"", @"", @"", @"tcp", @"allow-outbound"), @YES ]
    ];
    for (NSArray *test in cases) {
        CHECK(RuleOverlap(base, test[0]) == [test[1] boolValue]);
    }
    CHECK(RuleOverlap(base, base));
    CHECK(!RuleOverlap(NSFixtureGlobal(@[], @"", @"", @"", @"udp", @"allow"),
                       NSFixtureGlobal(@[], @"", @"", @"", @"tcp", @"block")));
    CHECK(RuleOverlap(NSFixtureGlobal(@[], @"", @"", @"", @"any", @"allow"),
                      NSFixtureGlobal(@[], @"", @"", @"", @"other", @"allow")));
    // A domain and an IP can identify the same connection. Independent port
    // dimensions also intersect even when their numeric values differ.
    CHECK(RuleOverlap(NSFixtureGlobal(@[], @"example.com", @"443", @"", @"any", @"allow"),
                      NSFixtureGlobal(@[], @"192.0.2.1", @"", @"1234", @"any", @"block")));
    CHECK(!RuleOverlap(NSFixtureGlobal(@[], @"a.test", @"", @"", @"any", @"block"),
                       NSFixtureGlobal(@[], @"b.test", @"", @"", @"any", @"allow")));
    CHECK(!RuleOverlap(NSFixtureGlobal(@[], @"a.test & 192.0.2.1", @"", @"", @"any", @"block"),
                       NSFixtureGlobal(@[], @"a.test & 192.0.2.2", @"", @"", @"any", @"allow")));
    for (NSString *action in @[ @"allow-outbound", @"block-outbound" ]) {
        NSString *candidate = NSFixtureGlobal(@"app", @"example.com", @"150", @"350", @"tcp", action);
        NSError *error = nil;
        CHECK(!NSValidateGlobalRuleChange(@{base : @"allow-outbound"}, candidate, action, nil, &error));
        CHECK([error.localizedDescription containsString:@"overlaps"] && error.userInfo[@"conflictingRule"]);
    }
    CHECK(NSValidateGlobalRuleChange(@{base : @"allow-outbound"}, base, @"allow-outbound", base, NULL));
    CHECK(!NSValidateGlobalRuleChange(@{}, base, @"allow-outbound", base, NULL));
    CHECK(!NSValidateGlobalRuleChange(@{base : @"allow-outbound"}, base, @"allow-outbound", nil, NULL));
    NSString *subset = NSFixtureGlobal(@"app", @"example.com", @"150", @"350", @"tcp", @"allow-outbound");
    NSMutableDictionary *document = [[NSPolicy defaultDocument] mutableCopy];
    document[@"globalRules"] = @{base : @"allow-outbound", subset : @"allow-outbound"};
    CHECK(![NSPolicy policyWithDocument:document error:NULL]);
    // An unchanged invalid collection is rejected on both disk read and update.
    CHECK(NSWriteDocument(document, NSPolicyFile, NULL));
    CHECK(!NSReadPolicy(NULL));
    CHECK(!NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *d, NSError **error) {
            return YES;
        },
        NULL));
    CHECK(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
    NSDictionary *staleView = NSReadPolicy(NULL).document[@"globalRules"];
    CHECK(NSValidateGlobalRuleChange(staleView, base, @"allow-outbound", nil, NULL));
    CHECK(NSValidateGlobalRuleChange(staleView, subset, @"allow-outbound", nil, NULL));
    CHECK(NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *d, NSError **error) {
            d[@"globalRules"] = @{base : @"allow-outbound"};
            return YES;
        },
        NULL));
    NSDictionary *before = NSReadPolicy(NULL).document;
    CHECK(!NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *d, NSError **error) {
            NSMutableDictionary *rules = [d[@"globalRules"] mutableCopy];
            if (!NSValidateGlobalRuleChange(rules, subset, @"allow-outbound", nil, error)) {
                return NO;
            }
            rules[subset] = @"allow-outbound";
            d[@"globalRules"] = rules;
            return YES;
        },
        NULL));
    CHECK([NSReadPolicy(NULL).document isEqual:before]);

    // CIDRs normalize host bits; range merging never expands covered addresses.
    CHECK([NSGlobalParseDestinations(@"192.0.2.129/24")
        isEqual:NSGlobalParseDestinations(@"192.0.2.0-192.0.2.255")]);
    CHECK([NSGlobalParseDestinations(@"2001:db8::1234/32")
        isEqual:NSGlobalParseDestinations(@"2001:db8::/32")]);
    CHECK([NSGlobalParseDestinations(@"192.0.2.1/32")
        isEqual:NSGlobalParseDestinations(@"::ffff:192.0.2.1/128")]);
    CHECK([NSGlobalParseDestinations(@"::ffff:192.0.2.99/120")
        isEqual:NSGlobalParseDestinations(@"192.0.2.0/24")]);
    CHECK(NSGlobalParseDestinations(@"0.0.0.0/0").count == 1);
    CHECK(NSGlobalParseDestinations(@"::/0").count == 3);
    CHECK(NSGlobalParseDestinations(@"2001:db8::1/128").count == 1);
    CHECK(RuleOverlap(NSFixtureGlobal(@[], @"::/0", @"", @"", @"any", @"block"),
                      NSFixtureGlobal(@[], @"192.0.2.1", @"", @"", @"any", @"block")));
    CHECK(!RuleOverlap(NSFixtureGlobal(@[], @"2001:db8::/33", @"", @"", @"any", @"block"),
                       NSFixtureGlobal(@[], @"2001:db8:8000::/33", @"", @"", @"any", @"block")));
    CHECK([NSGlobalParseDestinations(@"Example.COM., 192.0.2.0/25, 192.0.2.128/25, example.com") count] == 2);
    CHECK([NSGlobalParsePorts(@"80, 443, 8000-8080, 8081-9000")
        isEqual:@[ @[ @80, @80 ], @[ @443, @443 ], @[ @8000, @9000 ] ]]);
    for (NSString *bad in @[
             @"https://example.com", @"example.com,", @",example.com", @"192.0.2.1/33", @"::/129", @"::/-1",
             @"::/1.5", @"192.0.2.2-192.0.2.1", @"192.0.2.1-::1", @"::2-::1", @"example.com%en0"
         ]) {
        CHECK(!NSGlobalParseDestinations(bad));
    }
    for (NSString *bad in @[ @"0", @"65536", @"1.5", @"1-", @"-2", @"5-4", @"1,,2", @"true", @"1-2-3" ]) {
        CHECK(!NSGlobalParsePorts(bad));
    }
    for (NSString *old in @[
             @"domain:example.com", @"port:443", @"group:ip:192.0.2.1,ip:192.0.2.2",
             @"custom:[\"\",\"\",\"\",\"any\"]"
         ]) {
        CHECK(!NSValidGlobalRuleKey(old));
    }
    NSMutableDictionary *bad = [NSGlobalRuleCondition(base) mutableCopy];
    bad[@"remotePorts"] = @[ @[ @YES, @80 ] ];
    CHECK(!NSGlobalRuleKey(bad));
    bad[@"remotePorts"] = @[ @[ @1.5, @80 ] ];
    CHECK(!NSGlobalRuleKey(bad));
    bad[@"remotePorts"] = @[];
    bad[@"unknown"] = @YES;
    CHECK(!NSGlobalRuleKey(bad));

    NSDictionary *peer = @{
        @"domain" : @"example.com",
        @"address" : @"192.0.2.1",
        @"port" : @443,
        @"localPort" : @1234,
        @"protocol" : @"tcp"
    };
    NSString *exact = NSExactGlobalRuleKey(@[ @"app" ], peer, @"outgoing");
    document = [[NSPolicy defaultDocument] mutableCopy];
    document[@"default"] = @"block";
    document[@"globalRules"] = @{exact : @"allow-outbound"};
    NSPolicy *policy = [NSPolicy policyWithDocument:document error:NULL];
    CHECK(policy);
    CHECK([policy allowsIdentity:@"app" direction:NSFlowDirectionOutbound destination:peer]);
    CHECK(![policy allowsIdentity:@"other" direction:NSFlowDirectionOutbound destination:peer]);
    CHECK(![policy allowsIdentity:@"app" direction:NSFlowDirectionUnknown destination:peer]);
    NSMutableDictionary *changed = [peer mutableCopy];
    changed[@"domain"] = @"different.test";
    CHECK(![policy allowsIdentity:@"app" direction:NSFlowDirectionOutbound destination:changed]);
    [changed removeObjectForKey:@"address"];
    CHECK(![policy needsSocketDestination:changed identity:@"app" direction:NSFlowDirectionOutbound]);
    changed = [peer mutableCopy];
    [changed removeObjectForKey:@"address"];
    CHECK([policy needsSocketDestination:changed identity:@"app" direction:NSFlowDirectionOutbound]);
    changed[@"port"] = @1234;
    changed[@"localPort"] = @443;
    CHECK(![policy needsSocketDestination:changed identity:@"app" direction:NSFlowDirectionOutbound]);
    document[@"globalRules"] = @{
        NSFixtureGlobal(@"app", @"example.com,192.0.2.1", @"443", @"1234", @"tcp+udp", @"allow") : @"allow"
    };
    policy = [NSPolicy policyWithDocument:document error:NULL];
    CHECK([policy allowsIdentity:@"app"
                       direction:NSFlowDirectionOutbound
                     destination:@{
                         @"domain" : @"different.test",
                         @"address" : @"::ffff:192.0.2.1",
                         @"port" : @443,
                         @"localPort" : @1234,
                         @"protocol" : @"udp"
                     }]);
    CHECK(![policy allowsIdentity:@"app"
                        direction:NSFlowDirectionOutbound
                      destination:@{
                          @"domain" : @"example.com",
                          @"port" : @443,
                          @"localPort" : @1234
                      }]);
    // Exact domain-only connection conditions retain their metadata requirement,
    // including after export/import. Ordinary blocks keep safe DNS fallback.
    NSDictionary *endpoint = @{@"domain" : @"example.com", @"port" : @443};
    NSString *domainOnly = NSExactGlobalRuleKey(@[], endpoint, @"both");
    for (NSString *action in @[ @"allow", @"block" ]) {
        document[@"default"] = [action isEqual:@"allow"] ? @"block" : @"allow";
        document[@"globalRules"] = @{domainOnly : action};
        document[@"globalDomainAddresses"] = @{@"domain:example.com" : @[ @"ip:192.0.2.1" ]};
        document[@"globalDomainExpirations"] =
            @{@"domain:example.com" : [NSDate dateWithTimeIntervalSinceNow:120]};
        document[@"globalDomainLifetimes"] = @{@"domain:example.com" : NSFixtureDNSLifetime()};
        policy = [NSPolicy policyWithDocument:document error:NULL];
        CHECK(policy);
        CHECK([policy evaluateIdentity:@"app"
                             direction:NSFlowDirectionOutbound
                           destination:@{
                               @"address" : @"192.0.2.1",
                               @"port" : @443
                           }
                                socket:NO]
                  .reason != NSFlowReasonGlobal);
        CHECK(NSGlobalRuleConditions(policy.document[@"globalRules"]).count == 0);
        CHECK([NSParseRulesJSON(NSRulesAndActivityJSON(policy, @[], @"2.8.9", NULL), NULL).globalRules
            isEqual:document[@"globalRules"]]);
    }
    document[@"globalRules"] =
        @{NSFixtureGlobal(@[], @"example.com", @"443", @"", @"any", @"block") : @"block"};
    policy = [NSPolicy policyWithDocument:document error:NULL];
    CHECK([policy evaluateIdentity:@"app"
                         direction:NSFlowDirectionOutbound
                       destination:@{
                           @"address" : @"192.0.2.1",
                           @"port" : @443
                       }
                            socket:NO]
              .reason == NSFlowReasonGlobal);
    CHECK([policy evaluateIdentity:@"app"
                         direction:NSFlowDirectionOutbound
                       destination:@{
                           @"domain" : @"different.test",
                           @"address" : @"192.0.2.1",
                           @"port" : @443
                       }
                            socket:NO]
              .reason != NSFlowReasonGlobal);
    document[@"default"] = @"block";
    document[@"globalRules"] = @{NSFixtureGlobal(@[], @"", @"", @"", @"any", @"allow") : @"allow"};
    policy = [NSPolicy policyWithDocument:document error:NULL];
    CHECK([policy allowsIdentity:@"app" direction:NSFlowDirectionUnknown destination:@{}]);
    CHECK([policy allowsIdentity:@"app"
                       direction:NSFlowDirectionOutbound
                     destination:@{@"protocol" : @"other"}]);
    document[@"globalRules"] = @{NSFixtureGlobal(@[], @"", @"", @"", @"other+tcp+udp", @"allow") : @"allow"};
    policy = [NSPolicy policyWithDocument:document error:NULL];
    CHECK(![policy allowsIdentity:@"app" direction:NSFlowDirectionUnknown destination:@{}]);
    CHECK([policy allowsIdentity:@"app"
                       direction:NSFlowDirectionOutbound
                     destination:@{@"protocol" : @"other"}]);
    CHECK(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
}
static NSData *RulesJSON(id object) {
    return [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:NULL];
}
static void TestRuleImport(void) {
    NSString *global = NSFixtureGlobal(@[], @"example.com", @"443,8000-8080", @"", @"tcp+udp", @"block");
    NSMutableDictionary *envelope = [@{
        @"schemaVersion" : @(NSExportSchemaVersion),
        @"globalRules" : @[ @{@"condition" : NSGlobalRuleCondition(global), @"action" : @"block"} ],
        @"appRules" : @[
            @{@"identity" : @"new.app",
              @"rule" : @{@"outbound" : @"allow"}}
        ],
        @"systemRules" : @[
            @{@"identity" : @"com.apple.test",
              @"rule" : @{@"both" : @"block"}}
        ]
    } mutableCopy];
    // Ignored information can be nonsensical JSON without poisoning rules.
    for (NSString *key in @[
             @"recentActivity", @"monitor", @"settings", @"ruleDestinations", @"globalDomainAddresses",
             @"requests", @"responses", @"revision", @"ruleSetEpoch", @"askGenerations",
             @"globalRuleGeneration"
         ]) {
        envelope[key] = @[ NSNull.null, @YES, @"forged" ];
    }
    envelope[@"defaultRule"] = @"block";
    envelope[@"unidentifiedRule"] = @"allow";
    envelope[@"filterSockets"] = @YES;
    envelope[@"allowAppleSystemProcesses"] = @YES;
    NSRuleImportResult *result = NSParseRulesJSON(RulesJSON(envelope), NULL);
    CHECK(result && result.identityRules.count == 2 && result.globalRules.count == 1);
    NSMutableDictionary *local = [[NSPolicy defaultDocument] mutableCopy];
    local[@"default"] = @"ask";
    local[@"unattributed"] = @"ask";
    local[@"filterSockets"] = @NO;
    local[@"allowAppleSystemProcesses"] = @NO;
    local[@"rules"] = NSFixtureRules(@{@"old.app" : @"block", @"com.apple.old" : @"allow"});
    local[@"globalRules"] = @{NSFixtureGlobal(@[], @"old.example", @"", @"", @"any", @"block") : @"block"};
    local[@"ruleDestinations"] = @{@"old.app" : @{@"port" : @443}};
    local[@"askGenerations"] = @{@"old.app" : @"old-selection"};
    local[@"globalDomainAddresses"] = @{@"domain:old.example" : @[ @"ip:192.0.2.1" ]};
    local[@"globalDomainExpirations"] = @{@"domain:old.example" : [NSDate dateWithTimeIntervalSinceNow:120]};
    local[@"globalDomainLifetimes"] = @{@"domain:old.example" : NSFixtureDNSLifetime()};
    CHECK(NSWriteDocument(local, NSPolicyFile, NULL));
    NSPolicy *old = NSReadPolicy(NULL);
    CHECK(old);
    NSPermissionQueue *queue = [NSPermissionQueue new];
    [queue resolveWithPolicy:old now:0];
    __block NSUInteger invalidated = 0;
    NSDictionary *identified = [queue enqueueIdentity:@"pending.app"
                                            direction:NSFlowDirectionOutbound
                                                  now:1
                                                 date:NSDate.date
                                           completion:^(BOOL allow) {
                                               CHECK(!allow);
                                               invalidated++;
                                           }];
    NSDictionary *unidentified = [queue enqueueIdentity:@""
                                              direction:NSFlowDirectionOutbound
                                            destination:@{@"address" : @"198.51.100.1"}
                                                   flow:@""
                                                    now:1
                                                   date:NSDate.date
                                                 result:^(NSPermissionResult verdict) {
                                                     CHECK(verdict == NSPermissionBlocked);
                                                     invalidated++;
                                                 }];
    NSDictionary *once = [queue enqueueIdentity:@""
        direction:NSFlowDirectionUnknown
        destination:@{}
        flow:@"one-flow"
        now:1
        date:NSDate.date
        result:^(NSPermissionResult verdict) {
            CHECK(verdict == NSPermissionBlocked);
            invalidated++;
        }];
    CHECK(identified && unidentified && once);
    NSPermissionQueue *history = [NSPermissionQueue new];
    [history resolveWithPolicy:old now:0];
    [history enqueueIdentity:@"history.app"
                   direction:NSFlowDirectionOutbound
                         now:1
                        date:NSDate.date
                  completion:^(BOOL allow) {
                      CHECK(!allow);
                  }];
    [history resolveWithPolicy:old now:NSPermissionTimeout + 2];
    CHECK(history.requests.count == 1 && history.waitingCount == 0);
    NSMutableDictionary *staleResponse = [once mutableCopy];
    staleResponse[@"action"] = @"allow";
    NSDictionary *monitor = Monitor(@[ identified ], YES, NSEngineVersion, NSDate.date);
    CHECK(NSWriteDocument(monitor, NSMonitorFile, NULL));
    NSData *activityBefore = NSReadBoundedFile(
        [NSSharedDirectory openRoot:NSSharedURL(@"") leaf:NSMonitorFile error:NULL], NSMonitorFile, NULL);
    NSDictionary *pendingDNS = @{
        @"domain:old.example" : @{
            @"rule" : @"block",
            @"addresses" : @[ @"ip:192.0.2.2" ],
            @"expires" : [NSDate dateWithTimeIntervalSinceNow:120],
            @"lifetime" : NSFixtureDNSLifetime(),
            @"generation" : old.document[@"globalRuleGeneration"]
        }
    };
    CHECK(NSReplaceRulesFromImport(result, NULL));
    NSPolicy *saved = NSReadPolicy(NULL);
    CHECK([saved.document[@"rules"] isEqual:result.identityRules] &&
          [saved.document[@"globalRules"] isEqual:result.globalRules]);
    CHECK(!saved.document[@"rules"][@"old.app"] && !saved.document[@"rules"][@"com.apple.old"]);
    for (NSString *key in @[ @"default", @"unattributed", @"allowAppleSystemProcesses", @"filterSockets" ]) {
        CHECK([saved.document[key] isEqual:local[key]]);
    }
    for (NSString *key in
         @[ @"ruleDestinations", @"askGenerations", @"globalDomainAddresses", @"globalDomainLifetimes" ]) {
        CHECK(![saved.document[key] count]);
    }
    CHECK(![saved.document[@"revision"] isEqual:old.document[@"revision"]]);
    CHECK(!NSPermissionGenerationMatches(saved, identified) &&
          !NSPermissionGenerationMatches(saved, unidentified));
    CHECK(NSShouldWithdrawPermissionRequestNotification(saved, identified, YES));
    CHECK(NSShouldWithdrawPermissionRequestNotification(saved, once, YES));
    CHECK(![queue takeResponse:staleResponse policy:saved now:2]);
    CHECK(!NSAnswerPermissionRequest(identified, YES, NULL));
    [queue resolveWithPolicy:saved now:2];
    CHECK(invalidated == 3 && queue.requests.count == 0);
    [history resolveWithPolicy:saved now:NSPermissionTimeout + 3];
    CHECK(history.requests.count == 0);
    NSMutableDictionary *dnsTarget = [saved.document mutableCopy];
    CHECK(!NSApplyDNSResults(dnsTarget, pendingDNS, NSDate.date));
    CHECK(![dnsTarget[@"globalDomainAddresses"] count]);
    CHECK([activityBefore isEqual:NSReadBoundedFile([NSSharedDirectory openRoot:NSSharedURL(@"")
                                                                           leaf:NSMonitorFile
                                                                          error:NULL],
                                                    NSMonitorFile, NULL)]);
    NSData *exported = NSRulesAndActivityJSON(saved, @[], @"2.8.9", NULL);
    NSRuleImportResult *roundTrip = NSParseRulesJSON(exported, NULL);
    CHECK(roundTrip && exported.length <= NSMaximumRuleTransferBytes);
    CHECK([roundTrip.identityRules isEqual:result.identityRules] &&
          [roundTrip.globalRules isEqual:result.globalRules]);
    NSString *epoch = saved.document[@"ruleSetEpoch"],
             *dnsGeneration = saved.document[@"globalRuleGeneration"];
    CHECK(NSReplaceRulesFromImport(roundTrip, NULL));
    CHECK(![NSReadPolicy(NULL).document[@"ruleSetEpoch"] isEqual:epoch]);
    CHECK(![NSReadPolicy(NULL).document[@"globalRuleGeneration"] isEqual:dnsGeneration]);
    // Storage contention never publishes a preparatory wipe.
    NSDictionary *before = NSReadPolicy(NULL).document;
    NSStoreLock *lock = [NSStoreLock tryLockRoot:NSSharedURL(@"") leaf:@"policy.lock" error:NULL];
    CHECK(lock);
    CHECK(!NSReplaceRulesFromImport(result, NULL));
    [lock unlock];
    CHECK([NSReadPolicy(NULL).document isEqual:before]);
    // Fatal admission failures do not reach replacement.
    for (id version in @[ @1, @2, @4, @YES, @3.5, NSNull.null ]) {
        NSMutableDictionary *bad = [envelope mutableCopy];
        bad[@"schemaVersion"] = version;
        CHECK(!NSParseRulesJSON(RulesJSON(bad), NULL));
    }
    for (NSString *field in @[ @"schemaVersion", @"globalRules", @"appRules", @"systemRules" ]) {
        NSMutableDictionary *bad = [envelope mutableCopy];
        [bad removeObjectForKey:field];
        CHECK(!NSParseRulesJSON(RulesJSON(bad), NULL));
        bad[field] = @{};
        CHECK(!NSParseRulesJSON(RulesJSON(bad), NULL));
    }
    CHECK(!NSParseRulesJSON([@"{" dataUsingEncoding:NSUTF8StringEncoding], NULL));
    CHECK(!NSParseRulesJSON(RulesJSON(@[]), NULL));
    CHECK(!NSParseRulesJSON([NSMutableData dataWithLength:NSMaximumRuleTransferBytes + 1], NULL));
    CHECK([NSReadPolicy(NULL).document isEqual:before]);
    // First valid entry wins, independent of verdict; indices/reasons are stable.
    envelope[@"globalRules"] = @[
        NSNull.null, @{@"condition" : NSGlobalRuleCondition(global), @"action" : @"block"},
        @{@"condition" : NSGlobalRuleCondition(global), @"action" : @"allow"}
    ];
    envelope[@"appRules"] = @[
        @{@"identity" : @"bad", @"rule" : @"allow"},
        @{@"identity" : @"new.app",
          @"rule" : @{@"both" : @"allow"}},
        @{@"identity" : @"new.app",
          @"rule" : @{@"both" : @"block"}},
        @{@"identity" : @"com.apple.wrong",
          @"rule" : @{@"both" : @"allow"}}
    ];
    envelope[@"systemRules"] = @[ @{@"identity" : @"wrong.app", @"rule" : @{@"both" : @"block"}} ];
    result = NSParseRulesJSON(RulesJSON(envelope), NULL);
    CHECK(result && [result.acceptedCounts[@"globalRules"] isEqual:@1] &&
          [result.acceptedCounts[@"appRules"] isEqual:@1]);
    CHECK([result.rejectedCounts isEqual:@{@"globalRules" : @2, @"appRules" : @3, @"systemRules" : @1}]);
    CHECK([result.rejections isEqual:NSParseRulesJSON(RulesJSON(envelope), NULL).rejections]);
    CHECK([result.identityRules[@"new.app"] isEqual:@{@"both" : @"allow"}]);
    CHECK(NSReplaceRulesFromImport(result, NULL));
    for (NSArray *entries in @[ @[], @[ NSNull.null ] ]) {
        envelope[@"globalRules"] = entries;
        envelope[@"appRules"] = entries;
        envelope[@"systemRules"] = entries;
        result = NSParseRulesJSON(RulesJSON(envelope), NULL);
        CHECK(result);
        CHECK(NSReplaceRulesFromImport(result, NULL));
        CHECK([NSReadPolicy(NULL).document[@"rules"] count] == 0 &&
              [NSReadPolicy(NULL).document[@"globalRules"] count] == 0);
        CHECK([result.summary containsString:@"zero saved rules"]);
    }
    NSMutableArray *excess = [NSMutableArray new];
    for (NSUInteger i = 0; i <= NSMaximumRules; i++) {
        [excess addObject:@{
            @"identity" : [NSString stringWithFormat:@"capacity.%lu", (unsigned long)i],
            @"rule" : @{@"both" : @"block"}
        }];
    }
    envelope[@"globalRules"] = @[];
    envelope[@"appRules"] = excess;
    envelope[@"systemRules"] = @[];
    result = NSParseRulesJSON(RulesJSON(envelope), NULL);
    CHECK(result.identityRules.count == NSMaximumRules && [result.rejectedCounts[@"appRules"] isEqual:@1]);
    for (NSUInteger i = 0; i < 30; i++) {
        excess[i] = NSNull.null;
    }
    envelope[@"appRules"] = [excess subarrayWithRange:NSMakeRange(0, 30)];
    result = NSParseRulesJSON(RulesJSON(envelope), NULL);
    CHECK(result.rejections.count == 20 && [result.rejectedCounts[@"appRules"] isEqual:@30]);
    CHECK([result.summary containsString:@"Additional rejected entries"]);
    // Output and encoded-policy limits fail explicitly, without a publication.
    NSError *capacityError = nil;
    NSString *huge = [@"x" stringByPaddingToLength:NSMaximumRuleTransferBytes
                                        withString:@"x"
                                   startingAtIndex:0];
    CHECK(!NSRulesAndActivityJSON(NSReadPolicy(NULL), @[ @{@"time" : NSDate.date, @"text" : huge} ], @"2.8.9",
                                  &capacityError));
    CHECK(capacityError);
    before = NSReadPolicy(NULL).document;
    CHECK(!NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *d, NSError **error) {
            NSMutableDictionary *generations = [NSMutableDictionary new];
            for (NSUInteger i = 0; i < 2200; i++) {
                NSString *key = [[NSString stringWithFormat:@"capacity.%lu.", (unsigned long)i]
                    stringByPaddingToLength:NSMaximumIdentityLength
                                 withString:@"x"
                            startingAtIndex:0];
                generations[key] = @"selection";
            }
            d[@"askGenerations"] = generations;
            return YES;
        },
        NULL));
    CHECK([NSReadPolicy(NULL).document isEqual:before]);
    CHECK(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
}
static void TestReleaseVersions(void) {
    CHECK([NSCompareReleaseVersions(@"v2.3.3", @"2.3.2") isEqual:@(NSOrderedDescending)]);
    CHECK([NSCompareReleaseVersions(@"2.10.0", @"2.9.9") isEqual:@(NSOrderedDescending)]);
    CHECK([NSCompareReleaseVersions(@"3.0.0", @"2.99.99") isEqual:@(NSOrderedDescending)]);
    CHECK([NSCompareReleaseVersions(@"2.3.2", @"2.3.2") isEqual:@(NSOrderedSame)]);
    CHECK([NSCompareReleaseVersions(@" V2.3.2 ", @"2.3.2.0") isEqual:@(NSOrderedSame)]);
    CHECK([NSCompareReleaseVersions(@"2.3.0", @"2.3.2") isEqual:@(NSOrderedAscending)]);
    for (id bad in @[
             @"", @"v", @"2..3", @"2.3.2-beta", @"release-2.3.2", @"2.3.2junk", @"2.3.-1", @"9999999999.1",
             @42, NSNull.null
         ]) {
        CHECK(!NSCompareReleaseVersions(bad, @"2.3.2"));
        CHECK(!NSCompareReleaseVersions(@"2.3.2", bad));
    }
    CHECK([NSPublishedReleaseVersion(
        @{@"tag_name" : @"v2.3.3",
          @"draft" : @NO,
          @"prerelease" : @NO}) isEqual:@"v2.3.3"]);
    for (id bad in @[
             @[], NSNull.null, @{}, @{@"message" : @"rate limited"}, @{@"tag_name" : @"2.3.3"},
             @{@"tag_name" : @"2.3.3",
               @"draft" : @YES,
               @"prerelease" : @NO},
             @{@"tag_name" : @"2.3.3",
               @"draft" : @NO,
               @"prerelease" : @YES},
             @{@"tag_name" : @123,
               @"draft" : @NO,
               @"prerelease" : @NO}
         ]) {
        CHECK(!NSPublishedReleaseVersion(bad));
    }
}
static void TestCompositeAppRules(void) {
    NSDictionary *first = NSAppRuleBySelecting(nil, @"allow-outbound");
    CHECK([NSAppRuleBySelecting(first, @"allow-outbound") isEqual:first]);
    NSDictionary *mixed = NSAppRuleBySelecting(first, @"block-inbound");
    CHECK(NSAppRuleSelections(mixed).count == 2);
    NSPolicy *policy = Policy(@{@"app" : mixed});
    CHECK([policy allowsIdentity:@"app" direction:NSFlowDirectionOutbound]);
    CHECK(![policy allowsIdentity:@"app" direction:NSFlowDirectionInbound]);
    CHECK(![policy requiresPermissionForIdentity:@"app"]);
    NSDictionary *both = NSAppRuleBySelecting(mixed, @"allow");
    CHECK([NSAppRuleSelections(both) isEqual:@[ @"allow" ]]);
    CHECK([NSAppRuleBySelecting(both, @"block-inbound") isEqual:mixed]);
    CHECK(!NSAppRuleRecord(@{@"both" : @"allow", @"inbound" : @"block"}));
    CHECK(!NSAppRuleRecord(@{@"inbound" : @"ask"}));
    CHECK(!NSAppRuleRecord(@"allow"));
    for (NSNumber *schema in @[ @2, @3, @4 ]) {
        NSMutableDictionary *old = [[NSPolicy defaultDocument] mutableCopy];
        old[@"schema"] = schema;
        CHECK(![NSPolicy policyWithDocument:old error:NULL]);
    }
}

static void TestAppRuleEditorTransitions(void) {
    id none = NSNull.null;
    NSArray *cases = @[
        @[ none, @"allow", @"allow" ], @[ none, @"block", @"block" ], @[ @"allow", @"allow", none ],
        @[ @"block", @"block", none ], @[ @"allow", @"block", @"block" ], @[ @"block", @"allow", @"allow" ],
        @[ @"allow", @"block-inbound", @"block-inbound" ],
        @[ @"block", @"allow-outbound", @"allow-outbound" ], @[ @"allow-inbound", @"allow-inbound", none ],
        @[ @"block-outbound", @"block-outbound", none ],
        @[ @"allow-inbound", @"block-inbound", @"block-inbound" ],
        @[ @"block-outbound", @"allow-outbound", @"allow-outbound" ],
        @[ @"allow-inbound", @"block-outbound", @{@"inbound" : @"allow", @"outbound" : @"block"} ],
        @[ @"block-outbound", @"allow-inbound", @{@"inbound" : @"allow", @"outbound" : @"block"} ],
        @[ @{@"inbound" : @"allow", @"outbound" : @"block"}, @"allow-inbound", @"block-outbound" ],
        @[ @{@"inbound" : @"allow", @"outbound" : @"block"}, @"block-outbound", @"allow-inbound" ],
        @[
            @{@"inbound" : @"allow", @"outbound" : @"block"}, @"block-inbound",
            @{@"inbound" : @"block", @"outbound" : @"block"}
        ],
        @[ @{@"inbound" : @"allow", @"outbound" : @"block"}, @"allow", @"allow" ],
        @[ @{@"inbound" : @"block", @"outbound" : @"allow"}, @"block", @"block" ]
    ];
    for (NSArray *test in cases) {
        id input = test[0];
        NSDictionary *previous =
            [input isKindOfClass:NSString.class] ? NSAppRuleBySelecting(nil, input) : NSAppRuleRecord(input);
        NSDictionary *result = NSAppRuleByTogglingSelection(previous, test[1]);
        id output = test[2];
        NSDictionary *expected = [output isKindOfClass:NSString.class] ? NSAppRuleBySelecting(nil, output)
                                                                       : NSAppRuleRecord(output);
        CHECK(expected ? [result isEqual:expected] : result == nil);
    }
    // Default fallback respects both global precedence and the system allowance.
    for (NSString *identity in @[ @"editor.app", @"com.apple.editor" ]) {
        for (NSString *fallback in @[ @"ask", @"allow", @"block" ]) {
            CHECK(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
            CHECK(NSUpdatePolicy(
                ^BOOL(NSMutableDictionary *document, NSError **error) {
                    document[@"allowAppleSystemProcesses"] = @NO;
                    document[@"default"] = fallback;
                    document[@"rules"][identity] = NSAppRuleBySelecting(nil, @"allow");
                    return NSToggleAppRule(document, identity, @"allow", error);
                },
                NULL));
            NSPolicy *policy = NSReadPolicy(NULL);
            CHECK(!policy.document[@"rules"][identity]);
            CHECK([policy.document[@"askGenerations"][identity] length] > 0);
            CHECK([policy requiresPermissionForIdentity:identity
                                              direction:NSFlowDirectionInbound
                                            destination:@{}] == [fallback isEqual:@"ask"]);
            CHECK([policy allowsIdentity:identity
                               direction:NSFlowDirectionInbound] == [fallback isEqual:@"allow"]);
            NSMutableDictionary *document = [policy.document mutableCopy];
            document[@"allowAppleSystemProcesses"] = @YES;
            NSPolicy *systemPolicy = [NSPolicy policyWithDocument:document error:NULL];
            if (NSIsAppleSystemIdentity(identity)) {
                CHECK([systemPolicy allowsIdentity:identity direction:NSFlowDirectionInbound]);
                CHECK(![systemPolicy requiresPermissionForIdentity:identity]);
            }
            document[@"globalRules"] =
                @{NSFixtureGlobal(identity, @"", @"", @"", @"any", @"block") : @"block"};
            NSPolicy *globalPolicy = [NSPolicy policyWithDocument:document error:NULL];
            CHECK(![globalPolicy allowsIdentity:identity direction:NSFlowDirectionInbound]);
            CHECK(![globalPolicy requiresPermissionForIdentity:identity]);
        }
    }
    CHECK(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
    NSPermissionQueue *queue = [NSPermissionQueue new];
    [queue resolveWithPolicy:NSReadPolicy(NULL) now:0];
    NSDictionary *old = [queue enqueueIdentity:@"editor.app"
                                     direction:NSFlowDirectionInbound
                                           now:0
                                          date:NSDate.date
                                    completion:^(BOOL allow) {
                                        CHECK(!allow);
                                    }];
    [queue resolveWithPolicy:NSReadPolicy(NULL) now:31];
    CHECK(queue.requests.count == 1);
    CHECK(NSWriteDocument(Monitor(queue.requests, YES, NSEngineVersion, NSDate.date), NSMonitorFile, NULL));
    SaveRule(@"editor.app", @"allow");
    CHECK(NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *document, NSError **error) {
            return NSToggleAppRule(document, @"editor.app", @"allow-outbound", error);
        },
        NULL));
    NSPolicy *partial = NSReadPolicy(NULL);
    CHECK([partial.document[@"rules"][@"editor.app"] isEqual:NSAppRuleBySelecting(nil, @"allow-outbound")]);
    CHECK(!NSAnswerPermissionRequest(old, YES, NULL));
    [queue resolveWithPolicy:partial now:32];
    CHECK(queue.requests.count == 0);
    NSDictionary *fresh = [queue enqueueIdentity:@"editor.app"
                                       direction:NSFlowDirectionInbound
                                             now:33
                                            date:NSDate.date
                                      completion:^(BOOL allow) {
                                          CHECK(!allow);
                                      }];
    CHECK(fresh && ![fresh[@"token"] isEqual:old[@"token"]]);
    CHECK([fresh[@"askGeneration"] isEqual:NSPermissionGeneration(partial, @"editor.app")]);
    // Failed transactions retain both the actual checkmarks and generation.
    CHECK(!NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *document, NSError **error) {
            CHECK(NSToggleAppRule(document, @"editor.app", @"allow-outbound", error));
            return NO;
        },
        NULL));
    CHECK([NSReadPolicy(NULL).document isEqual:partial.document]);
    CHECK(NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *document, NSError **error) {
            return NSToggleAppRule(document, @"editor.app", @"allow-outbound", error);
        },
        NULL));
    CHECK(!NSReadPolicy(NULL).document[@"rules"][@"editor.app"]);
    CHECK(![NSReadPolicy(NULL).document[@"askGenerations"][@"editor.app"]
        isEqual:partial.document[@"askGenerations"][@"editor.app"]]);
    [queue resolveWithPolicy:NSReadPolicy(NULL) now:34];
    CHECK(queue.requests.count == 0);
}

static void TestDirectionalAppAllows(void) {
    for (NSString *rule in @[ @"allow-inbound", @"allow-outbound" ]) {
        NSFlowDirection matching =
            [rule isEqual:@"allow-inbound"] ? NSFlowDirectionInbound : NSFlowDirectionOutbound;
        NSFlowDirection opposite =
            matching == NSFlowDirectionInbound ? NSFlowDirectionOutbound : NSFlowDirectionInbound;
        for (NSString *fallback in @[ @"allow", @"block", @"ask" ]) {
            NSMutableDictionary *document = [[NSPolicy defaultDocument] mutableCopy];
            document[@"rules"] = @{@"direction.app" : NSAppRuleBySelecting(nil, rule)};
            document[@"default"] = fallback;
            NSPolicy *policy = [NSPolicy policyWithDocument:document error:NULL];
            CHECK(policy != nil);
            CHECK([policy allowsIdentity:@"direction.app" direction:matching]);
            CHECK(![policy requiresPermissionForIdentity:@"direction.app"
                                               direction:matching
                                             destination:@{}]);
            for (NSNumber *direction in @[ @(opposite), @(NSFlowDirectionUnknown) ]) {
                CHECK([policy allowsIdentity:@"direction.app"
                                   direction:direction.integerValue] == [fallback isEqual:@"allow"]);
                CHECK([policy requiresPermissionForIdentity:@"direction.app"
                                                  direction:direction.integerValue
                                                destination:@{}] == [fallback isEqual:@"ask"]);
            }
            document[@"globalRules"] =
                @{NSFixtureGlobal(@"direction.app", @"", @"", @"", @"any", @"block") : @"block"};
            policy = [NSPolicy policyWithDocument:document error:NULL];
            CHECK(![policy allowsIdentity:@"direction.app" direction:matching]);
            CHECK(![policy requiresPermissionForIdentity:@"direction.app"
                                               direction:opposite
                                             destination:@{}]);
            document[@"globalRules"] = @{};
            document[@"default"] = rule;
            CHECK(![NSPolicy policyWithDocument:document error:NULL]);
            document[@"default"] = fallback;
            document[@"unattributed"] = rule;
            CHECK(![NSPolicy policyWithDocument:document error:NULL]);
        }

        CHECK(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
        NSPermissionQueue *queue = [NSPermissionQueue new];
        [queue resolveWithPolicy:NSReadPolicy(NULL) now:0];
        __block NSUInteger allowed = 0, blocked = 0;
        NSDictionary *request = [queue enqueueIdentity:@"direction.app"
                                             direction:matching
                                                   now:1
                                                  date:NSDate.date
                                            completion:^(BOOL allow) {
                                                CHECK(allow);
                                                allowed++;
                                            }];
        [queue enqueueIdentity:@"direction.app"
                     direction:opposite
                           now:1
                          date:NSDate.date
                    completion:^(BOOL allow) {
                        CHECK(!allow);
                        blocked++;
                    }];
        CHECK(
            NSWriteDocument(Monitor(queue.requests, YES, NSEngineVersion, NSDate.date), NSMonitorFile, NULL));
        CHECK(NSAnswerPermissionRequestWithRule(request, rule, NULL));
        CHECK([NSReadPolicy(NULL).document[@"rules"][@"direction.app"]
            isEqual:NSAppRuleBySelecting(nil, rule)]);
        [queue resolveWithPolicy:NSReadPolicy(NULL) now:2];
        CHECK(allowed == 1 && blocked == 0 && queue.waitingCount == 1);
        NSDictionary *remaining = queue.requests.firstObject;
        CHECK([NSReadPolicy(NULL) requiresPermissionForRequest:remaining]);
        CHECK(![NSReadPolicy(NULL) requiresPermissionForRequest:request]);
        CHECK(
            NSWriteDocument(Monitor(queue.requests, YES, NSEngineVersion, NSDate.date), NSMonitorFile, NULL));
        NSMutableDictionary *forged = [remaining mutableCopy];
        forged[@"direction"] = request[@"direction"];
        CHECK(!NSAnswerPermissionRequestWithRule(forged, @"block", NULL));
        NSString *oppositeBlock =
            [remaining[@"direction"] isEqual:@"inbound"] ? @"block-inbound" : @"block-outbound";
        CHECK(NSAnswerPermissionRequestWithRule(remaining, oppositeBlock, NULL));
        CHECK(NSAppRuleSelections(NSReadPolicy(NULL).document[@"rules"][@"direction.app"]).count == 2);
        [queue resolveWithPolicy:NSReadPolicy(NULL) now:3];
        CHECK(allowed == 1 && blocked == 1 && queue.requests.count == 0);
    }
}

static void TestDirectionalPermissionAnswers(void) {
    for (NSString *rule in @[ @"block-inbound", @"block-outbound" ]) {
        CHECK(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
        NSPermissionQueue *queue = [NSPermissionQueue new];
        [queue resolveWithPolicy:NSReadPolicy(NULL) now:0];
        NSDictionary *destination = @{@"domain" : @"incoming.example"};
        NSDictionary *request = [queue
            enqueueIdentity:@"incoming.app"
                  direction:[rule isEqual:@"block-inbound"] ? NSFlowDirectionInbound : NSFlowDirectionOutbound
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
        CHECK([policy.document[@"rules"][@"incoming.app"] isEqual:NSAppRuleBySelecting(nil, rule)]);
        CHECK([policy.document[@"ruleDestinations"][@"incoming.app"] isEqual:destination]);
        CHECK([policy allowsIdentity:@"incoming.app" direction:NSFlowDirectionInbound] == NO);
        CHECK(![policy allowsIdentity:@"incoming.app" direction:NSFlowDirectionOutbound]);
        CHECK(!NSAnswerPermissionRequestWithRule(request, rule, NULL));
    }
}

static NSArray<NSDictionary *> *PublishUnidentifiedRequests(NSPermissionQueue *queue) {
    NSMutableDictionary *monitor = [Monitor(@[], YES, NSEngineVersion, NSDate.date) mutableCopy];
    monitor[@"schema"] = @(NSMonitorSchemaVersion);
    monitor[@"session"] = @"session";
    monitor[@"activation"] = @"activation";
    NSMutableArray *requests = [NSMutableArray new];
    for (NSDictionary *entry in queue.requests) {
        NSMutableDictionary *request = [entry mutableCopy];
        request[@"session"] = monitor[@"session"];
        request[@"activation"] = monitor[@"activation"];
        [requests addObject:request];
    }
    monitor[@"requests"] = requests;
    CHECK(NSWriteMonitorSnapshot(monitor, NULL));
    return NSReadMonitor()[@"requests"];
}

static void TestUnidentifiedExactRules(void) {
    NSMutableDictionary *legacy = [[NSPolicy defaultDocument] mutableCopy];
    CHECK([legacy[@"unattributed"] isEqual:@"allow"]);
    legacy[@"schema"] = @3;
    legacy[@"unattributed"] = @"block";
    CHECK(NSWriteDocument(legacy, NSPolicyFile, NULL));
    CHECK(!NSEnsurePolicy(NULL));
    CHECK([NSReadDocument(NSPolicyFile, NULL)[@"schema"] isEqual:@3]);
    CHECK(!NSReadPolicy(NULL));
    CHECK(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
    legacy = [[NSPolicy defaultDocument] mutableCopy];
    NSMutableDictionary *oldMonitor = [Monitor(@[], YES, NSEngineVersion - 1, NSDate.date) mutableCopy];
    oldMonitor[@"activation"] = @"activation";
    CHECK(NSWriteDocument(oldMonitor, NSMonitorFile, NULL));
    CHECK(!NSSetUnidentifiedMode(legacy, @"ask", YES, YES, NSEngineVersion, @"activation", NULL));
    CHECK([legacy[@"schema"] isEqual:@(NSSchemaVersion)]);
    oldMonitor[@"engine"] = @(NSEngineVersion);
    oldMonitor[@"schema"] = @(NSMonitorSchemaVersion);
    CHECK(NSWriteDocument(oldMonitor, NSMonitorFile, NULL));
    NSMutableDictionary *candidate = [legacy mutableCopy];
    CHECK(!NSSetUnidentifiedMode(candidate, @"ask", YES, YES, NSEngineVersion, @"earlier-activation", NULL));
    CHECK(NSSetUnidentifiedMode(candidate, @"ask", YES, YES, NSEngineVersion, @"activation", NULL));
    CHECK([candidate[@"schema"] isEqual:@(NSSchemaVersion)]);
    oldMonitor[@"controlRunning"] = @NO;
    CHECK(NSWriteDocument(oldMonitor, NSMonitorFile, NULL));
    CHECK(NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *document, NSError **error) {
            document[@"default"] = @"block";
            return NSSetUnidentifiedMode(document, @"ask", YES, NO, 0, nil, error);
        },
        NULL));
    NSPolicy *ask = NSReadPolicy(NULL);
    CHECK([ask.document[@"schema"] isEqual:@(NSSchemaVersion)]);
    CHECK([ask.document[@"unidentifiedAskGeneration"] length]);
    CHECK([ask requiresPermissionForIdentity:nil]);
    CHECK(![ask requiresPermissionForIdentity:@"example.app"]);
    CHECK(![ask allowsIdentity:nil direction:NSFlowDirectionUnknown]);

    NSDictionary *destination = @{
        @"domain" : @"Example.COM.",
        @"address" : @"::ffff:192.0.2.10",
        @"port" : @443,
        @"localPort" : @51000,
        @"protocol" : @"tcp"
    };
    NSDictionary *canonical = NSCanonicalConnectionDestination(destination);
    NSPermissionQueue *queue = [NSPermissionQueue new];
    [queue resolveWithPolicy:NSReadPolicy(NULL) now:0];
    [queue resolveWithPolicy:ask now:0];
    __block NSUInteger allowed = 0;
    void (^result)(NSPermissionResult) = ^(NSPermissionResult verdict) {
        allowed += verdict == NSPermissionAllowedByPolicy;
    };
    for (NSDictionary *peer in
         @[ destination, canonical, @{@"domain" : @"example.com", @"address" : @"192.0.2.11"} ]) {
        [queue enqueueIdentity:@""
                     direction:NSFlowDirectionOutbound
                   destination:peer
                          flow:@""
                           now:1
                          date:NSDate.date
                        result:result];
    }
    CHECK(queue.requests.count == 2 && queue.waitingCount == 3);
    NSDictionary *request = PublishUnidentifiedRequests(queue).firstObject;
    CHECK([request[@"destination"] isEqual:canonical] && [request[@"waiting"] isEqual:@2]);
    NSMutableDictionary *forged = [request mutableCopy];
    for (NSString *key in
         @[ @"session", @"activation", @"askGeneration", @"fingerprint", @"direction", @"kind" ]) {
        forged[key] = @"forged";
        CHECK(!NSAnswerPermissionRequestWithRule(forged, @"allow-outbound", NULL));
        forged[key] = request[key];
    }
    CHECK(!NSAnswerPermissionRequestWithRule(request, @"allow", NULL));
    forged[@"destination"] = @{@"domain" : @"forged.example"};
    CHECK(NSAnswerPermissionRequestWithRule(forged, @"allow-outbound", NULL));
    CHECK(!NSAnswerPermissionRequestWithRule(request, @"block-outbound", NULL));
    NSPolicy *saved = NSReadPolicy(NULL);
    NSString *key = [saved.document[@"globalRules"] allKeys].firstObject;
    CHECK([key isEqual:NSExactGlobalRuleKey(@[], canonical, @"outgoing")]);
    CHECK([saved.document[@"rules"] count] == 0);
    CHECK([saved allowsIdentity:@"example.app" direction:NSFlowDirectionOutbound destination:destination]);
    CHECK(![saved allowsIdentity:nil direction:NSFlowDirectionInbound destination:canonical]);
    for (NSString *field in canonical) {
        NSMutableDictionary *missing = [canonical mutableCopy];
        [missing removeObjectForKey:field];
        CHECK(![saved allowsIdentity:nil direction:NSFlowDirectionOutbound destination:missing]);
        CHECK([saved needsSocketDestination:missing identity:nil
                                  direction:NSFlowDirectionOutbound] == ![field isEqual:@"protocol"]);
        CHECK([saved evaluateIdentity:nil direction:NSFlowDirectionOutbound destination:missing socket:NO]
                  .disposition == NSFlowAsk);
        missing[field] = @{
            @"domain" : @"other.example",
            @"address" : @"192.0.2.11",
            @"protocol" : @"udp",
            @"port" : @8443,
            @"localPort" : @51001
        }[field];
        CHECK(![saved allowsIdentity:nil direction:NSFlowDirectionOutbound destination:missing]);
        CHECK(![saved needsSocketDestination:missing identity:nil direction:NSFlowDirectionOutbound]);
    }
    NSMutableDictionary *broad = [ask.document mutableCopy];
    broad[@"globalRules"] = @{
        NSExactGlobalRuleKey(@[], @{@"protocol" : @"other"}, @"outgoing") : @"allow-outbound",
        NSExactGlobalRuleKey(@[], @{}, @"incoming") : @"allow-inbound"
    };
    NSPolicy *partial = [NSPolicy policyWithDocument:broad error:NULL];
    CHECK(partial);
    CHECK([partial allowsIdentity:nil
                        direction:NSFlowDirectionOutbound
                      destination:@{@"protocol" : @"other"}]);
    CHECK(![partial allowsIdentity:nil direction:NSFlowDirectionUnknown destination:@{@"protocol" : @"tcp"}]);
    CHECK(![partial allowsIdentity:nil direction:NSFlowDirectionUnknown]);
    CHECK([partial allowsIdentity:nil direction:NSFlowDirectionInbound]);
    CHECK(NSValidGlobalRuleKey(NSExactGlobalRuleKey(@[], @{}, @"both")));
    [queue resolveWithPolicy:saved now:2];
    CHECK(allowed == 2 && queue.waitingCount == 1);
    [queue cancelAll];
    NSMutableDictionary *incompatible = [saved.document mutableCopy];
    incompatible[@"unattributed"] = @"allow";
    incompatible[@"schema"] = @3;
    [incompatible removeObjectForKey:@"unidentifiedAskGeneration"];
    CHECK(![NSPolicy policyWithDocument:incompatible error:NULL]);
    NSData *exportData = NSRulesAndActivityJSON(saved, @[], @"2.8.8", NULL);
    NSDictionary *export = [NSJSONSerialization JSONObjectWithData:exportData options:0 error:NULL];
    CHECK([export[@"schemaVersion"] isEqual:@(NSExportSchemaVersion)] &&
          [NSParseRulesJSON(exportData, NULL).globalRules isEqual:saved.document[@"globalRules"]]);
    CHECK(!export[@"responses"]);
}

static void TestUnidentifiedOneTimeResponses(void) {
    NSMutableDictionary *document = [[NSPolicy defaultDocument] mutableCopy];
    document[@"unattributed"] = @"ask";
    document[@"unidentifiedAskGeneration"] = @"generation";
    CHECK(NSWriteDocument(document, NSPolicyFile, NULL));
    NSPolicy *policy = NSReadPolicy(NULL);
    NSPermissionQueue *queue = [NSPermissionQueue new];
    [queue resolveWithPolicy:NSReadPolicy(NULL) now:0];
    [queue resolveWithPolicy:policy now:0];
    __block NSMutableArray *results = [NSMutableArray new];
    void (^result)(NSPermissionResult) = ^(NSPermissionResult verdict) {
        [results addObject:@(verdict)];
    };
    for (NSString *flow in @[ @"first", @"second", @"third" ]) {
        [queue enqueueIdentity:@""
                     direction:NSFlowDirectionUnknown
                   destination:@{}
                          flow:flow
                           now:1
                          date:NSDate.date
                        result:result];
    }
    NSArray *requests = PublishUnidentifiedRequests(queue);
    CHECK(requests.count == 3);
    CHECK(![requests[0][@"token"] isEqual:requests[1][@"token"]]);
    CHECK([requests[0][@"fingerprint"] isEqual:requests[1][@"fingerprint"]]);
    NSMutableDictionary *oldMonitor = [NSReadMonitor() mutableCopy];
    oldMonitor[@"schema"] = @2;
    CHECK(!NSValidateMonitor(oldMonitor, NULL));

    __block NSTimeInterval elapsed = 2;
    dispatch_block_t drain = ^{
        NSDrainPermissionResponses(@"session", @"activation",
                                   ^dispatch_block_t(NSDictionary *record, NSPolicy *current) {
                                       return [queue takeResponse:record policy:current now:elapsed];
                                   });
    };
    CHECK(NSAnswerPermissionRequestWithRule(requests[0], @"defer", NULL));
    drain();
    CHECK(queue.waitingCount == 3 && [queue.requests.firstObject[@"deferred"] boolValue]);
    CHECK(results.count == 0);
    CHECK(NSAnswerPermissionRequestWithRule(requests[0], @"allow", NULL));
    CHECK(!NSAnswerPermissionRequestWithRule(requests[0], @"block", NULL));
    NSDictionary *mailbox = NSReadDocument(NSPermissionResponsesFile, NULL);
    NSMutableDictionary *wrong = [mailbox[@"responses"][0] mutableCopy];
    wrong[@"session"] = @"old-session";
    CHECK(NSWriteDocument(@{@"responses" : @[ wrong ]}, NSPermissionResponsesFile, NULL));
    drain();
    CHECK(results.count == 0 && queue.waitingCount == 3);
    CHECK(NSWriteDocument(mailbox, NSPermissionResponsesFile, NULL));
    drain();
    CHECK([results isEqual:@[ @(NSPermissionAllowedOnce) ]] && queue.waitingCount == 2);
    CHECK(NSWriteDocument(mailbox, NSPermissionResponsesFile, NULL));
    drain();
    CHECK(results.count == 1 && queue.waitingCount == 2);
    CHECK(NSAnswerPermissionRequestWithRule(requests[1], @"block", NULL));
    drain();
    CHECK([results.lastObject isEqual:@(NSPermissionBlockedOnce)] && queue.waitingCount == 1);
    CHECK(NSAnswerPermissionRequestWithRule(requests[2], @"allow", NULL));
    elapsed = NSPermissionTimeout + 1;
    drain();
    CHECK(results.count == 2 && queue.waitingCount == 1);
    [queue resolveWithPolicy:policy now:elapsed];
    CHECK([results.lastObject isEqual:@(NSPermissionBlocked)] && queue.waitingCount == 0);
    CHECK(!NSAnswerPermissionRequestWithRule(PublishUnidentifiedRequests(queue).firstObject, @"allow", NULL));
    CHECK([NSReadPolicy(NULL).document isEqual:policy.document]);
    CHECK([queue enqueueIdentity:@""
                       direction:NSFlowDirectionUnknown
                     destination:@{}
                            flow:@"retry"
                             now:elapsed
                            date:NSDate.date
                          result:result]);
    NSDictionary *retry = PublishUnidentifiedRequests(queue).firstObject;
    CHECK(NSAnswerPermissionRequestWithRule(retry, @"allow", NULL));
    for (NSString *mode in @[ @"allow", @"ask" ]) {
        CHECK(NSUpdatePolicy(
            ^BOOL(NSMutableDictionary *current, NSError **error) {
                return NSSetUnidentifiedMode(current, mode, YES, YES, NSEngineVersion, @"activation", error);
            },
            NULL));
    }
    CHECK(!NSPermissionGenerationMatches(NSReadPolicy(NULL), retry));
    drain();
    CHECK(results.count == 3 && queue.waitingCount == 1);
    [queue resolveWithPolicy:NSReadPolicy(NULL) now:elapsed];
    CHECK(queue.waitingCount == 0 && [results.lastObject isEqual:@(NSPermissionBlocked)]);
    [queue cancelAll];
}

static void TestAnswersAndReset(void) {
    CHECK(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
    NSPermissionQueue *queue = [NSPermissionQueue new];
    [queue resolveWithPolicy:NSReadPolicy(NULL) now:0];
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
    CHECK([NSReadPolicy(NULL).document[@"rules"][@"answered"]
        isEqual:NSAppRuleBySelecting(nil, @"allow-outbound")]);
    CHECK([NSReadPolicy(NULL).document[@"rules"][@"edited"] isEqual:NSAppRuleBySelecting(nil, @"block")]);
    CHECK(!NSAnswerPermissionRequest(request, NO, NULL));
    NSString *revision = NSReadPolicy(NULL).document[@"revision"];
    NSURL *container = NSSharedURL(@"");
    NSURL *exportURL = StageExport([@"{}" dataUsingEncoding:NSUTF8StringEncoding], container);
    NSStoreLock *running = NSAcquireProviderLock(NULL);
    CHECK(running != nil);
    CHECK(NSWriteDocument(Monitor(@[], YES, NSEngineVersion, [NSDate dateWithTimeIntervalSinceNow:-60]),
                          NSMonitorFile, NULL));
    CHECK(!NSResetSharedState(NO, NULL));
    CHECK([NSReadPolicy(NULL).document[@"revision"] isEqual:revision]);
    CHECK([NSFileManager.defaultManager fileExistsAtPath:exportURL.path]);
    CHECK([NSFileManager.defaultManager removeItemAtURL:NSSharedURL(NSMonitorFile) error:NULL]);
    CHECK(!NSResetSharedState(NO, NULL));
    [running unlock];
    NSError *error = nil;
    CHECK(!NSResetSharedState(NO, &error));
    CHECK([error.domain isEqual:NSPOSIXErrorDomain] && error.code == EWOULDBLOCK);
    CHECK(!NSRemoveSharedStateAfterFilterRemoval(NULL));
    CHECK([NSReadPolicy(NULL).document[@"revision"] isEqual:revision]);
    CHECK([NSFileManager.defaultManager fileExistsAtPath:exportURL.path]);
    CHECK(NSRemoveStagedExport(container, exportURL, NULL));
    CHECK(NSResetSharedState(NO, NULL));
    CHECK(![NSFileManager.defaultManager fileExistsAtPath:NSSharedURL(NSExportCacheDirectory).path]);
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
    [queue resolveWithPolicy:NSReadPolicy(NULL) now:0];
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
    CHECK(![NSReadPolicy(NULL).document[@"filterSockets"] boolValue]);
    CHECK(![NSReadPolicy(NULL).document[@"allowAppleSystemProcesses"] boolValue]);
    CHECK([NSReadPolicy(NULL).document[@"unattributed"] isEqual:@"block"]);
    CHECK(NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *current, NSError **error) {
            current[@"filterSockets"] = @NO;
            current[@"rules"] = @{@"reset.app" : NSAppRuleBySelecting(nil, @"block")};
            current[@"ruleDestinations"] = @{@"reset.app" : @{@"port" : @443}};
            current[@"globalRules"] =
                @{NSFixtureGlobal(@[], @"reset.example", @"", @"", @"any", @"block") : @"block"};
            current[@"globalDomainAddresses"] = @{@"domain:reset.example" : @[ @"ip:192.0.2.1" ]};
            current[@"globalDomainExpirations"] =
                @{@"domain:reset.example" : [NSDate dateWithTimeIntervalSinceNow:60]};
            current[@"askGenerations"] = @{@"reset.app" : NSUUID.UUID.UUIDString};
            current[@"default"] = @"block";
            return YES;
        },
        NULL));
    CHECK(NSWriteDocument(Monitor(@[], NO, NSEngineVersion, NSDate.date), NSMonitorFile, NULL));
    CHECK(NSWriteDocument(@{@"revision" : @"retry"}, NSNotificationRetryFile, NULL));
    CHECK(NSWriteDocument(@{@"responses" : @[]}, NSPermissionResponsesFile, NULL));
    CHECK(NSClearActivity(NULL));
    CHECK(NSResetSharedState(NO, NULL));
    NSDictionary *reset = NSReadPolicy(NULL).document;
    CHECK([reset[@"filterSockets"] boolValue]);
    CHECK([reset[@"allowAppleSystemProcesses"] boolValue]);
    CHECK([reset[@"unattributed"] isEqual:@"allow"]);
    CHECK([reset[@"default"] isEqual:@"ask"]);
    CHECK([reset[@"rules"] count] == 0 && [reset[@"globalRules"] count] == 0);
    CHECK([reset[@"ruleDestinations"] count] == 0 && [reset[@"globalDomainAddresses"] count] == 0 &&
          [reset[@"globalDomainExpirations"] count] == 0 && [reset[@"askGenerations"] count] == 0);
    CHECK(NSReadMonitor().count == 0);
    for (NSString *name in
         @[ NSMonitorFile, NSNotificationRetryFile, NSActivityClearFile, NSPermissionResponsesFile ]) {
        CHECK(![NSFileManager.defaultManager fileExistsAtPath:NSSharedURL(name).path]);
    }
}

static void TestAppPreferences(void) {
    NSString *domain = [@"NetShield2.Tests." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:domain];
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1000000];
    CHECK([NSUpdateCheckMode(defaults) isEqual:NSUpdateCheckDaily]);
    CHECK(NSAutomaticUpdateCheckDue(defaults, now));
    [defaults setObject:now forKey:NSUpdateCheckLastAttemptKey];
    CHECK(!NSAutomaticUpdateCheckDue(defaults, now));
    CHECK(!NSAutomaticUpdateCheckDue([[NSUserDefaults alloc] initWithSuiteName:domain],
                                     [now dateByAddingTimeInterval:1]));
    CHECK(!NSAutomaticUpdateCheckDue(defaults, [now dateByAddingTimeInterval:86399]));
    CHECK(NSAutomaticUpdateCheckDue(defaults, [now dateByAddingTimeInterval:86400]));
    CHECK(!NSAutomaticUpdateCheckDue(defaults, [now dateByAddingTimeInterval:-1]));
    [defaults setObject:NSUpdateCheckEveryLaunch forKey:NSUpdateCheckModeKey];
    CHECK(NSAutomaticUpdateCheckDue(defaults, now));
    [defaults setObject:NSUpdateCheckOff forKey:NSUpdateCheckModeKey];
    CHECK(!NSAutomaticUpdateCheckDue(defaults, [now dateByAddingTimeInterval:86400]));
    [defaults setObject:@42 forKey:NSUpdateCheckModeKey];
    [defaults setObject:@"invalid date" forKey:NSUpdateCheckLastAttemptKey];
    CHECK([NSUpdateCheckMode(defaults) isEqual:NSUpdateCheckDaily]);
    CHECK(NSAutomaticUpdateCheckDue(defaults, now));
    [defaults setObject:@[ @"hidden.app" ] forKey:@"hiddenRuleIdentities"];
    NSString *migrationTarget =
        [NSString stringWithFormat:@"boot-policy-1/test-os/rootless/%ld/sockets=1", (long)NSEngineVersion];
    CHECK(NSFilterBootPolicyClaimMigration(defaults, migrationTarget, NULL));
    CHECK([[defaults arrayForKey:@"NSBootPolicyAutomaticAttempts"] containsObject:migrationTarget]);
    NSResetAppPreferences(defaults, domain);
    CHECK([defaults persistentDomainForName:domain].count == 0);
    NSUserDefaults *reloaded = [[NSUserDefaults alloc] initWithSuiteName:domain];
    CHECK(![reloaded objectForKey:@"hiddenRuleIdentities"]);
    CHECK(![reloaded objectForKey:NSUpdateCheckLastAttemptKey]);
    CHECK(![reloaded objectForKey:@"NSBootPolicyAutomaticAttempts"]);
    CHECK([NSUpdateCheckMode(reloaded) isEqual:NSUpdateCheckDaily]);
    CHECK(NSAutomaticUpdateCheckDue(reloaded, now));
    CHECK(NSFilterBootPolicyClaimMigration(reloaded, migrationTarget, NULL));
    NSResetAppPreferences(reloaded, domain);
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
- (void)getPendingNotificationRequestsWithCompletionHandler:
    (void (^)(NSArray<UNNotificationRequest *> *))completion {
    completion([self.requests copy]);
}
- (void)getDeliveredNotificationsWithCompletionHandler:(void (^)(NSArray<UNNotification *> *))completion {
    completion(@[]);
}
- (void)getNotificationSettingsWithCompletionHandler:(void (^)(UNNotificationSettings *))completion {
    [self.settingsCompletions addObject:[completion copy]];
}
@end
static void TestLateNotifications(void) {
    CHECK(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
    NSDictionary *request = NSFixtureRequest(
        @{
            @"token" : @"old-token",
            @"identity" : @"notify.app",
            @"destination" : @{@"domain" : @"notify.example", @"address" : @"192.0.2.1"}
        },
        NSReadPolicy(NULL));
    FakeNotificationCenter *center = [FakeNotificationCenter new];
    NSPermissionNotifications *old = [[NSPermissionNotifications alloc] initWithCenter:center];
    [old updateRequests:@[ request ] policy:NSReadPolicy(NULL) retryRevision:nil];
    CHECK(center.requests.count == 1);
    UNNotificationRequest *banner = center.requests.firstObject;
    CHECK([banner.content.title isEqual:@"app"]);
    CHECK([banner.content.body isEqual:@"Open NetShield2 to review notify.example"]);
    CHECK([banner.content.categoryIdentifier isEqual:NSPermissionCategoryForDirection(@"unknown")]);
    CHECK(banner.content.subtitle.length == 0);
    CHECK(banner.content.attachments.count == 0);
    CHECK([banner.content.userInfo isEqual:@{
        @"token" : @"old-token",
        @"identity" : @"notify.app",
        @"direction" : @"unknown",
        @"askGeneration" : request[@"askGeneration"]
    }]);
    CHECK([request[@"destination"][@"domain"] isEqual:@"notify.example"]);
    CHECK([request[@"destination"][@"address"] isEqual:@"192.0.2.1"]);
    CHECK(![banner.content.body containsString:@"192.0.2.1"]);
    [old updateRequests:@[] policy:NSReadPolicy(NULL) retryRevision:nil];
    [center.removed removeAllObjects];
    [center finish:0 error:nil];
    CHECK([center.removed containsObject:((UNNotificationRequest *)center.requests[0]).identifier]);
    CHECK(old.deliveryIssue.length == 0);

    NSPermissionNotifications *current = [[NSPermissionNotifications alloc] initWithCenter:center];
    NSDictionary *next =
        NSFixtureRequest(@{@"token" : @"new-token", @"identity" : @"notify.app", @"direction" : @"unknown"},
                         NSReadPolicy(NULL));
    [current updateRequests:@[ next ] policy:NSReadPolicy(NULL) retryRevision:nil];
    CHECK([((UNNotificationRequest *)center.requests[1]).content.body
        isEqual:@"Open NetShield2 to review this request"]);
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
    CHECK([center.removed containsObject:((UNNotificationRequest *)center.requests[2]).identifier]);
    CHECK(stopped.deliveryIssue.length == 0);

    NSPermissionNotifications *released = [[NSPermissionNotifications alloc] initWithCenter:center];
    [released updateRequests:@[ request ] policy:NSReadPolicy(NULL) retryRevision:nil];
    released = nil;
    [center.removed removeAllObjects];
    [center finish:3 error:nil];
    CHECK([center.removed containsObject:((UNNotificationRequest *)center.requests[3]).identifier]);
    [old stop];
}
static void TestUnidentifiedNotificationActions(void) {
    NSMutableDictionary *document = [[NSPolicy defaultDocument] mutableCopy];
    document[@"unattributed"] = @"ask";
    NSPolicy *policy = [NSPolicy policyWithDocument:document error:NULL];
    FakeNotificationCenter *center = [FakeNotificationCenter new];
    NSPermissionNotifications *notifications = [[NSPermissionNotifications alloc] initWithCenter:center];
    NSDictionary *request = NSFixtureRequest(@{
        @"token" : @"once",
        @"kind" : @"unidentified",
        @"identity" : @"",
        @"direction" : @"unknown",
        @"mode" : @"once",
        @"fingerprint" : @"tuple"
    },
                                             policy);
    [notifications updateRequests:@[ request ] policy:policy retryRevision:nil];
    UNNotificationRequest *banner = center.requests.firstObject;
    NSString *category = banner.content.categoryIdentifier;
    CHECK(NSIsPermissionCategory(category));
    CHECK([banner.content.body containsString:@"No rule will be saved"]);
    CHECK(NSIsPermissionNotificationAction(category, banner.content.userInfo, @"allow"));
    CHECK(NSIsPermissionNotificationAction(category, banner.content.userInfo, @"block"));
    CHECK(NSIsPermissionNotificationAction(category, banner.content.userInfo, NSDeferPermissionAction));
    CHECK(!NSIsPermissionNotificationAction(category, banner.content.userInfo, @"allow-outbound"));
    CHECK(!NSIsPermissionNotificationAction(NSPermissionCategoryForDirection(@"unknown"),
                                            banner.content.userInfo, @"allow"));
    CHECK(!NSIsPermissionNotificationAction(NSPermissionCategoryForDirection(@"unknown"),
                                            @{@"identity" : @"example.app", @"direction" : @"unknown"},
                                            @"block"));
    NSMutableDictionary *deferred = [request mutableCopy];
    deferred[@"deferred"] = @YES;
    [notifications updateRequests:@[ deferred ] policy:policy retryRevision:@"retry"];
    CHECK(center.requests.count == 1 && [center.removed containsObject:banner.identifier]);
    [notifications stop];
}

static void TestDirectionalNotifications(void) {
    CHECK(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
    FakeNotificationCenter *center = [FakeNotificationCenter new];
    NSPermissionNotifications *notifications = [[NSPermissionNotifications alloc] initWithCenter:center];
    NSDictionary *incoming = NSFixtureRequest(
        @{
            @"token" : @"mixed-token",
            @"identity" : @"mixed.app",
            @"direction" : @"inbound",
            @"destination" : @{@"address" : @"192.0.2.10"}
        },
        NSReadPolicy(NULL));
    NSDictionary *outgoing = NSFixtureRequest(
        @{
            @"token" : @"mixed-token",
            @"identity" : @"mixed.app",
            @"direction" : @"outbound",
            @"destination" : @{@"domain" : @"api.example.com", @"address" : @"192.0.2.10", @"port" : @443},
            @"session" : @"notify-session",
            @"activation" : @"notify-activation",
            @"askGeneration" : NSPermissionGeneration(NSReadPolicy(NULL), @"mixed.app")
        },
        NSReadPolicy(NULL));
    [notifications updateRequests:@[ incoming ] policy:NSReadPolicy(NULL) retryRevision:nil];
    CHECK(center.requests.count == 1);
    UNNotificationRequest *incomingBanner = center.requests[0];
    CHECK([incomingBanner.content.body isEqual:@"192.0.2.10\nLong press to Allow or Block"]);
    CHECK([incomingBanner.content.categoryIdentifier isEqual:NSPermissionCategoryForDirection(@"inbound")]);
    SaveRule(@"mixed.app", @"allow-inbound");
    // The same queue token now represents the remaining opposite-direction waiter.
    [notifications updateRequests:@[ outgoing ] policy:NSReadPolicy(NULL) retryRevision:nil];
    CHECK(center.requests.count == 2);
    CHECK([center.removed containsObject:incomingBanner.identifier]);
    UNNotificationRequest *outgoingBanner = center.requests[1];
    CHECK([outgoingBanner.content.body isEqual:@"api.example.com\nLong press to Allow or Block"]);
    CHECK([outgoingBanner.content.categoryIdentifier isEqual:NSPermissionCategoryForDirection(@"outbound")]);
    CHECK([outgoingBanner.content.userInfo isEqual:@{
        @"token" : @"mixed-token",
        @"identity" : @"mixed.app",
        @"direction" : @"outbound",
        @"session" : @"notify-session",
        @"activation" : @"notify-activation",
        @"askGeneration" : NSPermissionGeneration(NSReadPolicy(NULL), @"mixed.app")
    }]);
    // The remaining waiter changes peer without changing the token or direction.
    NSMutableDictionary *nextPeer = [outgoing mutableCopy];
    nextPeer[@"destination"] = @{@"address" : @"2001:db8::10", @"port" : @443};
    [center.removed removeAllObjects];
    [notifications updateRequests:@[ [nextPeer copy] ] policy:NSReadPolicy(NULL) retryRevision:nil];
    CHECK(center.requests.count == 3);
    CHECK([center.removed containsObject:outgoingBanner.identifier]);
    UNNotificationRequest *peerBanner = center.requests[2];
    CHECK(![peerBanner.identifier isEqual:outgoingBanner.identifier]);
    CHECK([peerBanner.content.body isEqual:@"2001:db8::10\nLong press to Allow or Block"]);
    CHECK([peerBanner.content.categoryIdentifier isEqual:NSPermissionCategoryForDirection(@"outbound")]);
    [center.removed removeAllObjects];
    [notifications updateRequests:@[ [nextPeer copy] ] policy:NSReadPolicy(NULL) retryRevision:nil];
    nextPeer[@"destination"] = @{@"address" : @"2001:db8::10", @"port" : @8443};
    [notifications updateRequests:@[ nextPeer ] policy:NSReadPolicy(NULL) retryRevision:nil];
    CHECK(center.requests.count == 3);
    CHECK(center.removed.count == 0);
    void (^duplicate)(NSError *) = center.completions[2];
    [center finish:0 error:nil];
    [center finish:1 error:nil];
    CHECK([center.removed containsObject:incomingBanner.identifier]);
    CHECK([center.removed containsObject:outgoingBanner.identifier]);
    CHECK(![center.removed containsObject:peerBanner.identifier]);
    [center finish:2 error:nil];
    duplicate(nil);
    CHECK(![center.removed containsObject:peerBanner.identifier]);
    CHECK(center.settingsCompletions.count == 1);
    [notifications updateRequests:@[ incoming ] policy:NSReadPolicy(NULL) retryRevision:nil];
    CHECK([center.removed containsObject:peerBanner.identifier]);
    [notifications stop];
    FakeNotificationCenter *copyCenter = [FakeNotificationCenter new];
    NSPermissionNotifications *copyNotifications =
        [[NSPermissionNotifications alloc] initWithCenter:copyCenter];
    for (NSArray *example in @[
             @[ @{}, @"Long press to Allow or Block" ],
             @[
                 @{@"domain" : @"https://bad.example/path", @"address" : @"192.0.2.10"},
                 @"192.0.2.10\nLong press to Allow or Block"
             ],
             @[ @{@"domain" : @"2001:db8::20"}, @"2001:db8::20\nLong press to Allow or Block" ],
             @[
                 @{@"domain" : @"api.example.com",
                   @"address" : @42},
                 @"api.example.com\nLong press to Allow or Block"
             ],
             @[ @{@"domain" : @42,
                  @"address" : @"not-an-address"},
                @"Long press to Allow or Block" ]
         ]) {
        NSMutableDictionary *request = [outgoing mutableCopy];
        request[@"destination"] = example[0];
        [copyNotifications updateRequests:@[ request ] policy:NSReadPolicy(NULL) retryRevision:nil];
        UNNotificationRequest *banner = copyCenter.requests.lastObject;
        CHECK([banner.content.body isEqual:example[1]]);
        CHECK([banner.content.categoryIdentifier isEqual:NSPermissionCategoryForDirection(@"outbound")]);
    }
    [copyNotifications stop];
    // Global-only cases must not inherit the app Allow Incoming selection from
    // the earlier waiter test. Keep the epoch so these request tokens stay current.
    NSMutableDictionary *globalBaseline = [NSReadPolicy(NULL).document mutableCopy];
    globalBaseline[@"rules"] = @{};
    globalBaseline[@"globalRules"] = @{};
    NSPolicy *asking = [NSPolicy policyWithDocument:globalBaseline error:NULL];
    CHECK(asking);
    CHECK(NSPermissionGenerationMatches(asking, incoming));
    CHECK(NSPermissionGenerationMatches(asking, outgoing));
    CHECK([asking requiresPermissionForRequest:incoming]);
    CHECK([asking requiresPermissionForRequest:outgoing]);
    for (NSString *action in @[ @"block-inbound", @"block-outbound" ]) {
        NSMutableDictionary *document = [asking.document mutableCopy];
        document[@"globalRules"] = @{NSFixtureGlobal(@"mixed.app", @"", @"", @"", @"any", action) : action};
        CHECK(NSWriteDocument(document, NSPolicyFile, NULL));
        NSPolicy *directional = NSReadPolicy(NULL);
        CHECK(directional);
        NSDictionary *pending = [action isEqual:@"block-inbound"] ? outgoing : incoming;
        NSDictionary *blocked = [action isEqual:@"block-inbound"] ? incoming : outgoing;
        CHECK([directional requiresPermissionForRequest:pending]);
        CHECK(![directional requiresPermissionForRequest:blocked]);
        FakeNotificationCenter *globalCenter = [FakeNotificationCenter new];
        NSPermissionNotifications *globalNotifications =
            [[NSPermissionNotifications alloc] initWithCenter:globalCenter];
        [globalNotifications updateRequests:@[ incoming, outgoing ] policy:directional retryRevision:nil];
        CHECK(globalCenter.requests.count == 1);
        UNNotificationRequest *globalBanner = globalCenter.requests.firstObject;
        CHECK([globalBanner.content.userInfo[@"direction"] isEqual:pending[@"direction"]]);
        CHECK([globalBanner.content.categoryIdentifier isEqual:NSPermissionCategoryForRequest(pending)]);
        CHECK(![globalCenter.removed
            containsObject:((UNNotificationRequest *)globalCenter.requests[0]).identifier]);
        document[@"globalRules"] =
            @{NSFixtureGlobal(@"mixed.app", @"", @"", @"", @"any", @"block") : @"block"};
        CHECK(NSWriteDocument(document, NSPolicyFile, NULL));
        [globalNotifications updateRequests:@[ incoming, outgoing ]
                                     policy:NSReadPolicy(NULL)
                              retryRevision:nil];
        CHECK([globalCenter.removed
            containsObject:((UNNotificationRequest *)globalCenter.requests[0]).identifier]);
        [globalNotifications stop];
    }
}

// H01: all transitions happen before the old center callback; no timing sleeps.
static void TestNotificationGenerations(void) {
    CHECK(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
    __block NSTimeInterval now = 100;
    FakeNotificationCenter *center = [FakeNotificationCenter new];
    NSPermissionNotifications *notifications = [[NSPermissionNotifications alloc] initWithCenter:center
                                                                                           clock:^{
                                                                                               return now;
                                                                                           }];
    NSDictionary *request =
        NSFixtureRequest(@{@"token" : @"retry-token", @"identity" : @"retry.app"}, NSReadPolicy(NULL));
    [notifications updateRequests:@[ request ] policy:NSReadPolicy(NULL) retryRevision:@"1"];
    [notifications updateRequests:@[ request ] policy:NSReadPolicy(NULL) retryRevision:@"2"];
    CHECK(center.requests.count == 2);
    NSString *oldID = ((UNNotificationRequest *)center.requests[0]).identifier;
    NSString *newID = ((UNNotificationRequest *)center.requests[1]).identifier;
    CHECK(![oldID isEqual:newID]);
    [center.removed removeAllObjects];
    [center finish:0 error:nil];
    CHECK([center.removed containsObject:oldID]);
    CHECK(![center.removed containsObject:newID]);
    [notifications updateRequests:@[] policy:NSReadPolicy(NULL) retryRevision:@"2"];
    [notifications updateRequests:@[ request ] policy:NSReadPolicy(NULL) retryRevision:@"2"];
    CHECK(center.requests.count == 3);
    [center.removed removeAllObjects];
    [center finish:1 error:nil];
    NSString *thirdID = ((UNNotificationRequest *)center.requests[2]).identifier;
    CHECK(![center.removed containsObject:thirdID]);
    // Missing completion is retired at the bounded deadline and gets a new ID.
    now += 10;
    [notifications updateRequests:@[ request ] policy:NSReadPolicy(NULL) retryRevision:@"2"];
    CHECK(center.requests.count == 4);
    [center.removed removeAllObjects];
    [center finish:2 error:nil];
    CHECK(![center.removed containsObject:((UNNotificationRequest *)center.requests[3]).identifier]);
    now += 10;
    [notifications updateRequests:@[ request ] policy:NSReadPolicy(NULL) retryRevision:@"2"];
    CHECK(center.requests.count == 5);
    now += 10;
    [notifications updateRequests:@[ request ] policy:NSReadPolicy(NULL) retryRevision:@"2"];
    CHECK(center.requests.count == 5); // three attempts, including missing callbacks
    [notifications stop];
    [center finish:3 error:nil];
    [center finish:4 error:nil];
    CHECK(notifications.deliveryIssue.length == 0);
}

@interface FakeFilterRemovalManager : NSObject <NSFilterRemovalManager>
@property(nonatomic, strong) id providerConfiguration;
@property(nonatomic, getter=isEnabled) BOOL enabled;
@property(nonatomic, strong) NSError *loadError;
@property(nonatomic, strong) NSError *removeError;
@property(nonatomic, strong) NSError *verifyError;
@property(nonatomic) BOOL retainConfiguration;
@property(nonatomic) BOOL retainEnabled;
@property(nonatomic) BOOL absentAfterRemovalError;
@property(nonatomic) NSUInteger loads;
@property(nonatomic) NSUInteger removals;
@end
@implementation FakeFilterRemovalManager
- (void)loadFromPreferencesWithCompletionHandler:(void (^)(NSError *))completion {
    NSStoreLock *physical = [NSStoreLock tryLockRoot:NSSharedURL(@"")
                                                leaf:NSConfigurationLockFile
                                               error:NULL];
    CHECK(physical);
    [physical unlock];
    self.loads++;
    if (self.loads > 1 && !self.verifyError && (!self.removeError || self.absentAfterRemovalError)) {
        if (!self.retainConfiguration) {
            self.providerConfiguration = nil;
        }
        self.enabled = self.retainEnabled;
    }
    completion(self.loads == 1 ? self.loadError : self.verifyError);
}
- (void)removeFromPreferencesWithCompletionHandler:(void (^)(NSError *))completion {
    NSStoreLock *physical = [NSStoreLock tryLockRoot:NSSharedURL(@"")
                                                leaf:NSConfigurationLockFile
                                               error:NULL];
    CHECK(physical);
    [physical unlock];
    self.removals++;
    completion(self.removeError);
}
@end
static void TestFilterRemoval(void) {
    NSError *failure = [NSError errorWithDomain:@"test.removal" code:1 userInfo:nil];
    for (NSUInteger scenario = 0; scenario < 9; scenario++) {
        FakeFilterRemovalManager *manager = [FakeFilterRemovalManager new];
        manager.providerConfiguration = scenario == 0 ? nil : @{};
        manager.enabled = scenario != 0 && scenario != 7;
        manager.loadError = scenario == 2 ? failure : nil;
        manager.removeError = (scenario == 3 || scenario == 8) ? failure : nil;
        manager.absentAfterRemovalError = scenario == 8;
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
        CHECK((result == nil) == (scenario == 0 || scenario == 1 || scenario == 7 || scenario == 8));
        CHECK(manager.removals == (scenario == 0 || scenario == 2 ? 0 : 1));
        CHECK(manager.loads == (scenario == 0 || scenario == 2 ? 1 : 2));
        if (scenario >= 2 && scenario <= 4) {
            CHECK(result == failure);
        }
    }
}

static NSError *WaitForSharedStateCleanup(NSTimeInterval timeout) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    __block NSUInteger completions = 0;
    __block NSError *result = nil;
    NSRemoveSharedStateAfterFilterRemovalWithRetry(deadline, ^(NSError *error) {
        CHECK(NSThread.isMainThread);
        completions++;
        result = error;
    });
    while (!completions && NSProcessInfo.processInfo.systemUptime < deadline + 1) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    CHECK(completions == 1);
    // Service the queue beyond a retry interval to catch duplicate completion.
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    CHECK(completions == 1);
    return result;
}

static void TestSharedStateCleanupRetries(void) {
    NSArray<NSString *> *files = @[
        NSPolicyFile, NSMonitorFile, NSNotificationRetryFile, NSActivityClearFile, NSPermissionResponsesFile
    ];
    NSArray<NSString *> *locks = @[ @"provider.lock", @"policy.lock", @"activity.lock" ];
    for (NSString *lockName in locks) {
        for (NSNumber *releaseAfterDelay in @[ @YES, @NO ]) {
            for (NSString *name in files) {
                CHECK(NSWriteDocument([NSPolicy defaultDocument], name, NULL));
            }
            NSURL *exportURL = StageExport([@"{}" dataUsingEncoding:NSUTF8StringEncoding], NSSharedURL(@""));
            CHECK(NSRemoveStagedExport(NSSharedURL(@""), exportURL, NULL));
            CHECK([NSFileManager.defaultManager createDirectoryAtURL:exportURL.URLByDeletingLastPathComponent
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:NULL]);
            CHECK([[@"{}" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:exportURL atomically:YES]);
            NSURL *sentinel = NSSharedURL(@"Library/Caches/NetShield2/keep.json");
            CHECK([[@"keep" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:sentinel atomically:YES]);
            NSStoreLock *held = [NSStoreLock tryLockRoot:NSSharedURL(@"") leaf:lockName error:NULL];
            CHECK(held != nil);
            if (releaseAfterDelay.boolValue) {
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
                        for (NSString *name in files) {
                            CHECK([NSFileManager.defaultManager fileExistsAtPath:NSSharedURL(name).path]);
                        }
                        CHECK([NSFileManager.defaultManager fileExistsAtPath:exportURL.path]);
                        // Busy attempts must release every earlier lock while waiting.
                        for (NSString *earlier in locks) {
                            if ([earlier isEqual:lockName]) {
                                break;
                            }
                            NSStoreLock *probe = [NSStoreLock tryLockRoot:NSSharedURL(@"")
                                                                     leaf:earlier
                                                                    error:NULL];
                            CHECK(probe != nil);
                            [probe unlock];
                        }
                        [held unlock];
                    });
            }
            NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
            NSError *error = WaitForSharedStateCleanup(releaseAfterDelay.boolValue ? 2 : 0.35);
            if (releaseAfterDelay.boolValue) {
                CHECK(error == nil);
                for (NSString *name in files) {
                    CHECK(![NSFileManager.defaultManager fileExistsAtPath:NSSharedURL(name).path]);
                }
                CHECK(![NSFileManager.defaultManager fileExistsAtPath:exportURL.path]);
            } else {
                CHECK([error.domain isEqual:@"NetShield2.Uninstall"] && error.code == ETIMEDOUT);
                NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
                CHECK([underlying.domain isEqual:NSPOSIXErrorDomain]);
                CHECK(underlying.code == EWOULDBLOCK || underlying.code == EAGAIN ||
                      underlying.code == EBUSY);
                CHECK([error.localizedDescription containsString:underlying.localizedDescription]);
                NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - started;
                CHECK(elapsed >= 0.35 && elapsed < 1.5);
                for (NSString *name in files) {
                    CHECK([NSFileManager.defaultManager fileExistsAtPath:NSSharedURL(name).path]);
                }
                CHECK([NSFileManager.defaultManager fileExistsAtPath:exportURL.path]);
                [held unlock];
            }
            CHECK(NSRemoveSharedStateAfterFilterRemoval(NULL));
            CHECK(NSRemoveSharedStateAfterFilterRemoval(NULL));
            CHECK(![NSFileManager.defaultManager fileExistsAtPath:NSSharedURL(NSExportCacheDirectory).path]);
            CHECK([NSFileManager.defaultManager fileExistsAtPath:sentinel.path]);
            CHECK([NSFileManager.defaultManager removeItemAtURL:sentinel error:NULL]);
            CHECK(NSRemoveStagedExport(NSSharedURL(@""), exportURL, NULL));
            for (NSString *name in locks) {
                CHECK([NSFileManager.defaultManager fileExistsAtPath:NSSharedURL(name).path]);
            }
        }
    }
    // A missing container fails at lock creation with ENOENT, without waiting
    // for the two-second retry budget or touching the original saved state.
    CHECK(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
    NSURL *container = [NSSharedURL(NSPolicyFile) URLByDeletingLastPathComponent];
    NSSetTestContainer([container URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES]);
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    NSError *error = WaitForSharedStateCleanup(2);
    CHECK([error.domain isEqual:NSPOSIXErrorDomain] && error.code == ENOENT);
    CHECK(NSProcessInfo.processInfo.systemUptime - started < 1);
    NSSetTestContainer(container);
    CHECK([NSFileManager.defaultManager fileExistsAtPath:NSSharedURL(NSPolicyFile).path]);
    CHECK(NSRemoveSharedStateAfterFilterRemoval(NULL));
    FakeFilterRemovalManager *absent = [FakeFilterRemovalManager new];
    __block BOOL cleared = NO, finished = NO;
    NSRemoveInstalledFilterAndSharedState(
        absent, NSProcessInfo.processInfo.systemUptime + 2,
        ^{
            NSError *lockError = nil;
            CHECK(![NSStoreLock tryLockRoot:NSSharedURL(@"") leaf:NSConfigurationLockFile error:&lockError] &&
                  NSIsLockContention(lockError));
            cleared = YES;
        },
        ^(NSError *cleanupError) {
            CHECK(!cleanupError && cleared);
            finished = YES;
        });
    CHECK(finished && absent.removals == 0 && absent.loads == 2);
    CHECK(![NSFileManager.defaultManager fileExistsAtPath:NSSharedURL(NSPolicyFile).path]);
}

extern void NSRunRecoveryTests(void);
extern void NSRunConfigurationTests(void);
extern void NSRunHardeningTests(void);

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
        CHECK([NSSharedURL(@"") isEqual:root]);
        TestPolicyAndCache();
        TestRulesAndActivityExport();
        TestStorageFailureAndRecovery();
        TestConcurrentMutations();
        TestPermissionQueue();
        TestQueueLimitsAndCancellation();
        TestLargePolicyCache();
        TestActivityGrouping();
        TestGlobalRules();
        TestRuleImport();
        TestReleaseVersions();
        TestIdentityDisplay();
        TestDirectionalPermissionAnswers();
        TestUnidentifiedExactRules();
        TestUnidentifiedOneTimeResponses();
        TestCompositeAppRules();
        TestAppRuleEditorTransitions();
        TestDirectionalAppAllows();
        TestAnswersAndReset();
        TestSocketSettingsAndDestinations();
        TestAppPreferences();
        TestLateNotifications();
        TestDirectionalNotifications();
        TestUnidentifiedNotificationActions();
        TestNotificationGenerations();
        TestFilterRemoval();
        TestSharedStateCleanupRetries();
        NSRunRecoveryTests();
        NSRunConfigurationTests();
        NSRunHardeningTests();
        CHECK([NSFileManager.defaultManager removeItemAtURL:root error:NULL]);
        NSLog(@"Passed %lu regression checks", (unsigned long)checks);
    }
    return 0;
}
