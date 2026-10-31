#import <Foundation/Foundation.h>

// Presentation only. Never use this value for rule keys, notification payloads,
// grouping, or decisions: distinct OS identities can have the same display name.
static inline NSString *NSIdentityDisplayName(id identity) {
    if (![identity isKindOfClass:NSString.class] || ![identity length]) {
        return @"Unidentified app";
    }
    NSRange period = [identity rangeOfString:@"."];
    NSString *name =
        period.location == NSNotFound ? identity : [identity substringFromIndex:period.location + 1];
    name = [name stringByReplacingOccurrencesOfString:@"com." withString:@""];
    name = [name stringByReplacingOccurrencesOfString:@"org." withString:@""];
    return name.length ? name : @"Unidentified app";
}

static inline NSComparisonResult NSCompareIdentityDisplayNames(NSString *left, NSString *right) {
    NSComparisonResult result =
        [NSIdentityDisplayName(left) localizedCaseInsensitiveCompare:NSIdentityDisplayName(right)];
    return result == NSOrderedSame ? [left compare:right options:NSLiteralSearch] : result;
}
