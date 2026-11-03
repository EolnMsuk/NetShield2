#import <NetworkExtension/NetworkExtension.h>
#import "../Shared/NSPolicyReader.h"
#import "../Shared/NSFlowDestination.h"

@interface NSFilterDataProvider : NEFilterDataProvider
@end

@implementation NSFilterDataProvider
- (NSFlowDirection)directionForFlow:(NEFilterFlow *)flow {
    return flow && flow.direction == NETrafficDirectionInbound    ? NSFlowDirectionInbound
           : flow && flow.direction == NETrafficDirectionOutbound ? NSFlowDirectionOutbound
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
    NSFlowEvaluation evaluation =
        policy ? [policy evaluateIdentity:flow.sourceAppIdentifier
                                direction:[self directionForFlow:flow]
                              destination:destination
                                   socket:[flow isKindOfClass:NEFilterSocketFlow.class]]
               : (NSFlowEvaluation){NSFlowDrop, NSFlowReasonPolicy};
    if (evaluation.disposition == NSFlowNeedsEndpoints) {
        return [NEFilterNewFlowVerdict filterDataVerdictWithFilterInbound:YES
                                                         peekInboundBytes:1
                                                           filterOutbound:YES
                                                        peekOutboundBytes:1];
    }
    if (evaluation.disposition == NSFlowAsk) {
        return [NEFilterNewFlowVerdict needRulesVerdict];
    }
    BOOL allow = evaluation.disposition == NSFlowAllow;
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
    NSFlowEvaluation evaluation = policy ? [policy evaluateIdentity:flow.sourceAppIdentifier
                                                          direction:[self directionForFlow:flow]
                                                        destination:destination
                                                             socket:YES]
                                         : (NSFlowEvaluation){NSFlowDrop, NSFlowReasonPolicy};
    if (evaluation.disposition == NSFlowAsk) {
        return [NEFilterDataVerdict needRulesVerdict];
    }
    // A deferred callback with still-missing endpoints terminates by dropping;
    // it cannot start an unbounded peek/need-rules loop.
    BOOL allow = evaluation.disposition == NSFlowAllow;
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
