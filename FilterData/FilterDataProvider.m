#import <NetworkExtension/NetworkExtension.h>
#import "../Shared/NSStore.h"
#import "../Shared/NSFlowDestination.h"

@interface NSFilterDataProvider : NEFilterDataProvider
@end

@implementation NSFilterDataProvider
- (NSFlowDirection)directionForFlow:(NEFilterFlow *)flow {
    return flow.direction == NETrafficDirectionInbound    ? NSFlowDirectionInbound
           : flow.direction == NETrafficDirectionOutbound ? NSFlowDirectionOutbound
                                                          : NSFlowDirectionUnknown;
}
- (void)startFilterWithCompletionHandler:(void (^)(NSError *))completionHandler {
    NSError *error = nil;
    NSReadPolicy(&error);
    completionHandler(error);
}
- (NEFilterNewFlowVerdict *)handleNewFlow:(NEFilterFlow *)flow {
    NSPolicy *policy = NSReadPolicy(NULL);
    NSDictionary *destination = NSDestinationForFlow(flow);
    if ([flow isKindOfClass:NEFilterSocketFlow.class] && [policy needsSocketDestination:destination]) {
        return [NEFilterNewFlowVerdict filterDataVerdictWithFilterInbound:YES
                                                         peekInboundBytes:1
                                                           filterOutbound:YES
                                                        peekOutboundBytes:1];
    }
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
- (NEFilterDataVerdict *)verdictForDeferredFlow:(NEFilterFlow *)flow {
    NSPolicy *policy = NSReadPolicy(NULL);
    NSDictionary *destination = NSDestinationForFlow(flow);
    if (!policy || [policy needsSocketDestination:destination]) {
        NEFilterDataVerdict *verdict = [NEFilterDataVerdict dropVerdict];
        verdict.shouldReport = YES;
        return verdict;
    }
    if ([policy requiresPermissionForIdentity:flow.sourceAppIdentifier destination:destination]) {
        return [NEFilterDataVerdict needRulesVerdict];
    }
    BOOL allow = [policy allowsIdentity:flow.sourceAppIdentifier
                              direction:[self directionForFlow:flow]
                            destination:destination];
    NEFilterDataVerdict *verdict =
        allow ? [NEFilterDataVerdict allowVerdict] : [NEFilterDataVerdict dropVerdict];
    verdict.shouldReport = YES;
    return verdict;
}
- (NEFilterDataVerdict *)handleInboundDataFromFlow:(NEFilterFlow *)flow
                              readBytesStartOffset:(NSUInteger)offset
                                         readBytes:(NSData *)bytes {
    return [self verdictForDeferredFlow:flow];
}
- (NEFilterDataVerdict *)handleOutboundDataFromFlow:(NEFilterFlow *)flow
                               readBytesStartOffset:(NSUInteger)offset
                                          readBytes:(NSData *)bytes {
    return [self verdictForDeferredFlow:flow];
}
- (NEFilterDataVerdict *)handleInboundDataCompleteForFlow:(NEFilterFlow *)flow {
    return [self verdictForDeferredFlow:flow];
}
- (NEFilterDataVerdict *)handleOutboundDataCompleteForFlow:(NEFilterFlow *)flow {
    return [self verdictForDeferredFlow:flow];
}
- (void)stopFilterWithReason:(NEProviderStopReason)reason
           completionHandler:(void (^)(void))completionHandler {
    completionHandler();
}
@end
