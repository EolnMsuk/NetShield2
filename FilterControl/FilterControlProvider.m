#import <NetworkExtension/NetworkExtension.h>
#import "../Shared/NSStore.h"

@interface NSFilterControlProvider : NEFilterControlProvider
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *events;
@property(nonatomic, copy) NSString *revision;
@property(nonatomic, copy) NSString *session;
@property(nonatomic, strong) NSDate *lastReport;
@property(nonatomic) BOOL stopped;
@end

@implementation NSFilterControlProvider
- (NSDictionary *)snapshotWithRunning:(BOOL)running policyError:(NSError *)error {
    return @{@"schema": @2, @"controlRunning": @(running), @"session": self.session ?: @"",
             @"updated": NSDate.date, @"lastReport": self.lastReport ?: [NSDate dateWithTimeIntervalSince1970:0],
             @"revision": self.revision ?: @"", @"policyError": error.localizedDescription ?: @"",
             @"events": [self.events copy] ?: @[]};
}
- (void)refresh {
    @synchronized(self) {
        if (self.stopped) return;
        NSError *error = nil;
        NSPolicy *policy = NSReadPolicy(&error);
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
    self.session = NSUUID.UUID.UUIDString;
    self.stopped = NO;
    if (!NSWriteDocument([self snapshotWithRunning:YES policyError:nil], @"monitor.plist", &error)) {
        completionHandler(error);
        return;
    }
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(self.timer, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
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
    // The data provider never requests rules. Defensive response if invoked.
    completionHandler([NEFilterControlVerdict dropVerdictWithUpdateRules:NO]);
}
- (void)stopFilterWithReason:(NEProviderStopReason)reason completionHandler:(void (^)(void))completionHandler {
    @synchronized(self) {
        self.stopped = YES;
        if (self.timer) { dispatch_source_cancel(self.timer); self.timer = nil; }
        NSWriteDocument([self snapshotWithRunning:NO policyError:nil], @"monitor.plist", NULL);
    }
    completionHandler();
}
@end
