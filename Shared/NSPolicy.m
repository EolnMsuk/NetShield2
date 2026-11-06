#import "NSPolicy.h"
#import "NSConstants.h"
#import "NSDestination.h"
#import "NSGlobalRule.h"
#import "NSDNSCache.h"
#import "NSRuleChoices.h"
#import "NSValidation.h"
#import <CoreFoundation/CoreFoundation.h>

static NSString *NSAppActionForDirection(id value, NSFlowDirection direction) {
    NSDictionary *record = value; // policy construction has already canonicalized app records
    return record[@"both"]
               ?: record[direction == NSFlowDirectionInbound    ? @"inbound"
                         : direction == NSFlowDirectionOutbound ? @"outbound"
                                                                : @"unknown"];
}

// Global actions cover only their selected direction.
static NSString *NSGlobalActionForDirection(NSString *action, NSFlowDirection direction) {
    if ([action hasSuffix:@"-inbound"] || [action hasSuffix:@"-outbound"]) {
        BOOL matches = [action hasSuffix:@"-inbound"] ? direction == NSFlowDirectionInbound
                                                      : direction == NSFlowDirectionOutbound;
        return matches ? (NSGlobalActionIsAllow(action) ? @"allow" : @"block") : nil;
    }
    return action;
}
static NSDictionary *NSGlobalsForDirection(NSDictionary *rules, NSFlowDirection direction) {
    NSMutableDictionary *applicable = [NSMutableDictionary new];
    for (NSString *key in rules) {
        NSString *action = NSGlobalActionForDirection(rules[key], direction);
        if (action) {
            applicable[key] = action;
        }
    }
    // Resolve coverage before expansion can merge actions from overlapping legacy groups.
    return NSExpandedGlobalRules(applicable);
}

static BOOL NSCustomRuleApplies(NSDictionary *rule, NSString *identity, NSDictionary *destination) {
    if ([rule[@"identities"] count] && ![rule[@"identities"] containsObject:identity ?: @""]) {
        return NO;
    }
    NSString *protocol = rule[@"protocol"];
    // Combined rules cover every delivered protocol, including other and missing metadata.
    return [protocol isEqual:@"any"] || [protocol isEqual:destination[@"protocol"]];
}
static BOOL NSMissingGlobalEndpoint(NSString *key, NSString *action, NSDictionary *destination) {
    BOOL needsAddress =
        [key hasPrefix:@"ip:"] ||
        ([key hasPrefix:@"domain:"] && ![NSGlobalHostKey(destination[@"domain"]) hasPrefix:@"domain:"] &&
         !NSGlobalActionIsAllow(action));
    return (needsAddress && ![destination[@"address"] length]) ||
           ([key hasPrefix:@"port:"] && !destination[@"port"]) ||
           ([key hasPrefix:@"localPort:"] && !destination[@"localPort"]);
}

static BOOL NSCustomHostsMatch(NSDictionary *rule, NSDictionary *destination, NSDictionary *document) {
    NSString *address = NSGlobalHostKey(destination[@"address"]);
    NSString *domain = NSGlobalHostKey(destination[@"domain"]);
    NSArray *hosts = rule[@"hosts"];
    BOOL hostMatches = !hosts.count;
    for (NSString *savedHost in hosts) {
        NSString *host =
            NSGlobalHostKey([savedHost substringFromIndex:[savedHost rangeOfString:@":"].location + 1]);
        if ([host isEqual:address] || [host isEqual:domain]) {
            hostMatches = YES;
            break;
        }
        // DNS address fallback is safe for blocking only; never grant an
        // allow rule to another hostname sharing the same IP address.
        if (!NSGlobalActionIsAllow(rule[@"action"]) && ![domain hasPrefix:@"domain:"] && address &&
            [host hasPrefix:@"domain:"] && NSDNSAddressIsLive(document, host, NSDate.date) &&
            [document[@"globalDomainAddresses"][host] containsObject:address]) {
            hostMatches = YES;
            break;
        }
    }
    return hostMatches;
}

