#import "NSConstants.h"

static inline BOOL NSDNSExpiryIsLive(id expiry, NSDate *now) {
    if (![expiry isKindOfClass:NSDate.class]) {
        return NO;
    }
    NSTimeInterval remaining = [expiry timeIntervalSinceDate:now];
    return remaining > 0 && remaining <= 300;
}

static inline BOOL NSApplyDNSResults(NSMutableDictionary *document, NSDictionary *pending, NSDate *now) {
    NSMutableDictionary *addresses =
        [document[@"globalDomainAddresses"] mutableCopy] ?: [NSMutableDictionary new];
    NSMutableDictionary *expirations =
        [document[@"globalDomainExpirations"] mutableCopy] ?: [NSMutableDictionary new];
    for (NSString *key in addresses.allKeys) {
        if (!NSDNSExpiryIsLive(expirations[key], now) || !document[@"globalRules"][key] ||
            [document[@"globalRules"][key] isEqual:@"allow"]) {
            [addresses removeObjectForKey:key];
            [expirations removeObjectForKey:key];
        }
    }
    for (NSString *key in pending) {
        NSDictionary *entry = pending[key];
        if (![entry[@"rule"] isEqual:document[@"globalRules"][key]] ||
            !NSDNSExpiryIsLive(entry[@"expires"], now)) {
            continue;
        }
        addresses[key] = entry[@"addresses"];
        expirations[key] = entry[@"expires"];
    }
    if ([addresses isEqual:document[@"globalDomainAddresses"] ?: @{}] &&
        [expirations isEqual:document[@"globalDomainExpirations"] ?: @{}]) {
        return NO;
    }
    document[@"globalDomainAddresses"] = addresses;
    document[@"globalDomainExpirations"] = expirations;
    return YES;
}
