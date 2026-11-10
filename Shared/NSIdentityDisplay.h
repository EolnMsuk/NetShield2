#import <Foundation/Foundation.h>

// Presentation only. Never use this value for rule keys, notification payloads,
// grouping, or decisions: distinct OS identities can have the same display name.
static inline NSString *NSIdentityDisplayName(id identity) {
    if (![identity isKindOfClass:NSString.class] || ![identity length]) {
        return @"Unidentified app";
    }
    BOOL suppressMainSuffix = [identity hasPrefix:@".Apple.com"] || [identity hasPrefix:@"Apple.com"];
    NSRange period = [identity rangeOfString:@"."];
    NSString *name =
        period.location == NSNotFound ? identity : [identity substringFromIndex:period.location + 1];
    BOOL hasMainPrefix = NO;
    if (period.location != NSNotFound && period.location > 0 &&
        ([name hasPrefix:@"com."] || [name isEqualToString:@"com"])) {
        NSRange lettersOrNumbers = [identity rangeOfString:@"[\\p{L}\\p{N}]"
                                                   options:NSRegularExpressionSearch
                                                     range:NSMakeRange(0, period.location)];
        hasMainPrefix = lettersOrNumbers.location != NSNotFound;
    }
    name = [name stringByReplacingOccurrencesOfString:@"com." withString:@""];
    name = [name stringByReplacingOccurrencesOfString:@"org." withString:@""];
    if (!name.length) {
        return @"Unidentified app";
    }
    return hasMainPrefix && !suppressMainSuffix ? [name stringByAppendingString:@" (main)"] : name;
}

// For presentation and copying only. Keep the raw identity for rule operations.
static inline NSString *NSIdentityFullDisplayName(id identity) {
    if (![identity isKindOfClass:NSString.class] || ![identity length]) {
        return @"";
    }
    return [identity characterAtIndex:0] == '.' ? [identity substringFromIndex:1] : identity;
}

static inline NSComparisonResult NSCompareIdentityDisplayNames(NSString *left, NSString *right) {
    NSComparisonResult result =
        [NSIdentityDisplayName(left) localizedCaseInsensitiveCompare:NSIdentityDisplayName(right)];
    return result == NSOrderedSame ? [left compare:right options:NSLiteralSearch] : result;
}
