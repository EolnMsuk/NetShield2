#import "NSConstants.h"
#import "NSGlobalRule.h"
#import "NSBootSession.h"
#import "NSValidation.h"
#include <math.h>

static inline BOOL NSDNSExpiryIsLive(id expiry, NSDate *now) {
    if (![expiry isKindOfClass:NSDate.class]) {
        return NO;
    }
    NSTimeInterval remaining = [expiry timeIntervalSinceDate:now];
    return remaining > 0 && remaining <= 300;
}

static inline BOOL NSValidDNSLifetime(id value) {
    if (![value isKindOfClass:NSDictionary.class] || [value count] != 3 ||
        !NSBoundedString(value[@"boot"], 128, NO)) {
        return NO;
    }
    id issue = value[@"issued"], expiry = value[@"expires"];
    if (![issue isKindOfClass:NSNumber.class] || NSBoolean(issue) || ![expiry isKindOfClass:NSNumber.class] ||
        NSBoolean(expiry)) {
        return NO;
    }
    double start = [issue doubleValue], end = [expiry doubleValue];
    return isfinite(start) && isfinite(end) && start >= 0 && end > start && end - start <= 300.001;
}
static inline BOOL NSDNSLifetimeIsLive(NSDictionary *lifetime, NSTimeInterval uptime, NSString *boot) {
    if (!lifetime) {
        return YES; // supported legacy policy has wall expiry only
    }
    return NSValidDNSLifetime(lifetime) && uptime >= [lifetime[@"issued"] doubleValue] &&
           uptime < [lifetime[@"expires"] doubleValue] &&
           (!boot || ![lifetime[@"boot"] length] || [lifetime[@"boot"] isEqual:boot]);
}
static inline BOOL NSDNSAddressIsLive(NSDictionary *document, NSString *key, NSDate *now) {
    return NSDNSExpiryIsLive(document[@"globalDomainExpirations"][key], now) &&
           NSDNSLifetimeIsLive(document[@"globalDomainLifetimes"][key],
                               NSProcessInfo.processInfo.systemUptime, NSBootSessionIdentifier());
}

static inline BOOL NSApplyDNSResults(NSMutableDictionary *document, NSDictionary *pending, NSDate *now) {
    NSDictionary *rules = NSGlobalRuleConditions(document[@"globalRules"]);
    NSMutableDictionary *addresses =
        [document[@"globalDomainAddresses"] mutableCopy] ?: [NSMutableDictionary new];
    NSMutableDictionary *expirations =
        [document[@"globalDomainExpirations"] mutableCopy] ?: [NSMutableDictionary new];
    NSMutableDictionary *lifetimes =
        [document[@"globalDomainLifetimes"] mutableCopy] ?: [NSMutableDictionary new];
    for (NSString *key in addresses.allKeys) {
        if (!NSDNSAddressIsLive(document, key, now) || !rules[key] || NSGlobalActionIsAllow(rules[key])) {
            [addresses removeObjectForKey:key];
            [expirations removeObjectForKey:key];
            [lifetimes removeObjectForKey:key];
        }
    }
    for (NSString *key in pending) {
        NSDictionary *entry = pending[key];
        if ((document[@"globalRuleGeneration"] &&
             ![entry[@"generation"] isEqual:document[@"globalRuleGeneration"]]) ||
            ![entry[@"rule"] isEqual:rules[key]] || NSGlobalActionIsAllow(rules[key]) ||
            !NSDNSExpiryIsLive(entry[@"expires"], now) ||
            !NSDNSLifetimeIsLive(entry[@"lifetime"], NSProcessInfo.processInfo.systemUptime,
                                 NSBootSessionIdentifier())) {
            continue;
        }
        addresses[key] = entry[@"addresses"];
        expirations[key] = entry[@"expires"];
        if (entry[@"lifetime"]) {
            lifetimes[key] = entry[@"lifetime"];
        } else {
            [lifetimes removeObjectForKey:key];
        }
    }
    if ([addresses isEqual:document[@"globalDomainAddresses"] ?: @{}] &&
        [expirations isEqual:document[@"globalDomainExpirations"] ?: @{}] &&
        [lifetimes isEqual:document[@"globalDomainLifetimes"] ?: @{}]) {
        return NO;
    }
    document[@"globalDomainAddresses"] = addresses;
    document[@"globalDomainExpirations"] = expirations;
    document[@"globalDomainLifetimes"] = lifetimes;
    return YES;
}
