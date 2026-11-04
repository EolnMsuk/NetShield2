#import <NetworkExtension/NetworkExtension.h>
#import "../Shared/NSStore.h"
#import "../Shared/NSPermissionQueue.h"
#import "NSPermissionNotifications.h"
#import "../Shared/NSDestination.h"
#import "../Shared/NSFlowDestination.h"
#import "NSDomainResolver.h"
#import "NSProviderWorkQueue.h"
#import "../Shared/NSDNSCache.h"
#include <errno.h>
static char NSControlPathContext;

@interface NSFilterControlProvider : NEFilterControlProvider
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, strong) NSProviderWorkQueue *work;
@property(nonatomic, strong) NSProviderReplyGate *replies;
@property(nonatomic) BOOL observingPath;
@property(nonatomic, strong) dispatch_queue_t delivery;
@property(nonatomic) BOOL pathChangeQueued;
@property(nonatomic) NSUInteger pathGeneration;
@property(nonatomic) BOOL invalidateDNSCache;
@property(nonatomic) BOOL acceptDNS;
@property(nonatomic) NSUInteger lifecycle; // 0 stopped, 1 starting, 2 running, 3 stopping
@property(nonatomic, strong) NSMutableArray *stopCompletions;
@property(nonatomic, copy) void (^startupCompletion)(NSError *);
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *events;
@property(nonatomic, copy) NSString *revision;
@property(nonatomic, copy) NSString *session;
@property(nonatomic, strong) NSDate *lastReport;
@property(nonatomic) BOOL stopped;
@property(nonatomic) BOOL refreshScheduled;
@property(nonatomic, strong) NSPermissionQueue *permissions;
@property(nonatomic, strong) NSPermissionNotifications *notifications;
@property(nonatomic, strong) NSStoreLock *providerLock;
@property(nonatomic, strong) NSDomainResolver *resolver;
@property(nonatomic, strong) NSMutableDictionary *pendingDNS;
@property(nonatomic, strong) NSMutableDictionary *dnsIssues;
@property(nonatomic, copy) NSString *dnsPublicationIssue;
@property(nonatomic, copy) NSString *monitorIssue;
@property(nonatomic) NSTimeInterval nextDNSPublication;
@property(nonatomic) NSTimeInterval lastPublication;
@property(nonatomic, copy) NSDictionary *publishedPayload;
@end

@implementation NSFilterControlProvider
- (instancetype)init {
    if ((self = [super init])) {
        _stopped = YES;
        _work = [[NSProviderWorkQueue alloc] initWithCapacity:512];
        _delivery = dispatch_queue_create("com.eolnmsuk.netshield.control.delivery", DISPATCH_QUEUE_SERIAL);
        _stopCompletions = [NSMutableArray new];
        if (!_work || !_delivery) {
            return nil;
        }
        _replies = [[NSProviderReplyGate alloc] initWithCapacity:NSMaximumWaiters delivery:_delivery];
        [self addObserver:self forKeyPath:@"defaultPath" options:0 context:&NSControlPathContext];
        _observingPath = YES;
    }
    return self;
}
- (void)deliver:(void (^)(void))completion {
    dispatch_async(self.delivery, completion);
}
- (void)appendEvent:(NSDictionary *)event {
    NSDictionary *stamped = NSActivityEventWithCurrentBoundary(event);
    if (!stamped) {
        return;
    }
    [self.events addObject:stamped];
    if (self.events.count > NSMaximumEvents) {
        [self.events removeObjectsInRange:NSMakeRange(0, self.events.count - NSMaximumEvents)];
    }
}
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if (context != &NSControlPathContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    @synchronized(self) {
        if (self.pathChangeQueued) {
            return;
        }
        self.pathChangeQueued = YES;
    }
    dispatch_async(self.work.queue, ^{
        @synchronized(self) {
            self.pathChangeQueued = NO;
        }
        if (self.stopped) {
            return;
        }
        self.invalidateDNSCache = YES;
        self.acceptDNS = NO;
        [self.pendingDNS removeAllObjects];
        NSString *session = self.session;
        NSUInteger generation = ++self.pathGeneration;
        [self.resolver invalidateNetworkWithCompletion:^{
            dispatch_async(self.work.queue, ^{
                if (self.stopped || ![self.session isEqual:session] || self.pathGeneration != generation) {
                    return;
                }
                self.acceptDNS = YES;
                [self scheduleRefresh];
            });
        }];
        [self scheduleRefresh];
    });
}
- (void)dealloc {
    if (_observingPath) {
        [self removeObserver:self forKeyPath:@"defaultPath" context:&NSControlPathContext];
    }
    if (_timer) {
        dispatch_source_cancel(_timer);
    }
    // Normally stop detached everything. On unexpected release, queued state
    // work cannot retain the dying provider, but its waiters still need denial.
    NSPermissionQueue *pending = _permissions;
    NSPermissionNotifications *notifications = _notifications;
    if (_work && (pending || notifications)) {
        dispatch_async(_work.queue, ^{
            [pending cancelAll];
            [notifications stop];
        });
    }
}

