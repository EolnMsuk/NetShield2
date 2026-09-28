#import <NetworkExtension/NetworkExtension.h>
#import "../Shared/NSStore.h"

@interface NSFilterDataProvider : NEFilterDataProvider
@end

@implementation NSFilterDataProvider
- (void)startFilterWithCompletionHandler:(void (^)(NSError *))completionHandler {
    NSError *error = nil;
    NSReadPolicy(&error);
    completionHandler(error);
}
- (NEFilterNewFlowVerdict *)handleNewFlow:(NEFilterFlow *)flow {
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
}
- (void)stopFilterWithReason:(NEProviderStopReason)reason completionHandler:(void (^)(void))completionHandler {
    completionHandler();
}
@end
