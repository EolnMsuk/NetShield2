#import <NetworkExtension/NetworkExtension.h>
#import "../Shared/NSStore.h"

@interface NSFilterDataProvider : NEFilterDataProvider
@end

@implementation NSFilterDataProvider
- (void)startFilterWithCompletionHandler:(void (^)(NSError *))completionHandler {
    // Do not export data or open IPC/network channels from this sandbox.
    NSError *error = nil;
    NSReadPolicy(&error);
    completionHandler(error);
}
- (NEFilterNewFlowVerdict *)handleNewFlow:(NEFilterFlow *)flow {
    // Read an atomic snapshot at admission. A missing/corrupt policy blocks the
    // flow; an old cached allow policy must not silently survive a broken update.
    NSPolicy *policy = NSReadPolicy(NULL);
    if ([policy requiresPermissionForIdentity:flow.sourceAppIdentifier]) {
        return [NEFilterNewFlowVerdict needRulesVerdict];
    }
    NSFlowDirection direction = NSFlowDirectionUnknown;
    if (flow.direction == NETrafficDirectionInbound) direction = NSFlowDirectionInbound;
    if (flow.direction == NETrafficDirectionOutbound) direction = NSFlowDirectionOutbound;
    BOOL allow = policy && [policy allowsIdentity:flow.sourceAppIdentifier direction:direction];
    NEFilterNewFlowVerdict *verdict = allow ? [NEFilterNewFlowVerdict allowVerdict] : [NEFilterNewFlowVerdict dropVerdict];
    verdict.shouldReport = YES;
    return verdict;
}
- (void)handleRulesChanged {
    // Every new flow reads the latest policy. Already admitted flows retain
    // their verdict: iOS has no public updateFlow:usingVerdict:forDirection: API.
}
- (void)stopFilterWithReason:(NEProviderStopReason)reason completionHandler:(void (^)(void))completionHandler {
    completionHandler();
}
@end
