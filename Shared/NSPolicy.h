#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
static inline BOOL NSIsAppleSystemIdentity(NSString *_Nullable identity) {
    return [identity isKindOfClass:NSString.class] &&
           [identity rangeOfString:@"com.apple." options:NSLiteralSearch].location != NSNotFound;
}
static inline BOOL NSAppleSystemTrafficEnabled(NSDictionary *_Nullable document) {
    // Older schema-5 documents without a socket preference filter sockets.
    return (!document[@"filterSockets"] || [document[@"filterSockets"] boolValue]) &&
           [document[@"allowAppleSystemProcesses"] boolValue];
}
FOUNDATION_EXPORT NSArray<NSString *> *NSAppleSystemTelemetryIdentities(void);

typedef NS_ENUM(NSInteger, NSFlowDirection) {
    NSFlowDirectionUnknown = 0,
    NSFlowDirectionInbound = 1,
    NSFlowDirectionOutbound = 2,
};

static inline NSFlowDirection NSNormalizedFlowDirection(NSFlowDirection direction) {
    return direction == NSFlowDirectionInbound || direction == NSFlowDirectionOutbound
               ? direction
               : NSFlowDirectionUnknown;
}
typedef NS_ENUM(NSInteger, NSFlowDisposition) { NSFlowDrop, NSFlowAllow, NSFlowAsk, NSFlowNeedsEndpoints };
typedef NS_ENUM(NSInteger, NSFlowDecisionReason) {
    NSFlowReasonPolicy,
    NSFlowReasonGlobal,
    NSFlowReasonSystem,
    NSFlowReasonApp,
    NSFlowReasonDefault,
    NSFlowReasonUnidentified,
    NSFlowReasonEndpoints
};
typedef struct {
    NSFlowDisposition disposition;
    NSFlowDecisionReason reason;
} NSFlowEvaluation;

@interface NSPolicy : NSObject
@property(nonatomic, readonly, copy) NSDictionary *document;
@property(nonatomic, readonly, copy) NSDictionary *globalRuleConditions;
+ (NSDictionary *)defaultDocument;
+ (nullable instancetype)policyWithDocument:(id)document error:(NSError *_Nullable *_Nullable)error;
- (NSFlowEvaluation)evaluateIdentity:(nullable NSString *)identity
                           direction:(NSFlowDirection)direction
                         destination:(NSDictionary *)destination
                              socket:(BOOL)socket;
- (BOOL)automaticallyAllowsIdentity:(nullable NSString *)identity;
- (nullable NSString *)automaticSystemActionForIdentity:(nullable NSString *)identity;
- (BOOL)allowsIdentity:(nullable NSString *)identity direction:(NSFlowDirection)direction;
- (BOOL)requiresPermissionForIdentity:(nullable NSString *)identity;
- (BOOL)requiresPermissionForRequest:(NSDictionary *)request;
- (BOOL)requiresPermissionForIdentity:(nullable NSString *)identity destination:(NSDictionary *)destination;
- (BOOL)requiresPermissionForIdentity:(nullable NSString *)identity
                            direction:(NSFlowDirection)direction
                          destination:(NSDictionary *)destination;
- (BOOL)needsSocketDestination:(NSDictionary *)destination;
- (BOOL)needsSocketDestination:(NSDictionary *)destination identity:(nullable NSString *)identity;
- (BOOL)needsSocketDestination:(NSDictionary *)destination
                      identity:(nullable NSString *)identity
                     direction:(NSFlowDirection)direction;
- (BOOL)allowsIdentity:(nullable NSString *)identity
             direction:(NSFlowDirection)direction
           destination:(NSDictionary *)destination;
@end
NS_ASSUME_NONNULL_END
