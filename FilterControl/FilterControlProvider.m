#import <NetworkExtension/NetworkExtension.h>
#import "../Shared/NSStore.h"
#import "../Shared/NSPermissionQueue.h"
#import "NSPermissionNotifications.h"
#import "../Shared/NSDestination.h"
#import "../Shared/NSFlowDestination.h"

@interface NSFilterControlProvider : NEFilterControlProvider
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *events;
@property(nonatomic, copy) NSString *revision;
@property(nonatomic, copy) NSString *session;
@property(nonatomic, strong) NSDate *lastReport;
@property(nonatomic) BOOL stopped;
@property(nonatomic) BOOL refreshScheduled;
@property(nonatomic, strong) NSPermissionQueue *permissions;
@property(nonatomic, strong) NSPermissionNotifications *notifications;
@property(nonatomic, strong) NSStoreLock *providerLock;
@end

@implementation NSFilterControlProvider
- (NSDictionary *)snapshotWithRunning:(BOOL)running policyError:(NSError *)error {
    return @{
        @"engine" : @(NSEngineVersion),
        @"schema" : @(NSSchemaVersion),
        @"controlRunning" : @(running),
        @"session" : self.session ?: @"",
        @"updated" : NSDate.date,
        @"lastReport" : self.lastReport ?: [NSDate dateWithTimeIntervalSince1970:0],
        @"revision" : self.revision ?: @"",
        @"policyError" : error.localizedDescription ?: @"",
        @"events" : [self.events copy] ?: @[],
        @"requests" : self.permissions.requests ?: @[],
        @"notificationDeliveryIssue" : self.notifications.deliveryIssue ?: @"",
        @"overflowCount" : @(self.permissions.overflowCount),
        @"evictedRequestCount" : @(self.permissions.evictedRequestCount)
    };
}
- (void)refresh {
    @synchronized(self) {
        if (self.stopped) {
            return;
        }
        NSError *error = nil;
        NSPolicy *policy = NSReadPolicy(&error);
        [self.permissions resolveWithPolicy:policy now:NSProcessInfo.processInfo.systemUptime];
        NSString *retry = NSReadDocument(NSNotificationRetryFile, NULL)[@"revision"];
        if (![retry isKindOfClass:NSString.class]) {
            retry = nil;
        }
        NSString *revision = policy.document[@"revision"];
        if ((self.revision || revision) && ![self.revision isEqual:revision]) {
            self.revision = revision;
            [self notifyRulesChanged];
        }
        NSWriteDocument([self snapshotWithRunning:YES policyError:error], NSMonitorFile, NULL);
        [self.notifications updateRequests:self.permissions.requests policy:policy retryRevision:retry];
    }
}
- (void)scheduleRefresh {
    if (self.refreshScheduled || self.stopped) {
        return;
    }
    self.refreshScheduled = YES;
    NSString *session = self.session;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                       NSFilterControlProvider *owner = weakSelf;
                       if (!owner) {
                           return;
                       }
                       @synchronized(owner) {
                           if (![owner.session isEqual:session] || owner.stopped) {
                               return;
                           }
                           owner.refreshScheduled = NO;
                           [owner refresh];
                       }
                   });
}
- (void)startFilterWithCompletionHandler:(void (^)(NSError *))completionHandler {
    NSError *error = nil;
    @synchronized(self) {
        self.stopped = YES;
        self.providerLock = NSAcquireProviderLock(&error);
        if (!self.providerLock) {
            completionHandler(error);
            return;
        }
        if (!NSReadPolicy(&error)) {
            [self.providerLock unlock];
            self.providerLock = nil;
            completionHandler(error);
            return;
        }
        self.events = [NSMutableArray new];
        self.lastReport = nil;
        self.revision = nil;
        self.permissions = [NSPermissionQueue new];
        self.notifications = [NSPermissionNotifications new];
        self.session = NSUUID.UUID.UUIDString;
        self.refreshScheduled = NO;
        self.stopped = NO;
        if (!NSWriteDocument([self snapshotWithRunning:YES policyError:nil], NSMonitorFile, &error)) {
            self.stopped = YES;
            [self.notifications stop];
            [self.providerLock unlock];
            self.providerLock = nil;
            completionHandler(error);
            return;
        }
        self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(self.timer, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 10);
        __weak typeof(self) weakSelf = self;
        NSString *session = self.session;
        dispatch_source_set_event_handler(self.timer, ^{
            NSFilterControlProvider *owner = weakSelf;
            if (!owner) {
                return;
            }
            @synchronized(owner) {
                if ([owner.session isEqual:session]) {
                    [owner refresh];
                }
            }
        });
        dispatch_resume(self.timer);
    }
    completionHandler(nil);
}
- (void)handleReport:(NEFilterReport *)report {
    @synchronized(self) {
        if (self.stopped) {
            return;
        }
        self.lastReport = NSDate.date;
        NEFilterFlow *flow = report.flow;
        NSString *action = @"other";
        if (report.action == NEFilterActionAllow) {
            action = @"allow";
        }
        if (report.action == NEFilterActionDrop) {
            action = @"block";
        }
        NSString *direction = @"unknown";
        if (flow && flow.direction == NETrafficDirectionInbound) {
            direction = @"inbound";
        }
        if (flow && flow.direction == NETrafficDirectionOutbound) {
            direction = @"outbound";
        }
        NSString *identity = flow.sourceAppIdentifier ?: @"";
        if (identity.length > NSMaximumIdentityLength) {
            identity = @"";
        }
        [self.events addObject:@{
            @"time" : self.lastReport,
            @"identity" : identity,
            @"flow" : flow.identifier.UUIDString ?: @"",
            @"destination" : NSDestinationForFlow(flow),
            @"action" : action,
            @"direction" : direction,
            @"event" : @(report.event),
            @"bytesIn" : @(report.bytesInboundCount),
            @"bytesOut" : @(report.bytesOutboundCount)
        }];
        if (self.events.count > NSMaximumEvents) {
            [self.events removeObjectsInRange:NSMakeRange(0, self.events.count - NSMaximumEvents)];
        }
    }
}
- (void)handleNewFlow:(NEFilterFlow *)flow
    completionHandler:(void (^)(NEFilterControlVerdict *))completionHandler {
    @synchronized(self) {
        NSPolicy *policy = NSReadPolicy(NULL);
        NSFlowDirection direction = NSFlowDirectionUnknown;
        if (flow.direction == NETrafficDirectionInbound) {
            direction = NSFlowDirectionInbound;
        }
        if (flow.direction == NETrafficDirectionOutbound) {
            direction = NSFlowDirectionOutbound;
        }
        NSString *identity = flow.sourceAppIdentifier ?: @"";
        if (self.stopped || !policy) {
            completionHandler([NEFilterControlVerdict dropVerdictWithUpdateRules:NO]);
            return;
        }
        if (![policy requiresPermissionForIdentity:identity destination:NSDestinationForFlow(flow)]) {
            completionHandler([NEFilterControlVerdict updateRules]);
            return;
        }
        self.lastReport = NSDate.date;
        __weak typeof(self) weakSelf = self;
        [self.permissions
            enqueueIdentity:identity
                  direction:direction
                destination:NSDestinationForFlow(flow)
                        now:NSProcessInfo.processInfo.systemUptime
                       date:NSDate.date
                 completion:^(BOOL allow) {
                     completionHandler(allow ? [NEFilterControlVerdict updateRules]
                                             : [NEFilterControlVerdict dropVerdictWithUpdateRules:NO]);
                     NSFilterControlProvider *owner = weakSelf;
                     if (!owner) {
                         return;
                     }
                     @synchronized(owner) {
                         [owner.events addObject:@{
                             @"time" : NSDate.date,
                             @"identity" : identity,
                             @"flow" : flow.identifier.UUIDString ?: @"",
                             @"destination" : NSDestinationForFlow(flow),
                             @"action" : allow ? @"permission-allow" : @"permission-block",
                             @"direction" : direction == NSFlowDirectionInbound
                                 ? @"inbound"
                                 : (direction == NSFlowDirectionOutbound ? @"outbound" : @"unknown"),
                             @"event" : @0,
                             @"bytesIn" : @0,
                             @"bytesOut" : @0
                         }];
                         if (owner.events.count > NSMaximumEvents) {
                             [owner.events
                                 removeObjectsInRange:NSMakeRange(0, owner.events.count - NSMaximumEvents)];
                         }
                     }
                 }];
        [self scheduleRefresh];
    }
}
- (void)stopFilterWithReason:(NEProviderStopReason)reason
           completionHandler:(void (^)(void))completionHandler {
    @synchronized(self) {
        self.stopped = YES;
        [self.permissions cancelAll];
        [self.notifications stop];
        if (self.timer) {
            dispatch_source_cancel(self.timer);
            self.timer = nil;
        }
        if (self.providerLock) {
            NSWriteDocument([self snapshotWithRunning:NO policyError:nil], NSMonitorFile, NULL);
            [self.providerLock unlock];
            self.providerLock = nil;
        }
    }
    completionHandler();
}
@end