@interface NSPolicy ()
@property(nonatomic, copy) NSArray<NSDictionary *> *customGlobalRules;
@property(nonatomic, copy) NSArray<NSDictionary *> *directionalGlobalRules;
@property(nonatomic, copy) NSDictionary *dnsByAddress;
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
        @"exactDomainResolution" : @YES,
        @"allowAppleSystemProcesses" : @YES,
        @"filterSockets" : @YES
    };
}
+ (instancetype)policyWithDocument:(id)document error:(NSError **)error {
    BOOL valid = [document isKindOfClass:NSDictionary.class];
    NSDictionary *d = valid ? document : @{};
    NSSet *actions = [NSSet setWithArray:NSDirectionRuleValues()];
    NSSet *globalActions = actions;
    NSSet *defaults = [NSSet setWithArray:@[ @"allow", @"block", @"ask" ]];
    NSSet *unknownActions = [NSSet setWithArray:@[ @"allow", @"block" ]];
    valid = valid && [d[@"schema"] isKindOfClass:NSNumber.class] &&
            CFGetTypeID((__bridge CFTypeRef)d[@"schema"]) != CFBooleanGetTypeID() &&
            ([d[@"schema"] isEqual:@2] || [d[@"schema"] isEqual:@(NSSchemaVersion)]) &&
            [d[@"revision"] isKindOfClass:NSString.class] && [d[@"revision"] length] > 0 &&
            [d[@"revision"] length] <= 128 && [d[@"default"] isKindOfClass:NSString.class] &&
            [defaults containsObject:d[@"default"]] && [d[@"unattributed"] isKindOfClass:NSString.class] &&
            [unknownActions containsObject:d[@"unattributed"]] &&
            [d[@"rules"] isKindOfClass:NSDictionary.class];
    valid = valid && (!d[@"globalRuleGeneration"] || NSBoundedString(d[@"globalRuleGeneration"], 128, YES));
    valid = valid && (!d[@"exactDomainResolution"] || NSBoolean(d[@"exactDomainResolution"]));
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
    id globalRules = d[@"globalRules"];
    if (valid && globalRules) {
        valid = [globalRules isKindOfClass:NSDictionary.class] && [globalRules count] <= NSMaximumRules;
        if (valid) {
            NSUInteger memberCount = 0;
            for (id key in globalRules) {
                if (!NSValidGlobalRuleKey(key) ||
                    (memberCount += MAX((NSUInteger)1, NSGlobalRuleMembers(key).count)) > NSMaximumRules ||
                    ![globalRules[key] isKindOfClass:NSString.class] ||
                    ![globalActions containsObject:globalRules[key]] ||
                    !NSGlobalCoverageAgrees(key, globalRules[key])) {
                    valid = NO;
                    break;
                }
            }
        }
    }
    id addresses = d[@"globalDomainAddresses"];
    if (valid && addresses) {
        valid = [addresses isKindOfClass:NSDictionary.class] && [addresses count] <= NSMaximumRules;
        if (valid) {
            for (id key in addresses) {
                if (!NSValidGlobalRuleKey(key) || ![key hasPrefix:@"domain:"] ||
                    ![addresses[key] isKindOfClass:NSArray.class] || [addresses[key] count] > 128) {
                    valid = NO;
                    break;
                }
                for (id address in addresses[key]) {
                    if (!NSValidGlobalRuleKey(address) || ![address hasPrefix:@"ip:"]) {
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
                if (!NSValidGlobalRuleKey(key) || ![key hasPrefix:@"domain:"] ||
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
            *error = [NSError
                errorWithDomain:@"NetShield2.Policy"
                           code:1
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"Invalid or unsupported policy. Active filtering callbacks will block "
                               @"until a valid policy is readable."
                       }];
        }
        return nil;
    }
    NSMutableDictionary *canonicalDocument = [NSMutableDictionary new];
    for (NSString *key in @[
             @"schema", @"revision", @"default", @"unattributed", @"rules", @"globalRules",
             @"globalDomainAddresses", @"globalDomainExpirations", @"globalDomainLifetimes",
             @"globalRuleGeneration", @"ruleDestinations", @"askGenerations", @"exactDomainResolution",
             @"allowAppleSystemProcesses", @"filterSockets"
         ]) {
        if (d[key]) {
            canonicalDocument[key] = d[key];
        }
    }
    canonicalDocument[@"schema"] = @(NSSchemaVersion);
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
    // Discard pre-2.3.1 DNS answers, which combined bare and www hosts.
    if (![d[@"exactDomainResolution"] isEqual:@YES]) {
        [canonicalDocument removeObjectForKey:@"globalDomainAddresses"];
        [canonicalDocument removeObjectForKey:@"globalDomainExpirations"];
        [canonicalDocument removeObjectForKey:@"globalDomainLifetimes"];
    }
    canonicalDocument[@"exactDomainResolution"] = @YES;
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
    if (!encoded) {
        return nil;
    }
    NSPolicy *policy = [NSPolicy new];
    policy->_document = [NSPropertyListSerialization propertyListWithData:encoded
                                                                  options:NSPropertyListImmutable
                                                                   format:NULL
                                                                    error:error];
    policy->_expandedGlobalRules = [NSExpandedGlobalRules(policy->_document[@"globalRules"]) copy];
    policy->_globalRuleConditions = [NSGlobalRuleConditions(policy->_document[@"globalRules"]) copy];
    NSMutableArray *directionalRules = [NSMutableArray new];
    for (NSFlowDirection direction = NSFlowDirectionUnknown; direction <= NSFlowDirectionOutbound;
         direction++) {
        [directionalRules addObject:NSGlobalsForDirection(policy->_document[@"globalRules"], direction)];
    }
    policy.directionalGlobalRules = directionalRules;
    NSMutableArray *customRules = [NSMutableArray new];
    for (NSString *key in policy->_document[@"globalRules"]) {
        NSArray *parts = NSCustomGlobalRuleComponents(key);
        if (parts) {
            [customRules addObject:@{
                @"identities" : NSCustomGlobalRuleIdentities(parts),
                @"hosts" : [parts[1] length] ? NSGlobalRuleMembers(parts[1]) : @[],
                @"ports" : [parts[2] length] ? NSGlobalRuleMembers(parts[2]) : @[],
                @"protocol" : parts[3],
                @"action" : policy->_document[@"globalRules"][key]
            }];
        }
    }
    policy.customGlobalRules = customRules;
    NSMutableDictionary *reverse = [NSMutableDictionary new];
    for (NSString *domain in policy.document[@"globalDomainAddresses"]) {
        for (NSString *address in policy.document[@"globalDomainAddresses"][domain]) {
            NSMutableArray *domains = reverse[address] ?: (reverse[address] = [NSMutableArray new]);
            [domains addObject:domain];
        }
    }
    NSMutableDictionary *immutableReverse = [NSMutableDictionary new];
    for (NSString *address in reverse) {
        immutableReverse[address] = [reverse[address] copy];
    }
    policy.dnsByAddress = [immutableReverse copy];
    return policy->_document ? policy : nil;
}
- (BOOL)automaticallyAllowsIdentity:(NSString *)identity {
    return [self.document[@"allowAppleSystemProcesses"] boolValue] && NSIsAppleSystemIdentity(identity);
}
- (NSString *)globalActionForDestination:(NSDictionary *)destination direction:(NSFlowDirection)direction {
    NSDictionary *rules = self.directionalGlobalRules[NSNormalizedFlowDirection(direction)];
    NSString *addressKey = NSGlobalHostKey(destination[@"address"]);
    NSString *action = NSGlobalActionForDirection(addressKey ? rules[addressKey] : nil, direction);
    if (action) {
        return action;
    }
    NSString *domainKey = NSGlobalHostKey(destination[@"domain"]);
    for (NSString *host in NSGlobalDomainAliases(domainKey)) {
        action = NSGlobalActionForDirection(rules[[@"domain:" stringByAppendingString:host]], direction);
        if (action) {
            return action;
        }
    }
    BOOL inbound = NO, outbound = NO;
    NSDate *now = NSDate.date;
    for (NSString *key in addressKey ? self.dnsByAddress[addressKey] : @[]) {
        if ([domainKey hasPrefix:@"domain:"] || !addressKey || !NSDNSAddressIsLive(self.document, key, now) ||
            ![self.document[@"globalDomainAddresses"][key] containsObject:addressKey]) {
            continue;
        }
        action = rules[key];
        inbound |= [action isEqual:@"block"] || [action isEqual:@"block-inbound"];
        outbound |= [action isEqual:@"block"] || [action isEqual:@"block-outbound"];
    }
    if (inbound || outbound) {
        return inbound && outbound ? @"block" : inbound ? @"block-inbound" : @"block-outbound";
    }
    NSString *portKey = NSGlobalPortKey([destination[@"port"] stringValue]);
    action = NSGlobalActionForDirection(portKey ? rules[portKey] : nil, direction);
    if (action) {
        return action;
    }
    NSString *localPortKey = NSGlobalLocalPortKey([destination[@"localPort"] stringValue]);
    return NSGlobalActionForDirection(localPortKey ? rules[localPortKey] : nil, direction);
}
- (BOOL)requiresPermissionForIdentity:(NSString *)identity destination:(NSDictionary *)destination {
    return [self requiresPermissionForIdentity:identity
                                     direction:NSFlowDirectionUnknown
                                   destination:destination];
}
- (BOOL)requiresPermissionForIdentity:(NSString *)identity
                            direction:(NSFlowDirection)direction
                          destination:(NSDictionary *)destination {
    NSString *action = NSAppActionForDirection(self.document[@"rules"][identity ?: @""], direction);
    return ![self globalActionForIdentity:identity direction:direction destination:destination] &&
           ![self automaticallyAllowsIdentity:identity] && identity.length > 0 && !action &&
           [self.document[@"default"] isEqual:@"ask"];
}
- (NSString *)globalActionForIdentity:(NSString *)identity
                            direction:(NSFlowDirection)direction
                          destination:(NSDictionary *)destination {
    NSString *result = [self globalActionForDestination:destination direction:direction];
    NSString *remotePort = NSGlobalPortKey([destination[@"port"] stringValue]);
    NSString *localPort = NSGlobalLocalPortKey([destination[@"localPort"] stringValue]);
    for (NSDictionary *rule in self.customGlobalRules) {
        if (!NSGlobalActionForDirection(rule[@"action"], direction) ||
            !NSCustomRuleApplies(rule, identity, destination)) {
            continue;
        }
        NSArray *ports = rule[@"ports"];
        if (ports.count && ![ports containsObject:remotePort ?: @""] &&
            ![ports containsObject:localPort ?: @""]) {
            continue;
        }
        BOOL hostMatches = NSCustomHostsMatch(rule, destination, self.document);
        if (hostMatches) {
            NSString *action = NSGlobalActionForDirection(rule[@"action"], direction);
            if (action) {
                result = NSMergeGlobalActions(result, action);
            }
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
    NSDictionary *applicable = self.directionalGlobalRules[NSNormalizedFlowDirection(direction)];
    for (NSString *key in applicable) {
        NSString *action = applicable[key];
        if (action && NSMissingGlobalEndpoint(key, action, destination)) {
            return YES;
        }
    }
    for (NSDictionary *rule in self.customGlobalRules) {
        if (!NSGlobalActionForDirection(rule[@"action"], direction) ||
            !NSCustomRuleApplies(rule, identity, destination)) {
            continue;
        }
        NSArray *ports = rule[@"ports"];
        BOOL portMatches =
            !ports.count ||
            [ports containsObject:NSGlobalPortKey([destination[@"port"] stringValue]) ?: @""] ||
            [ports containsObject:NSGlobalLocalPortKey([destination[@"localPort"] stringValue]) ?: @""];
        BOOL missingPort = NO, missingHost = NO;
        for (NSString *key in ports) {
            missingPort |= NSMissingGlobalEndpoint(key, rule[@"action"], destination);
        }
        if (!portMatches && !missingPort) {
            continue;
        }
        BOOL hostMatches = NSCustomHostsMatch(rule, destination, self.document);
        if (!hostMatches) {
            for (NSString *key in rule[@"hosts"]) {
                missingHost |= NSMissingGlobalEndpoint(key, rule[@"action"], destination);
            }
        }
        if (!hostMatches && !missingHost) {
            continue;
        }
        if (missingPort || missingHost) {
            return YES;
        }
    }
    return NO;
}
- (BOOL)requiresPermissionForIdentity:(NSString *)identity {
    // Without a direction, report whether any direction can still require permission.
    return [self requiresPermissionForIdentity:identity direction:NSFlowDirectionInbound destination:@{}] ||
           [self requiresPermissionForIdentity:identity direction:NSFlowDirectionOutbound destination:@{}];
}
- (BOOL)requiresPermissionForRequest:(NSDictionary *)request {
    NSString *value = request[@"direction"];
    NSFlowDirection direction = [value isEqual:@"inbound"]    ? NSFlowDirectionInbound
                                : [value isEqual:@"outbound"] ? NSFlowDirectionOutbound
                                                              : NSFlowDirectionUnknown;
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
        [action isEqual:@"allow"] ? NSFlowAllow
                                  : ([action isEqual:@"ask"] && identity.length ? NSFlowAsk : NSFlowDrop);
    return (NSFlowEvaluation){disposition, reason};
}
@end
