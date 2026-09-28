#import <NetworkExtension/NetworkExtension.h>
#import "../Shared/NSStore.h"
#import "../Shared/NSPermissionQueue.h"
#import "../Shared/NSNotifications.h"
#import "../Shared/NSNotificationPolicy.h"

@interface NSFilterControlProvider : NEFilterControlProvider
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *events;
@property(nonatomic, copy) NSString *revision;
@property(nonatomic, copy) NSString *session;
@property(nonatomic, strong) NSDate *lastReport;
@property(nonatomic) BOOL stopped;
@property(nonatomic, strong) NSPermissionQueue *permissions;
@property(nonatomic, copy) NSString *notificationError;
@property(nonatomic, copy) NSString *notificationRetry;
@property(nonatomic, copy) NSString *notificationDeliveryIssue;
@property(nonatomic, strong) NSMutableSet<NSString *> *submittedNotifications;
@property(nonatomic, strong) NSMutableSet<NSString *> *submittingNotifications;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *notificationAttempts;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *notificationAttemptTimes;
@end

@implementation NSFilterControlProvider
- (NSDictionary *)snapshotWithRunning:(BOOL)running policyError:(NSError *)error {
    return @{@"engine": @20013, @"schema": @2, @"controlRunning": @(running), @"session": self.session ?: @"",
             @"updated": NSDate.date, @"lastReport": self.lastReport ?: [NSDate dateWithTimeIntervalSince1970:0],
             @"revision": self.revision ?: @"", @"policyError": error.localizedDescription ?: @"",
             @"events": [self.events copy] ?: @[], @"requests": self.permissions.requests ?: @[],
             @"notificationError": self.notificationError ?: @"",
             @"notificationDeliveryIssue": self.notificationDeliveryIssue ?: @""};
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
        for (NSString *token in removed) {
            [self.submittedNotifications removeObject:token];
            [self.notificationAttempts removeObjectForKey:token];
            [self.notificationAttemptTimes removeObjectForKey:token];
        }
        if (removed.count) {
            [UNUserNotificationCenter.currentNotificationCenter removePendingNotificationRequestsWithIdentifiers:removed];
            [UNUserNotificationCenter.currentNotificationCenter removeDeliveredNotificationsWithIdentifiers:removed];
        }
        NSString *retry = NSReadDocument(@"notification-retry.plist", NULL)[@"revision"];
        if ([retry isKindOfClass:NSString.class] && ![retry isEqual:self.notificationRetry]) {
            self.notificationRetry = retry;
            [self.submittedNotifications removeAllObjects];
            [self.notificationAttempts removeAllObjects];
            [self.notificationAttemptTimes removeAllObjects];
        }
        // Submission failures do not get another enqueue callback for this
        // identity. Retry at most three times, with five seconds between attempts.
        // Returning from notification settings starts a fresh retry budget.
        for (NSDictionary *request in self.permissions.requests) [self sendNotification:request];
        NSString *revision = policy.document[@"revision"];
        if (![self.revision isEqual:revision]) {
            self.revision = revision;
            NSRemoveAutomaticallyAllowedNotifications();
            [self notifyRulesChanged];
        }
        NSError *writeError = nil;
        if (!NSWriteDocument([self snapshotWithRunning:YES policyError:error], @"monitor.plist", &writeError)) {
            // Metadata only. No destinations, payloads, URLs or app identities in system logs.
            NSLog(@"NetShield2 monitor storage failed: %@", writeError.localizedDescription);
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
    self.notificationDeliveryIssue = @"";
    self.submittedNotifications = [NSMutableSet new];
    self.submittingNotifications = [NSMutableSet new];
    self.notificationAttempts = [NSMutableDictionary new];
    self.notificationAttemptTimes = [NSMutableDictionary new];
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
        // refresh submits each queued identity once, including transient retries.
        (void)request;
    }
}
- (void)sendNotification:(NSDictionary *)request {
    NSString *identity = request[@"identity"];
    // A policy edit can resolve a just-enqueued request during refresh, before
    // this method is reached. Never publish that stale notification.
    NSPolicy *current = NSReadPolicy(NULL);
    if (self.stopped || ![current requiresPermissionForIdentity:identity] ||
        ![[self.permissions.requests valueForKey:@"token"] containsObject:request[@"token"]]) return;
    NSString *token = request[@"token"];
    NSUInteger attempts = [self.notificationAttempts[token] unsignedIntegerValue];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if ([self.submittedNotifications containsObject:token] || [self.submittingNotifications containsObject:token] ||
        attempts >= 3 || (attempts && now - [self.notificationAttemptTimes[token] doubleValue] < 5)) return;
    self.notificationAttempts[token] = @(attempts + 1);
    self.notificationAttemptTimes[token] = @(now);
    [self.submittingNotifications addObject:token];
    __weak typeof(self) weakSelf = self;
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = @"Network access requested";
    content.body = [NSString stringWithFormat:@"%@ wants to connect. Long-press this banner for Allow app or Keep blocking. Unanswered connections are blocked after 30 seconds.", identity];
    content.categoryIdentifier = NSPermissionCategory;
    content.sound = UNNotificationSound.defaultSound;
    content.userInfo = @{@"token": request[@"token"], @"identity": identity};
    UNNotificationRequest *notification = [UNNotificationRequest requestWithIdentifier:request[@"token"] content:content trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:notification withCompletionHandler:^(NSError *error) {
        NSFilterControlProvider *provider = weakSelf;
        if (provider) {
            @synchronized(provider) {
                [provider.submittingNotifications removeObject:token];
                if (!error && !provider.stopped && [[provider.permissions.requests valueForKey:@"token"] containsObject:token])
                    [provider.submittedNotifications addObject:token];
                if (!provider.stopped) provider.notificationDeliveryIssue = error
                    ? [NSString stringWithFormat:@"Notification delivery failed: %@. Reopen notification settings, then return to retry.", error.localizedDescription] : @"";
                // Submission is asynchronous. Only a known policy decision may
                // withdraw it; a failed read or missing queue entry proves nothing.
                if (provider.stopped || NSShouldWithdrawPermissionNotification(NSReadPolicy(NULL), identity)) {
                    [UNUserNotificationCenter.currentNotificationCenter removePendingNotificationRequestsWithIdentifiers:@[request[@"token"]]];
                    [UNUserNotificationCenter.currentNotificationCenter removeDeliveredNotificationsWithIdentifiers:@[request[@"token"]]];
                }
            }
        }
        [UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
            NSFilterControlProvider *owner = weakSelf;
            if (!owner) return;
            @synchronized(owner) {
                if (!owner.stopped && !error && (settings.authorizationStatus == UNAuthorizationStatusDenied ||
                    settings.authorizationStatus == UNAuthorizationStatusNotDetermined || settings.alertSetting == UNNotificationSettingDisabled)) {
                    owner.notificationDeliveryIssue = @"iOS is not allowing alerts from the filter provider. Enable Allow Notifications and Banners in Notification settings, then return to retry.";
                }
                if (!owner.stopped) owner.notificationError = [NSString stringWithFormat:@"Provider notification at %@: %@. Provider authorization=%ld, alerts=%ld (2=enabled). Banner display is not confirmed.", NSDate.date,
                    error ? [NSString stringWithFormat:@"%@ (%@ %ld)", error.localizedDescription, error.domain, (long)error.code] : @"submission accepted",
                    (long)settings.authorizationStatus, (long)settings.alertSetting];
            }
        }];
    }];
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
