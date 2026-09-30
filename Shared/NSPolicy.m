#import "NSPolicy.h"
#import "NSConstants.h"
#import "NSDestination.h"
#import "NSGlobalRule.h"
#import <CoreFoundation/CoreFoundation.h>

@implementation NSPolicy
+ (NSDictionary *)defaultDocument {
    return @{
        @"schema" : @(NSSchemaVersion),
        @"revision" : NSUUID.UUID.UUIDString,
        @"default" : @"ask",
        @"unattributed" : @"allow",
        @"rules" : @{},
        @"globalRules" : @{},
        @"allowAppleSystemProcesses" : @YES,
        @"filterSockets" : @YES
    };
}
+ (instancetype)policyWithDocument:(id)document error:(NSError **)error {
    BOOL valid = [document isKindOfClass:NSDictionary.class];
    NSDictionary *d = valid ? document : @{};
    NSSet *actions = [NSSet setWithArray:@[ @"allow", @"block", @"block-inbound", @"block-outbound" ]];
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
            for (id key in globalRules) {
                if (!NSValidGlobalRuleKey(key) || ![globalRules[key] isKindOfClass:NSString.class] ||
                    ![actions containsObject:globalRules[key]]) {
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
    // Older policies have no socket preference. Default to full flow coverage,
    // while preserving an explicit choice to disable socket filtering.
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
    return policy->_document ? policy : nil;
}
- (BOOL)automaticallyAllowsIdentity:(NSString *)identity {
    return [identity isKindOfClass:NSString.class] &&
           [self.document[@"allowAppleSystemProcesses"] boolValue] &&
           ([identity hasPrefix:@"com.apple."] || [identity hasPrefix:@".com.apple."] ||
            [identity hasPrefix:@"Apple.com.apple."]);
}
- (NSString *)globalActionForDestination:(NSDictionary *)destination {
    NSDictionary *rules = self.document[@"globalRules"];
    NSString *addressKey = NSGlobalHostKey(destination[@"address"]);
    NSString *action = addressKey ? rules[addressKey] : nil;
    if (action) {
        return action;
    }
    NSString *domainKey = NSGlobalHostKey(destination[@"domain"]);
    for (NSString *host in NSGlobalDomainAliases(domainKey)) {
        action = rules[[@"domain:" stringByAppendingString:host]];
        if (action) {
            return action;
        }
    }
    // Only blocks use DNS address fallback: a shared hosting IP must never grant access.
    // Combine directional blocks deterministically when several domains share an IP.
    BOOL inbound = NO, outbound = NO;
    for (NSString *key in self.document[@"globalDomainAddresses"]) {
        if ([domainKey hasPrefix:@"domain:"] || !addressKey ||
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
    return portKey ? rules[portKey] : nil;
}
- (BOOL)requiresPermissionForIdentity:(NSString *)identity destination:(NSDictionary *)destination {
    return ![self globalActionForDestination:destination] && [self requiresPermissionForIdentity:identity];
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
    NSString *globalAction = [self globalActionForDestination:destination];
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
