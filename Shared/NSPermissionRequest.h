#import "NSGlobalRule.h"
#import "NSPolicy.h"

static inline NSString *NSPermissionDirectionName(NSFlowDirection direction) {
    return direction == NSFlowDirectionInbound    ? @"inbound"
           : direction == NSFlowDirectionOutbound ? @"outbound"
                                                  : @"unknown";
}

static inline NSFlowDirection NSPermissionDirection(NSString *direction) {
    return [direction isEqual:@"inbound"]    ? NSFlowDirectionInbound
           : [direction isEqual:@"outbound"] ? NSFlowDirectionOutbound
                                             : NSFlowDirectionUnknown;
}

static inline BOOL NSUnidentifiedRequest(NSDictionary *request) {
    return [request[@"kind"] isEqual:@"unidentified"];
}

static inline NSString *NSConnectionFingerprint(NSDictionary *canonical, NSString *direction) {
    NSArray *fields = @[
        @"unidentified", direction, canonical[@"domain"] ?: NSNull.null, canonical[@"address"] ?: NSNull.null,
        canonical[@"port"] ?: NSNull.null, canonical[@"localPort"] ?: NSNull.null,
        canonical[@"protocol"] ?: NSNull.null
    ];
    NSData *data = [NSJSONSerialization dataWithJSONObject:fields options:0 error:NULL];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static inline BOOL NSConnectionHasConditions(NSDictionary *canonical, NSString *direction) {
    return canonical.count > 0 || NSPermissionDirection(direction) != NSFlowDirectionUnknown;
}

static inline NSString *NSPermissionGeneration(NSPolicy *policy, NSString *identity) {
    return (identity.length ? policy.document[@"askGenerations"][identity]
                            : policy.document[@"unidentifiedAskGeneration"])
               ?: @"";
}

static inline BOOL NSPermissionGenerationMatches(NSPolicy *policy, NSDictionary *request) {
    return [(request[@"askGeneration"] ?: @"") isEqual:NSPermissionGeneration(policy, request[@"identity"])];
}

// The presented tuple and its authority must still describe the same request.
static inline BOOL NSPermissionPresentationMatches(NSDictionary *presented, NSDictionary *current) {
    if (!presented || !current) {
        return NO;
    }
    for (NSString *key in @[
             @"token", @"identity", @"direction", @"kind", @"fingerprint", @"mode", @"flow", @"askGeneration",
             @"session", @"activation"
         ]) {
        if (![(presented[key] ?: @"") isEqual:(current[key] ?: @"")]) {
            return NO;
        }
    }
    return YES;
}

static inline NSString *NSUnidentifiedPermissionScope(NSDictionary *request) {
    if ([request[@"mode"] isEqual:@"once"]) {
        return @"This decision applies only to this connection. No rule will be saved.";
    }
    NSString *direction = [request[@"direction"] isEqual:@"unknown"]
                              ? @" The rule covers both directions because iOS did not report a direction."
                              : @" The rule is limited to the direction shown.";
    NSDictionary *destination = request[@"destination"];
    BOOL hasEndpoint = destination[@"domain"] || destination[@"address"] || destination[@"port"] ||
                       destination[@"localPort"];
    NSString *conditions = hasEndpoint ? @" whose connections match every available condition shown."
                           : destination[@"protocol"] ? @" using the protocol shown at any endpoint."
                                                      : @" at any endpoint and using any protocol.";
    return [NSString
        stringWithFormat:@"Saves a global rule for all apps and system processes%@%@", conditions, direction];
}
