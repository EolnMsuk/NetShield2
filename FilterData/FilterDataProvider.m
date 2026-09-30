#import <NetworkExtension/NetworkExtension.h>
#import "../Shared/NSStore.h"
#import "../Shared/NSFlowDestination.h"

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
    NSDictionary *destination = NSDestinationForFlow(flow);
    if ([policy requiresPermissionForIdentity:flow.sourceAppIdentifier destination:destination]) {
        return [NEFilterNewFlowVerdict needRulesVerdict];
    }
    NSFlowDirection direction = NSFlowDirectionUnknown;
    if (flow.direction == NETrafficDirectionInbound) {
        direction = NSFlowDirectionInbound;
    }
    if (flow.direction == NETrafficDirectionOutbound) {
        direction = NSFlowDirectionOutbound;
    }
    BOOL allow = policy && [policy allowsIdentity:flow.sourceAppIdentifier
                                        direction:direction
                                      destination:destination];
    NEFilterNewFlowVerdict *verdict =
        allow ? [NEFilterNewFlowVerdict allowVerdict] : [NEFilterNewFlowVerdict dropVerdict];
    verdict.shouldReport = YES;
    return verdict;
}
- (void)handleRulesChanged {
    NSInvalidatePolicyCache();
}
- (void)stopFilterWithReason:(NEProviderStopReason)reason
           completionHandler:(void (^)(void))completionHandler {
    completionHandler();
}
@end
