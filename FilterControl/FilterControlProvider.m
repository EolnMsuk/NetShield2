#import <NetworkExtension/NetworkExtension.h>
#import "../Shared/NSStore.h"
#import "../Shared/NSPermissionQueue.h"
#import "../Shared/NSNotifications.h"

@interface NSFilterControlProvider : NEFilterControlProvider
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *events;
@property(nonatomic, copy) NSString *revision;
@property(nonatomic, copy) NSString *session;
@property(nonatomic, strong) NSDate *lastReport;
@property(nonatomic) BOOL stopped;
@property(nonatomic, strong) NSPermissionQueue *permissions;
@property(nonatomic, copy) NSString *notificationError;
@end

@implementation NSFilterControlProvider
- (NSDictionary *)snapshotWithRunning:(BOOL)running policyError:(NSError *)error {
    return @{@"schema": @2, @"controlRunning": @(running), @"session": self.session ?: @"",
             @"updated": NSDate.date, @"lastReport": self.lastReport ?: [NSDate dateWithTimeIntervalSince1970:0],
             @"revision": self.revision ?: @"", @"policyError": error.localizedDescription ?: @"",
             @"events": [self.events copy] ?: @[], @"requests": self.permissions.requests ?: @[],
             @"notificationError": self.notificationError ?: @""};
}
- (void)refresh {
    @synchronized(self) {
        if (self.stopped) return;
        NSError *error = nil;
        NSPolicy *policy = NSReadPolicy(&error);
        NSArray *before = self.permissions.requests;
        [self.permissions resolveWithPolicy:policy now:NSProcessInfo.processInfo.systemUptime];
        NSSet *remaining = [NSSet setWithArray:[self.permissions.requests valueForKey:@"token"]];
        NSMutableArray *removed = [NSMutableArray new];
        for (NSDictionary *request in before) {
            if (![remaining containsObject:request[@"token"]]) [removed addObject:request[@"token"]];
        }
        if (removed.count) {
            [UNUserNotificationCenter.currentNotificationCenter removePendingNotificationRequestsWithIdentifiers:removed];
            [UNUserNotificationCenter.currentNotificationCenter removeDeliveredNotificationsWithIdentifiers:removed];
        }
        NSString *revision = policy.document[@"revision"];
        if (![self.revision isEqual:revision]) {
            self.revision = revision;
            [self notifyRulesChanged];
        }
        NSError *writeError = nil;
        if (!NSWriteDocument([self snapshotWithRunning:YES policyError:error], @"monitor.plist", &writeError)) {
            // Metadata only. No destinations, payloads, URLs or app identities in system logs.
            NSLog(@"NetShield monitor storage failed: %@", writeError.localizedDescription);
        }
    }
}
- (void)startFilterWithCompletionHandler:(void (^)(NSError *))completionHandler {
    NSError *error = nil;
    if (!NSReadPolicy(&error)) { completionHandler(error); return; }
    self.events = [NSMutableArray new];
    self.lastReport = nil;
    self.revision = nil;
    self.permissions = [NSPermissionQueue new];
    self.notificationError = @"";
    NSRegisterPermissionActions();
    self.session = NSUUID.UUID.UUIDString;
    self.stopped = NO;
    if (!NSWriteDocument([self snapshotWithRunning:YES policyError:nil], @"monitor.plist", &error)) {
        completionHandler(error);
        return;
    }
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(self.timer, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 10);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.timer, ^{ [weakSelf refresh]; });
    dispatch_resume(self.timer);
    completionHandler(nil);
}
- (void)handleReport:(NEFilterReport *)report {
    @synchronized(self) {
        if (self.stopped) return;
        self.lastReport = NSDate.date;
        NEFilterFlow *flow = report.flow;
        NSString *action = @"other";
        if (report.action == NEFilterActionAllow) action = @"allow";
        if (report.action == NEFilterActionDrop) action = @"block";
        NSString *direction = @"unknown";
        if (flow && flow.direction == NETrafficDirectionInbound) direction = @"inbound";
        if (flow && flow.direction == NETrafficDirectionOutbound) direction = @"outbound";
        // Identity is exactly the OS-supplied sourceAppIdentifier, including any
        // signing prefix. Empty is explicitly unattributed, never a guessed app.
        NSString *identity = flow.sourceAppIdentifier ?: @"";
        if (identity.length > 1024) identity = @"";
        [self.events addObject:@{@"time": self.lastReport, @"identity": identity,
            @"flow": flow.identifier.UUIDString ?: @"", @"action": action,
            @"direction": direction, @"event": @(report.event),
            @"bytesIn": @(report.bytesInboundCount), @"bytesOut": @(report.bytesOutboundCount)}];
        if (self.events.count > 300) [self.events removeObjectsInRange:NSMakeRange(0, self.events.count - 300)];
    }
}
- (void)handleNewFlow:(NEFilterFlow *)flow completionHandler:(void (^)(NEFilterControlVerdict *))completionHandler {
    @synchronized(self) {
        NSPolicy *policy = NSReadPolicy(NULL);
        NSFlowDirection direction = NSFlowDirectionUnknown;
        if (flow.direction == NETrafficDirectionInbound) direction = NSFlowDirectionInbound;
        if (flow.direction == NETrafficDirectionOutbound) direction = NSFlowDirectionOutbound;
        NSString *identity = flow.sourceAppIdentifier ?: @"";
        if (self.stopped || !policy) {
            completionHandler([NEFilterControlVerdict dropVerdictWithUpdateRules:NO]);
            return;
        }
        if (![policy requiresPermissionForIdentity:identity]) {
            completionHandler([NEFilterControlVerdict updateRules]);
            return;
        }
        // Receiving this request itself demonstrates a live data-provider callback.
        self.lastReport = NSDate.date;
        __weak typeof(self) weakSelf = self;
        NSDictionary *request = [self.permissions enqueueIdentity:identity direction:direction
            now:NSProcessInfo.processInfo.systemUptime date:NSDate.date completion:^(BOOL allow) {
                // For allowed flows, send the data provider back through its latest
                // policy so shouldReport is applied there. Timeouts always drop.
                completionHandler(allow ? [NEFilterControlVerdict updateRules] : [NEFilterControlVerdict dropVerdictWithUpdateRules:NO]);
                NSFilterControlProvider *owner = weakSelf;
                if (!owner) return;
                @synchronized(owner) {
                    [owner.events addObject:@{@"time": NSDate.date, @"identity": identity,
                        @"flow": flow.identifier.UUIDString ?: @"", @"action": allow ? @"permission-allow" : @"permission-block",
                        @"direction": direction == NSFlowDirectionInbound ? @"inbound" : (direction == NSFlowDirectionOutbound ? @"outbound" : @"unknown"),
                        @"event": @0, @"bytesIn": @0, @"bytesOut": @0}];
                    if (owner.events.count > 300) [owner.events removeObjectsInRange:NSMakeRange(0, owner.events.count - 300)];
                }
            }];
        [self refresh];
        if (!request) return; // Already queued, timed out, or over capacity.
        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.title = @"Network access requested";
        content.body = [NSString stringWithFormat:@"%@ wants to connect. Allow or block this app in NetShield. Unanswered connections are blocked after 30 seconds.", identity];
        content.categoryIdentifier = NSPermissionCategory;
        content.sound = UNNotificationSound.defaultSound;
        content.userInfo = @{@"token": request[@"token"], @"identity": identity};
        UNNotificationRequest *notification = [UNNotificationRequest requestWithIdentifier:request[@"token"] content:content trigger:nil];
        [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:notification withCompletionHandler:^(NSError *error) {
            NSFilterControlProvider *owner = weakSelf;
            if (!owner) return;
            @synchronized(owner) {
                if (!owner.stopped) owner.notificationError = error ?
                    [NSString stringWithFormat:@"Notifications unavailable (%@ %ld). Open NetShield to answer requests.", error.domain, (long)error.code] : @"";
            }
        }];
    }
}
- (void)stopFilterWithReason:(NEProviderStopReason)reason completionHandler:(void (^)(void))completionHandler {
    @synchronized(self) {
        self.stopped = YES;
        NSArray *tokens = [self.permissions.requests valueForKey:@"token"];
        [self.permissions cancelAll];
        [UNUserNotificationCenter.currentNotificationCenter removePendingNotificationRequestsWithIdentifiers:tokens];
        [UNUserNotificationCenter.currentNotificationCenter removeDeliveredNotificationsWithIdentifiers:tokens];
        if (self.timer) { dispatch_source_cancel(self.timer); self.timer = nil; }
        NSWriteDocument([self snapshotWithRunning:NO policyError:nil], @"monitor.plist", NULL);
    }
    completionHandler();
}
@end
