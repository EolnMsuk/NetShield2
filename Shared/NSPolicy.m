#import "NSPolicy.h"
#import "NSConstants.h"
#import "NSDestination.h"
#import "NSGlobalRule.h"
#import "NSDNSCache.h"
#import <CoreFoundation/CoreFoundation.h>

// Directional allows do not decide traffic in the other or unknown direction.
static NSString *NSGlobalActionForDirection(NSString *action, NSFlowDirection direction) {
    if ([action isEqual:@"allow-inbound"]) {
        return direction == NSFlowDirectionInbound ? @"allow" : nil;
    }
    if ([action isEqual:@"allow-outbound"]) {
        return direction == NSFlowDirectionOutbound ? @"allow" : nil;
    }
    return action;
}

static BOOL NSCustomRuleApplies(NSDictionary *rule, NSString *identity, NSDictionary *destination) {
    if ([rule[@"identities"] count] && ![rule[@"identities"] containsObject:identity ?: @""]) {
        return NO;
    }
    NSString *protocol = rule[@"protocol"];
    // Browser flows do not expose their transport protocol.
    return [protocol isEqual:@"any"]
               ? (!destination[@"protocol"] || [@[ @"tcp", @"udp" ] containsObject:destination[@"protocol"]])
               : [protocol isEqual:destination[@"protocol"]];
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
    for (NSString *host in hosts) {
        if ([host isEqual:address] || [host isEqual:domain]) {
            hostMatches = YES;
            break;
        }
        // DNS address fallback is safe for blocking only; never grant an
        // allow rule to another hostname sharing the same IP address.
        if (!NSGlobalActionIsAllow(rule[@"action"]) && ![domain hasPrefix:@"domain:"] && address &&
            [host hasPrefix:@"domain:"] &&
            NSDNSExpiryIsLive(document[@"globalDomainExpirations"][host], NSDate.date) &&
            [document[@"globalDomainAddresses"][host] containsObject:address]) {
            hostMatches = YES;
            break;
        }
    }
    return hostMatches;
}

@interface NSPolicy ()
@property(nonatomic, copy) NSArray<NSDictionary *> *customGlobalRules;
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
    NSSet *actions = [NSSet setWithArray:@[ @"allow", @"block", @"block-inbound", @"block-outbound" ]];
    NSMutableSet *globalActions = [actions mutableCopy];
    [globalActions addObjectsFromArray:@[ @"allow-inbound", @"allow-outbound" ]];
    NSSet *defaults = [NSSet setWithArray:@[ @"allow", @"block", @"ask" ]];
    NSSet *unknownActions = [NSSet setWithArray:@[ @"allow", @"block" ]];
    valid = valid && [d[@"schema"] isKindOfClass:NSNumber.class] &&
            CFGetTypeID((__bridge CFTypeRef)d[@"schema"]) != CFBooleanGetTypeID() &&
            [d[@"schema"] isEqual:@(NSSchemaVersion)] && [d[@"revision"] isKindOfClass:NSString.class] &&
            [d[@"revision"] length] > 0 && [d[@"revision"] length] <= 128 &&
            [d[@"default"] isKindOfClass:NSString.class] && [defaults containsObject:d[@"default"]] &&
            [d[@"unattributed"] isKindOfClass:NSString.class] &&
            [unknownActions containsObject:d[@"unattributed"]] &&
            [d[@"rules"] isKindOfClass:NSDictionary.class];
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
                [key length] > NSMaximumIdentityLength || ![value isKindOfClass:NSString.class] ||
                ![actions containsObject:value]) {
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
                    ![globalActions containsObject:globalRules[key]]) {
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
                           NSLocalizedDescriptionKey : @"Invalid v2 policy. Filtering callbacks will block "
                                                       @"until a valid policy is readable."
                       }];
        }
        return nil;
    }
    NSMutableDictionary *canonicalDocument = [d mutableCopy];
    NSMutableDictionary *canonicalRules = [NSMutableDictionary new];
    for (NSString *key in globalRules) {
        NSString *canonical = [key hasPrefix:@"ip:"] ? NSGlobalHostKey([key substringFromIndex:3]) : key;
        canonicalRules[canonical] = NSMergeGlobalActions(canonicalRules[canonical], globalRules[key]);
    }
    canonicalDocument[@"globalRules"] = canonicalRules;
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
    return policy->_document ? policy : nil;
}
- (BOOL)automaticallyAllowsIdentity:(NSString *)identity {
    return [self.document[@"allowAppleSystemProcesses"] boolValue] && NSIsAppleSystemIdentity(identity);
}
- (NSString *)globalActionForDestination:(NSDictionary *)destination direction:(NSFlowDirection)direction {
    NSDictionary *rules = self.expandedGlobalRules;
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
    for (NSString *key in self.document[@"globalDomainAddresses"]) {
        if ([domainKey hasPrefix:@"domain:"] || !addressKey ||
            !NSDNSExpiryIsLive(self.document[@"globalDomainExpirations"][key], now) ||
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
    return ![self globalActionForIdentity:identity direction:direction destination:destination] &&
           [self requiresPermissionForIdentity:identity];
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
    for (NSString *key in self.expandedGlobalRules) {
        NSString *action = NSGlobalActionForDirection(self.expandedGlobalRules[key], direction);
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
    return ![self automaticallyAllowsIdentity:identity] && identity.length > 0 &&
           !self.document[@"rules"][identity] && [self.document[@"default"] isEqual:@"ask"];
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
    NSString *action = identity.length ? (self.document[@"rules"][identity] ?: self.document[@"default"])
                                       : self.document[@"unattributed"];
    action = globalAction ?: action;
    if ([action isEqual:@"allow"]) {
        return YES;
    }
    if ([action isEqual:@"block-inbound"]) {
        return direction == NSFlowDirectionOutbound;
    }
    if ([action isEqual:@"block-outbound"]) {
        return direction == NSFlowDirectionInbound;
    }
    return NO;
}
@end
