#import "NSConstants.h"

static inline BOOL NSDNSExpiryIsLive(id expiry, NSDate *now) {
    if (![expiry isKindOfClass:NSDate.class]) {
        return NO;
    }
    NSTimeInterval remaining = [expiry timeIntervalSinceDate:now];
    // The resolver never grants a lifetime over five minutes. A clock rollback
    // must not turn an old entry into a long-lived block.
    return remaining > 0 && remaining <= 300;
}

// Caller owns policy.lock. Replace answer sets, never union old or observed IPs.
// Returns NO only when the document is unchanged; persistence owns I/O errors.
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