- (void)failStartup:(NSError *)error completion:(void (^)(NSError *))completion {
    NSLog(@"NetShield2 control startup failed stage=%@ error=%@/%ld",
          error.userInfo[@"stage"] ?: @"initialize or publish", error.domain, (long)error.code);
    self.lifecycle = 3;
    self.stopped = YES;
    [self.notifications stop];
    if (self.timer) {
        dispatch_source_cancel(self.timer);
        self.timer = nil;
    }
    void (^unwind)(void) = ^{
        dispatch_async(self.work.queue, ^{
            [self.providerLock unlock];
            self.providerLock = nil;
            self.lifecycle = 0;
            [self deliver:^{
                completion(error);
            }];
            NSArray *stops = [self.stopCompletions copy];
            [self.stopCompletions removeAllObjects];
            for (void (^stop)(void) in stops) {
                [self deliver:stop];
            }
        });
    };
    if (self.resolver) {
        [self.resolver stopWithCompletion:unwind];
    } else {
        unwind();
    }
}
- (BOOL)refreshDomainAddresses:(NSPolicy *)policy {
    [self.resolver refreshRules:policy.globalRuleConditions ?: @{}
                     generation:policy.document[@"globalRuleGeneration"]];
    for (NSString *key in self.dnsIssues.allKeys) {
        NSString *rule = policy.globalRuleConditions[key];
        if (!rule || NSGlobalActionIsAllow(rule)) {
            [self.dnsIssues removeObjectForKey:key];
        }
    }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now < self.nextDNSPublication || (!self.invalidateDNSCache && !self.pendingDNS.count)) {
        return NO;
    }
    NSMutableDictionary *preview = [policy.document mutableCopy];
    if (!self.invalidateDNSCache && !NSApplyDNSResults(preview, self.pendingDNS, NSDate.date)) {
        [self.pendingDNS removeAllObjects];
        self.dnsPublicationIssue = @"";
        return NO;
    }
    NSError *error = nil;
    BOOL saved = NSUpdateResolvedDNS(self.pendingDNS, self.invalidateDNSCache, &error);
    if (saved || !error) {
        self.invalidateDNSCache = NO;
        [self.pendingDNS removeAllObjects];
        self.dnsPublicationIssue = @"";
        self.nextDNSPublication = now + 0.5;
    } else {
        BOOL busy =
            [error.domain isEqual:NSPOSIXErrorDomain] && (error.code == EAGAIN || error.code == EWOULDBLOCK);
        self.nextDNSPublication = now + (busy ? 1 : 5);
        self.dnsPublicationIssue =
            [NSString stringWithFormat:@"DNS answers could not be saved: %@", error.localizedDescription];
    }
    return saved;
}
- (NSDictionary *)snapshotWithRunning:(BOOL)running policyError:(NSError *)error {
    // All mutable state belongs to work.queue; delivery never runs on that queue.
    self.events = [NSActivityAfterClear(self.events) mutableCopy];
    NSMutableArray *requests = [NSMutableArray new];
    for (NSDictionary *request in self.permissions.requests) {
        NSMutableDictionary *current = [request mutableCopy];
        current[@"session"] = self.session ?: @"";
        current[@"activation"] = self.filterConfiguration.vendorConfiguration[@"activation"] ?: @"";
        [requests addObject:[current copy]];
    }
    NSUInteger droppedWork = self.work.rejectedCount;
    NSUInteger droppedReplies = self.replies.rejectedCount;
    droppedWork += MIN(NSUIntegerMax - droppedWork, droppedReplies);
    return @{
        @"engine" : @(NSEngineVersion),
        @"schema" : @2,
        @"activityGenerations": @YES,
        @"controlRunning" : @(running),
        @"session" : self.session ?: @"",
        @"activation" : self.filterConfiguration.vendorConfiguration[@"activation"] ?: @"",
        @"updated" : NSDate.date,
        @"lastReport" : self.lastReport ?: [NSDate dateWithTimeIntervalSince1970:0],
        @"revision" : self.revision ?: @"",
        @"policyError" : error.localizedDescription ?: self.monitorIssue ?: @"",
        @"dnsIssue" : self.dnsPublicationIssue.length ? self.dnsPublicationIssue : (self.dnsIssues.allValues.firstObject ?: self.resolver.coverageIssue ?: @""),
        @"events" : [self.events copy] ?: @[],
        @"requests" : [requests copy],
        @"notificationDeliveryIssue" : self.notifications.deliveryIssue ?: @"",
        @"overflowCount" : @(self.permissions.overflowCount),
        @"droppedWorkCount": @(droppedWork),
        @"evictedRequestCount" : @(self.permissions.evictedRequestCount)
    };
}
- (void)refresh {
    if (self.stopped) {
        return;
    }
    NSError *error = nil;
    NSPolicy *policy = NSReadPolicy(&error);
    if (policy && [self refreshDomainAddresses:policy]) {
        policy = NSReadPolicy(&error);
    }
    [self.permissions resolveWithPolicy:policy now:NSProcessInfo.processInfo.systemUptime];
    NSString *retry = NSReadNotificationRetryRevision();
    NSString *revision = policy.document[@"revision"];
    if ((self.revision || revision) && ![self.revision isEqual:revision]) {
        self.revision = revision;
        [self deliver:^{
            [self notifyRulesChanged];
        }];
    }
    NSDictionary *snapshot = [self snapshotWithRunning:YES policyError:error];
    NSMutableDictionary *payload = [snapshot mutableCopy];
    [payload removeObjectForKey:@"updated"];
    NSString *retryKey = retry ?: @"";
    payload[@"retryRevision"] = retryKey;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if ([payload isEqual:self.publishedPayload] && now - self.lastPublication < 3) {
        [self.notifications updateRequests:snapshot[@"requests"] policy:policy retryRevision:retry];
        return;
    }
    NSError *writeError = nil;
    BOOL published = [self.notifications publishSnapshot:snapshot
                                                  policy:policy
                                           retryRevision:retry
                                                   error:&writeError];
    if (published) {
        self.publishedPayload = [payload copy];
        self.lastPublication = now;
    }
    self.monitorIssue = published
                            ? @""
                            : [NSString stringWithFormat:@"Permission requests could not be published: %@",
                                                         writeError.localizedDescription];
}
- (void)scheduleRefresh {
    if (self.refreshScheduled || self.stopped) {
        return;
    }
    self.refreshScheduled = YES;
    NSString *session = self.session;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), self.work.queue, ^{
        NSFilterControlProvider *owner = weakSelf;
        if (!owner) {
            return;
        }
        if (![owner.session isEqual:session] || owner.stopped) {
            return;
        }
        owner.refreshScheduled = NO;
        [owner refresh];
    });
}
- (void)publishInitialSnapshot:(NSUInteger)attempt session:(NSString *)session {
    if (self.lifecycle != 1 || ![self.session isEqual:session]) {
        return;
    }
    NSError *error = nil;
    BOOL published = NSWriteMonitorSnapshot([self snapshotWithRunning:YES policyError:nil], &error);
    if (!published && attempt < 3 && (NSIsLockContention(error) || NSFileReadChanged(error))) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC * 100), self.work.queue, ^{
            [self publishInitialSnapshot:attempt + 1 session:session];
        });
        return;
    }
    void (^completion)(NSError *) = self.startupCompletion;
    self.startupCompletion = nil;
    if (!published) {
        [self failStartup:error completion:completion];
        return;
    }
    self.stopped = NO;
    self.lifecycle = 2;
    [self deliver:^{
        completion(nil);
    }];
}
- (void)startFilterWithCompletionHandler:(void (^)(NSError *))completionHandler {
    dispatch_async(self.work.queue, ^{
        if (self.lifecycle != 0) {
            [self deliver:^{
                completionHandler([NSError
                    errorWithDomain:@"NetShield2.Provider"
                               code:1
                           userInfo:@{
                               NSLocalizedDescriptionKey :
                                   @"Control provider is already starting/running/stopping."
                           }]);
            }];
            return;
        }
        self.lifecycle = 1;
        NSError *error = nil;
        self.stopped = YES;
        self.providerLock = NSAcquireProviderLock(&error);
        if (!self.providerLock) {
            NSLog(@"NetShield2 control startup lock failed stage=%@ error=%@/%ld", error.userInfo[@"stage"],
                  error.domain, (long)error.code);
            self.lifecycle = 0;
            [self deliver:^{
                completionHandler(error);
            }];
            return;
        }
        if (!NSReadPolicy(&error)) {
            NSLog(@"NetShield2 control startup policy failed stage=%@ error=%@/%ld",
                  error.userInfo[@"stage"] ?: @"decode", error.domain, (long)error.code);
            [self.providerLock unlock];
            self.providerLock = nil;
            self.lifecycle = 0;
            [self deliver:^{
                completionHandler(error);
            }];
            return;
        }
        // A new provider session deliberately drops pending requests, but Recent
        // Activity belongs to the persisted monitor snapshot. Apply the clear
        // boundary again so a stale pre-clear snapshot cannot return on restart.
        self.events = [NSActivityAfterClear(NSReadMonitor()[@"events"] ?: @[]) mutableCopy];
        if (self.events.count > NSMaximumEvents) {
            [self.events removeObjectsInRange:NSMakeRange(0, self.events.count - NSMaximumEvents)];
        }
        self.lastReport = nil;
        self.revision = nil;
        self.permissions = [NSPermissionQueue new];
        self.notifications = [NSPermissionNotifications new];
        self.session = NSUUID.UUID.UUIDString;
        self.refreshScheduled = NO;
        self.pendingDNS = [NSMutableDictionary new];
        self.invalidateDNSCache = YES;
        self.acceptDNS = YES;
        self.dnsIssues = [NSMutableDictionary new];
        self.dnsPublicationIssue = @"";
        self.monitorIssue = @"";
        self.nextDNSPublication = 0;
        self.publishedPayload = nil;
        self.lastPublication = 0;
        __weak typeof(self) dnsOwner = self;
        NSString *dnsSession = self.session;
        self.resolver = [[NSDomainResolver alloc]
            initWithCompletion:^(NSString *key, NSString *rule, NSDictionary *result, NSError *lookupError) {
                NSFilterControlProvider *owner = dnsOwner;
                if (!owner) {
                    return;
                }
                dispatch_async(owner.work.queue, ^{
                    if (owner.stopped || !owner.acceptDNS || ![owner.session isEqual:dnsSession]) {
                        return;
                    }
                    if (lookupError) {
                        owner.dnsIssues[key] = lookupError.localizedDescription;
                    } else {
                        [owner.dnsIssues removeObjectForKey:key];
                        NSMutableDictionary *entry = [result mutableCopy];
                        entry[@"rule"] = rule;
                        if (owner.pendingDNS.count < 64 || owner.pendingDNS[key]) {
                            owner.pendingDNS[key] = entry;
                        } else {
                            owner.dnsIssues[key] =
                                @"DNS publication backlog is full; answers will be retried.";
                        }
                    }
                    [owner scheduleRefresh];
                });
            }];
        if (!self.resolver) {
            [self failStartup:[NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil]
                   completion:completionHandler];
            return;
        }
        self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.work.queue);
        if (!self.timer) {
            [self failStartup:[NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil]
                   completion:completionHandler];
            return;
        }
        dispatch_source_set_timer(self.timer, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 10);
        __weak typeof(self) weakSelf = self;
        NSString *session = self.session;
        dispatch_source_set_event_handler(self.timer, ^{
            NSFilterControlProvider *owner = weakSelf;
            if (!owner) {
                return;
            }
            if ([owner.session isEqual:session]) {
                [owner refresh];
            }
        });
        dispatch_resume(self.timer);
        self.startupCompletion = completionHandler;
        [self publishInitialSnapshot:0 session:session];
    });
}
- (void)handleReport:(NEFilterReport *)report {
    // Capture OS metadata before queueing; no later callback retains the flow.
    NEFilterFlow *flow = report.flow;
    NSString *identity = flow.sourceAppIdentifier ?: @"";
    if (identity.length > NSMaximumIdentityLength) {
        identity = @"";
    }
    NSDictionary *event = @{
        @"time" : NSDate.date,
        @"identity" : identity,
        @"flow" : flow.identifier.UUIDString ?: @"",
        @"destination" : NSDestinationForFlow(flow),
        @"action" : report.action == NEFilterActionAllow
            ? @"allow"
            : (report.action == NEFilterActionDrop ? @"block" : @"other"),
        @"direction" : flow && flow.direction == NETrafficDirectionInbound
            ? @"inbound"
            : (flow && flow.direction == NETrafficDirectionOutbound ? @"outbound" : @"unknown"),
        @"event" : @(report.event),
        @"bytesIn" : @(report.bytesInboundCount),
        @"bytesOut" : @(report.bytesOutboundCount)
    };
    [self.work submit:^{
        if (self.stopped) {
            return;
        }
        self.lastReport = event[@"time"];
        [self appendEvent:event];
    }];
}
- (void)handleNewFlow:(NEFilterFlow *)flow
    completionHandler:(void (^)(NEFilterControlVerdict *))completionHandler {
    NSProviderReply *reply = [self.replies admit:^(id verdict) {
        completionHandler(verdict);
    }];
    if (!reply) {
        completionHandler([NEFilterControlVerdict dropVerdictWithUpdateRules:NO]);
        return;
    }
    NSString *identity = [flow.sourceAppIdentifier copy] ?: @"";
    NSDictionary *destination = [NSDestinationForFlow(flow) copy];
    NSString *flowID = flow.identifier.UUIDString ?: @"";
    NSFlowDirection direction = flow.direction == NETrafficDirectionInbound
                                    ? NSFlowDirectionInbound
                                    : (flow.direction == NETrafficDirectionOutbound ? NSFlowDirectionOutbound
                                                                                    : NSFlowDirectionUnknown);
    BOOL admitted = [self.work submit:^{
        NSPolicy *policy = NSReadPolicy(NULL);
        if (self.stopped || !policy) {
            [reply complete:[NEFilterControlVerdict dropVerdictWithUpdateRules:NO]];
            return;
        }
        if (![policy requiresPermissionForIdentity:identity direction:direction destination:destination]) {
            [reply complete:[NEFilterControlVerdict updateRules]];
            return;
        }
        [self.permissions resolveWithPolicy:policy now:NSProcessInfo.processInfo.systemUptime];
        self.lastReport = NSDate.date;
        NSString *session = self.session;
        __weak typeof(self) weakSelf = self;
        [self.permissions
            enqueueIdentity:identity
                  direction:direction
                destination:destination
                        now:NSProcessInfo.processInfo.systemUptime
                       date:NSDate.date
                 completion:^(BOOL allow) {
                     NSFilterControlProvider *owner = weakSelf;
                     // PermissionQueue invokes on the state queue after detaching its waiters.
                     if (owner && !owner.stopped && [owner.session isEqual:session]) {
                         [owner appendEvent:@{
                             @"time" : NSDate.date,
                             @"identity" : identity,
                             @"flow" : flowID,
                             @"destination" : destination,
                             @"action" : allow ? @"permission-allow" : @"permission-block",
                             @"direction" : direction == NSFlowDirectionInbound
                                 ? @"inbound"
                                 : (direction == NSFlowDirectionOutbound ? @"outbound" : @"unknown"),
                             @"event" : @0,
                             @"bytesIn" : @0,
                             @"bytesOut" : @0
                         }];
                     }
                     // The delivery queue outlives this session until shutdown's barrier.
                     [reply complete:allow ? [NEFilterControlVerdict updateRules]
                                           : [NEFilterControlVerdict dropVerdictWithUpdateRules:NO]];
                 }];
        [self scheduleRefresh];
    }];
    if (!admitted) {
        [reply complete:[NEFilterControlVerdict dropVerdictWithUpdateRules:NO]];
    }
}
- (void)publishStopped:(NSUInteger)attempt {
    NSError *error = nil;
    BOOL published = NSWriteMonitorSnapshot([self snapshotWithRunning:NO policyError:nil], &error);
    BOOL busy =
        [error.domain isEqual:NSPOSIXErrorDomain] && (error.code == EAGAIN || error.code == EWOULDBLOCK);
    if (!published && busy && attempt < 3) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC * 100), self.work.queue, ^{
            [self publishStopped:attempt + 1];
        });
        return;
    }
    if (!published) {
        NSLog(@"NetShield2: final control telemetry publication failed (%@/%ld)", error.domain,
              (long)error.code);
    }
    // DNS references and old state writers are quiescent. Detached OS
    // completions have no storage access, so a stalled external callback
    // cannot hold the provider lifetime lock or the shutdown acknowledgement.
    [self.providerLock unlock];
    self.providerLock = nil;
    self.lifecycle = 0;
    NSArray *completions = [self.stopCompletions copy];
    [self.stopCompletions removeAllObjects];
    self.permissions = nil;
    self.resolver = nil;
    self.notifications = nil;
    for (void (^completion)(void) in completions) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), completion);
    }
}
- (void)stopFilterWithReason:(NEProviderStopReason)reason
           completionHandler:(void (^)(void))completionHandler {
    dispatch_async(self.work.queue, ^{
        if (self.lifecycle == 0) {
            [self deliver:completionHandler];
            return;
        }
        [self.stopCompletions addObject:[completionHandler copy]];
        if (self.lifecycle == 3) {
            return;
        }
        if (self.lifecycle == 1) {
            void (^startup)(NSError *) = self.startupCompletion;
            self.startupCompletion = nil;
            [self failStartup:[NSError errorWithDomain:NSPOSIXErrorDomain code:ECANCELED userInfo:nil]
                   completion:startup];
            return;
        }
        self.lifecycle = 3;
        self.stopped = YES;
        [self.permissions cancelAll];
        [self.notifications stop];
        if (self.timer) {
            dispatch_source_cancel(self.timer);
            self.timer = nil;
        }
        [self.resolver stopWithCompletion:^{
            dispatch_async(self.work.queue, ^{
                [self publishStopped:0];
            });
        }];
    });
}
@end
