#import <Foundation/Foundation.h>

// Presentation only. Never use this value for rule keys, notification payloads,
// grouping, or decisions: distinct OS identities can have the same display name.
static inline NSString *NSIdentityDisplayName(id identity) {
    if (![identity isKindOfClass:NSString.class] || ![identity length]) {
        return @"Unidentified app";
    }
    NSString *rawIdentity = identity;
    NSRange period = [rawIdentity rangeOfString:@"." options:NSLiteralSearch];
    if (period.location == NSNotFound) {
        return rawIdentity;
    }
    NSRange comDelimiter = [rawIdentity rangeOfString:@".com." options:NSLiteralSearch];
    BOOL hasMainPrefix = NO;
    if (comDelimiter.location != NSNotFound && comDelimiter.location > 0) {
        NSRange lettersOrNumbers = [rawIdentity rangeOfString:@"[\\p{L}\\p{N}]"
                                                      options:NSRegularExpressionSearch
                                                        range:NSMakeRange(0, comDelimiter.location)];
        hasMainPrefix = lettersOrNumbers.location != NSNotFound;
    }
    // Include the starting period so namespace removal can match both sides of "com".
    NSUInteger nameStart = hasMainPrefix ? comDelimiter.location : period.location;
    NSString *name = [rawIdentity substringFromIndex:nameStart];
    if ([name isEqualToString:@".com"]) {
        return rawIdentity;
    }
    if (comDelimiter.location != NSNotFound) {
        // Keep the trailing period so consecutive "com" components can each match.
        name = [name stringByReplacingOccurrencesOfString:@"\\.com(?=\\.)"
                                               withString:@""
                                                  options:NSRegularExpressionSearch
                                                    range:NSMakeRange(0, name.length)];
    }
    name = [[name substringFromIndex:1] stringByReplacingOccurrencesOfString:@"org." withString:@""];
    if (!name.length) {
        return @"Unidentified app";
    }
    return hasMainPrefix ? [name stringByAppendingString:@" (main)"] : name;
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
