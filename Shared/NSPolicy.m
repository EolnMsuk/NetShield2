#import "NSPolicy.h"
#import "NSConstants.h"
#import "NSDestination.h"
#import "NSGlobalRule.h"
#import "NSDNSCache.h"
#import "NSRuleChoices.h"
#import "NSPermissionRequest.h"
#import "NSValidation.h"
#import <CoreFoundation/CoreFoundation.h>

static NSString *NSAppActionForDirection(id value, NSFlowDirection direction) {
    NSDictionary *record = value; // policy construction has already canonicalized app records
    return record[@"both"]
               ?: record[direction == NSFlowDirectionInbound    ? @"inbound"
                         : direction == NSFlowDirectionOutbound ? @"outbound"
                                                                : @"unknown"];
}

@interface NSPolicy ()
@property(nonatomic, copy) NSArray<NSDictionary *> *compiledGlobalRules;
@end

@implementation NSPolicy
+ (NSDictionary *)defaultDocument {
    return @{
        @"schema" : @(NSSchemaVersion),
        @"revision" : NSUUID.UUID.UUIDString,
        @"default" : @"ask",
        @"unattributed" : @"allow",
        @"rules" : @{},
        @"globalRules" : @{},
        @"ruleSetEpoch" : NSUUID.UUID.UUIDString,
        @"globalRuleGeneration" : NSUUID.UUID.UUIDString,
        @"allowAppleSystemProcesses" : @YES,
        @"filterSockets" : @YES
    };
}
+ (instancetype)policyWithDocument:(id)document error:(NSError **)error {
    BOOL valid = [document isKindOfClass:NSDictionary.class];
    NSDictionary *d = valid ? document : @{};
    NSSet *defaults = [NSSet setWithArray:@[ @"allow", @"block", @"ask" ]];
    valid = valid && NSUnsignedInteger(d[@"schema"], NSSchemaVersion) &&
            [d[@"schema"] isEqual:@(NSSchemaVersion)] && NSBoundedString(d[@"ruleSetEpoch"], 128, YES) &&
            NSBoundedString(d[@"revision"], 128, YES) && [defaults containsObject:d[@"default"] ?: @""] &&
            [defaults containsObject:d[@"unattributed"] ?: @""] &&
            [d[@"rules"] isKindOfClass:NSDictionary.class] &&
            [d[@"globalRules"] isKindOfClass:NSDictionary.class];
    valid = valid && NSBoundedString(d[@"globalRuleGeneration"], 128, YES);
    valid = valid &&
            (!d[@"unidentifiedAskGeneration"] || NSBoundedString(d[@"unidentifiedAskGeneration"], 128, YES));
    id appleAllowance = d[@"allowAppleSystemProcesses"];
    valid = valid &&
            (!appleAllowance || ([appleAllowance isKindOfClass:NSNumber.class] &&
                                 CFGetTypeID((__bridge CFTypeRef)appleAllowance) == CFBooleanGetTypeID()));
    id sockets = d[@"filterSockets"];
    valid = valid && (!sockets || ([sockets isKindOfClass:NSNumber.class] &&
                                   CFGetTypeID((__bridge CFTypeRef)sockets) == CFBooleanGetTypeID()));
    if (valid) {
        valid = [d[@"rules"] count] <= NSMaximumRules;
        for (id key in d[@"rules"]) {
            id value = d[@"rules"][key];
            if (![key isKindOfClass:NSString.class] || [key length] == 0 ||
                [key length] > NSMaximumIdentityLength || !NSAppRuleRecord(value)) {
                valid = NO;
                break;
            }
        }
    }
    NSDictionary *globalRules = d[@"globalRules"];
    NSError *globalError = nil;
    NSArray *compiledRules = valid ? NSCompileGlobalRules(globalRules, &globalError) : nil;
    valid = valid && compiledRules && [d[@"rules"] count] + globalRules.count <= NSMaximumRules;
    NSUInteger predicateCost = [d[@"rules"] count];
    if (valid) {
        for (NSString *key in globalRules) {
            predicateCost += NSGlobalConditionCost(NSGlobalRuleCondition(key));
        }
        valid = predicateCost <= NSMaximumRules;
    }
    id addresses = d[@"globalDomainAddresses"];
    if (valid && addresses) {
        valid = [addresses isKindOfClass:NSDictionary.class] && [addresses count] <= NSMaximumRules;
        if (valid) {
            for (id key in addresses) {
                if (![key isKindOfClass:NSString.class] || ![key hasPrefix:@"domain:"] ||
                    ![key isEqual:NSGlobalHostKey([key substringFromIndex:7])] ||
                    ![addresses[key] isKindOfClass:NSArray.class] || [addresses[key] count] > 128) {
                    valid = NO;
                    break;
                }
                for (id address in addresses[key]) {
                    if (![address isKindOfClass:NSString.class] || ![address hasPrefix:@"ip:"] ||
                        ![address isEqual:NSGlobalHostKey([address substringFromIndex:3])]) {
                        valid = NO;
                        break;
                    }
                }
            }
        }
    }
    id expirations = d[@"globalDomainExpirations"];
    if (valid && expirations) {
        valid = [expirations isKindOfClass:NSDictionary.class] && [expirations count] <= NSMaximumRules;
        if (valid) {
            for (id key in expirations) {
                if (![key isKindOfClass:NSString.class] || ![key hasPrefix:@"domain:"] ||
                    ![key isEqual:NSGlobalHostKey([key substringFromIndex:7])] ||
                    ![expirations[key] isKindOfClass:NSDate.class]) {
                    valid = NO;
                    break;
                }
            }
        }
    }
    id lifetimes = d[@"globalDomainLifetimes"];
    if (valid && lifetimes) {
        valid = [lifetimes isKindOfClass:NSDictionary.class] && [lifetimes count] <= NSMaximumRules;
        if (valid) {
            for (id key in lifetimes) {
                if (![key isKindOfClass:NSString.class] || ![addresses isKindOfClass:NSDictionary.class] ||
                    !addresses[key] || !NSValidDNSLifetime(lifetimes[key])) {
                    valid = NO;
                    break;
                }
            }
        }
    }
    id generations = d[@"askGenerations"];
    if (valid && generations) {
        valid = [generations isKindOfClass:NSDictionary.class] && [generations count] <= NSMaximumRules;
        if (valid) {
            for (id identity in generations) {
                if (![identity isKindOfClass:NSString.class] || ![identity length] ||
                    [identity length] > NSMaximumIdentityLength ||
                    ![generations[identity] isKindOfClass:NSString.class] ||
                    ![generations[identity] length] || [generations[identity] length] > 128) {
                    valid = NO;
                    break;
                }
            }
        }
    }
    id destinations = d[@"ruleDestinations"];
    if (valid && destinations) {
        valid = [destinations isKindOfClass:NSDictionary.class] && [destinations count] <= NSMaximumRules;
        if (valid) {
            for (id identity in destinations) {
                if (![identity isKindOfClass:NSString.class] || !d[@"rules"][identity] ||
                    !NSValidDestination(destinations[identity])) {
                    valid = NO;
                    break;
                }
            }
        }
    }
    if (!valid) {
        if (error) {
            *error = globalError
                         ?: [NSError errorWithDomain:@"NetShield2.Policy"
                                                code:1
                                            userInfo:@{
                                                NSLocalizedDescriptionKey :
                                                    @"Invalid or unsupported policy. Active filtering "
                                                    @"callbacks will block "
                                                    @"until a valid policy is readable."
                                            }];
        }
        return nil;
    }
    NSMutableDictionary *canonicalDocument = [NSMutableDictionary new];
    for (NSString *key in @[
             @"schema", @"revision", @"default", @"unattributed", @"rules", @"globalRules",
             @"globalDomainAddresses", @"globalDomainExpirations", @"globalDomainLifetimes",
             @"globalRuleGeneration", @"ruleDestinations", @"askGenerations", @"ruleSetEpoch",
             @"allowAppleSystemProcesses", @"filterSockets", @"unidentifiedAskGeneration"
         ]) {
        if (d[key]) {
            canonicalDocument[key] = d[key];
        }
    }
    NSMutableDictionary *appRules = [NSMutableDictionary new];
    for (NSString *identity in d[@"rules"]) {
        appRules[identity] = NSAppRuleRecord(d[@"rules"][identity]);
    }
    canonicalDocument[@"rules"] = appRules;
    // Preserve saved keys: canonical aliases can carry distinct direction coverage.
    canonicalDocument[@"globalRules"] = globalRules ?: @{};
    NSMutableDictionary *canonicalAddresses = [NSMutableDictionary new];
    for (NSString *key in addresses) {
        NSMutableOrderedSet *values = [NSMutableOrderedSet new];
        for (NSString *address in addresses[key]) {
            [values addObject:NSGlobalHostKey([address substringFromIndex:3])];
        }
        canonicalAddresses[key] = values.array;
    }
    if (addresses) {
        canonicalDocument[@"globalDomainAddresses"] = canonicalAddresses;
    }
    d = canonicalDocument;
    if (!sockets) {
        NSMutableDictionary *normalized = [d mutableCopy];
        normalized[@"filterSockets"] = @YES;
        d = normalized;
    }
    NSData *encoded = [NSPropertyListSerialization dataWithPropertyList:d
                                                                 format:NSPropertyListBinaryFormat_v1_0
                                                                options:0
                                                                  error:error];
    if (!encoded || encoded.length > NSMaximumDocumentBytes) {
        if (encoded && error) {
            *error = [NSError
                errorWithDomain:@"NetShield2.Policy"
                           code:3
                       userInfo:@{
                           NSLocalizedDescriptionKey : @"The encoded policy exceeds its storage limit."
                       }];
        }
        return nil;
    }
    NSPolicy *policy = [NSPolicy new];
    policy->_document = [NSPropertyListSerialization propertyListWithData:encoded
                                                                  options:NSPropertyListImmutable
                                                                   format:NULL
                                                                    error:error];
    policy.compiledGlobalRules = compiledRules;
    policy->_globalRuleConditions = [NSGlobalRuleConditions(policy->_document[@"globalRules"]) copy];
    return policy->_document ? policy : nil;
}
- (BOOL)automaticallyAllowsIdentity:(NSString *)identity {
    return [self.document[@"allowAppleSystemProcesses"] boolValue] && NSIsAppleSystemIdentity(identity);
}
- (BOOL)requiresPermissionForIdentity:(NSString *)identity destination:(NSDictionary *)destination {
    return [self requiresPermissionForIdentity:identity
                                     direction:NSFlowDirectionUnknown
                                   destination:destination];
}
- (BOOL)requiresPermissionForIdentity:(NSString *)identity
                            direction:(NSFlowDirection)direction
                          destination:(NSDictionary *)destination {
    return
        [self evaluateIdentity:identity direction:direction destination:destination socket:NO].disposition ==
        NSFlowAsk;
}
- (NSString *)globalActionForIdentity:(NSString *)identity
                            direction:(NSFlowDirection)direction
                          destination:(NSDictionary *)destination {
    NSString *result = nil;
    for (NSDictionary *rule in self.compiledGlobalRules) {
        BOOL allow = NSGlobalActionIsAllow(rule[@"action"]);
        if (NSMatchGlobalCondition(rule, identity, direction, destination, allow, self.document) ==
            NSGlobalMatched) {
            // Derived blocking DNS answers may collide even though the explicit
            // predicates are disjoint. Keep the existing conservative verdict.
            result = NSMergeGlobalActions(result, allow ? @"allow" : @"block");
        }
    }
    return result;
}
- (BOOL)needsSocketDestination:(NSDictionary *)destination {
    return [self needsSocketDestination:destination identity:nil];
}
- (BOOL)needsSocketDestination:(NSDictionary *)destination identity:(NSString *)identity {
    return [self needsSocketDestination:destination identity:identity direction:NSFlowDirectionUnknown];
}
- (BOOL)needsSocketDestination:(NSDictionary *)destination
                      identity:(NSString *)identity
                     direction:(NSFlowDirection)direction {
    for (NSDictionary *rule in self.compiledGlobalRules) {
        if (NSMatchGlobalCondition(rule, identity, direction, destination,
                                   NSGlobalActionIsAllow(rule[@"action"]),
                                   self.document) == NSGlobalMissingEndpoints) {
            return YES;
        }
    }
    return NO;
}
- (BOOL)requiresPermissionForIdentity:(NSString *)identity {
    // Without a direction, report whether any direction can still require permission.
    return (!identity.length && [self requiresPermissionForIdentity:identity destination:@{}]) ||
           [self requiresPermissionForIdentity:identity direction:NSFlowDirectionInbound destination:@{}] ||
           [self requiresPermissionForIdentity:identity direction:NSFlowDirectionOutbound destination:@{}];
}
- (BOOL)requiresPermissionForRequest:(NSDictionary *)request {
    NSFlowDirection direction = NSPermissionDirection(request[@"direction"]);
    return [self requiresPermissionForIdentity:request[@"identity"]
                                     direction:direction
                                   destination:request[@"destination"] ?: @{}];
}
- (BOOL)allowsIdentity:(NSString *)identity direction:(NSFlowDirection)direction {
    return [self allowsIdentity:identity direction:direction destination:@{}];
}
- (BOOL)allowsIdentity:(NSString *)identity
             direction:(NSFlowDirection)direction
           destination:(NSDictionary *)destination {
    NSString *globalAction = [self globalActionForIdentity:identity
                                                 direction:direction
                                               destination:destination];
    if (!globalAction && [self automaticallyAllowsIdentity:identity]) {
        return YES;
    }
    NSString *action = identity.length
                           ? (NSAppActionForDirection(self.document[@"rules"][identity], direction)
                                  ?: self.document[@"default"])
                           : self.document[@"unattributed"];
    action = globalAction ?: action;
    if ([action isEqual:@"allow"]) {
        return YES;
    }
    return NO;
}
- (NSFlowEvaluation)evaluateIdentity:(NSString *)identity
                           direction:(NSFlowDirection)direction
                         destination:(NSDictionary *)destination
                              socket:(BOOL)socket {
    direction = NSNormalizedFlowDirection(direction);
    if (socket && [self needsSocketDestination:destination identity:identity direction:direction]) {
        return (NSFlowEvaluation){NSFlowNeedsEndpoints, NSFlowReasonEndpoints};
    }
    NSString *action = [self globalActionForIdentity:identity direction:direction destination:destination];
    if (action) {
        return (NSFlowEvaluation){[action isEqual:@"allow"] ? NSFlowAllow : NSFlowDrop, NSFlowReasonGlobal};
    }
    if ([self automaticallyAllowsIdentity:identity]) {
        return (NSFlowEvaluation){NSFlowAllow, NSFlowReasonSystem};
    }
    NSFlowDecisionReason reason = identity.length ? NSFlowReasonApp : NSFlowReasonUnidentified;
    action = identity.length ? NSAppActionForDirection(self.document[@"rules"][identity], direction)
                             : self.document[@"unattributed"];
    if (!action) {
        action = self.document[@"default"];
        reason = NSFlowReasonDefault;
    }
    NSFlowDisposition disposition =
        [action isEqual:@"allow"] ? NSFlowAllow : ([action isEqual:@"ask"] ? NSFlowAsk : NSFlowDrop);
    return (NSFlowEvaluation){disposition, reason};
}
@end
