#import "NSPolicy.h"
#import "NSConstants.h"
#import "NSDestination.h"
#import <CoreFoundation/CoreFoundation.h>

@implementation NSPolicy
+ (NSDictionary *)defaultDocument {
    return @{
        @"schema" : @(NSSchemaVersion),
        @"revision" : NSUUID.UUID.UUIDString,
        @"default" : @"ask",
        @"unattributed" : @"allow",
        @"rules" : @{},
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
- (BOOL)requiresPermissionForIdentity:(NSString *)identity {
    return ![self automaticallyAllowsIdentity:identity] && identity.length > 0 &&
           !self.document[@"rules"][identity] && [self.document[@"default"] isEqual:@"ask"];
}
- (BOOL)allowsIdentity:(NSString *)identity direction:(NSFlowDirection)direction {
    if ([self automaticallyAllowsIdentity:identity]) {
        return YES;
    }
    NSString *action = identity.length ? (self.document[@"rules"][identity] ?: self.document[@"default"])
                                       : self.document[@"unattributed"];
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
