#import <Foundation/Foundation.h>
#include <arpa/inet.h>

// Canonical exact host/port keys shared by input validation and flow matching.
static inline NSString *NSGlobalHostKey(id value) {
    if (![value isKindOfClass:NSString.class]) {
        return nil;
    }
    NSString *host = [[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        lowercaseString];
    if ([host hasPrefix:@"["] && [host hasSuffix:@"]"]) {
        host = [host substringWithRange:NSMakeRange(1, host.length - 2)];
    }
    struct in6_addr bytes;
    char text[INET6_ADDRSTRLEN];
    for (NSNumber *family in @[ @(AF_INET), @(AF_INET6) ]) {
        if (inet_pton(family.intValue, host.UTF8String, &bytes) == 1) {
            inet_ntop(family.intValue, &bytes, text, sizeof(text));
            return [@"ip:" stringByAppendingString:@(text)];
        }
    }
    if ([host hasSuffix:@"."]) {
        host = [host substringToIndex:host.length - 1];
    }
    if (!host.length || host.length > 253) {
        return nil;
    }
    NSCharacterSet *invalid = [[NSCharacterSet
        characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-"] invertedSet];
    BOOL hasLetter =
        [host rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location != NSNotFound;
    if (!hasLetter) {
        return nil;
    }
    for (NSString *label in [host componentsSeparatedByString:@"."]) {
        if (!label.length || label.length > 63 || [label hasPrefix:@"-"] || [label hasSuffix:@"-"] ||
            [label rangeOfCharacterFromSet:invalid].location != NSNotFound) {
            return nil;
        }
    }
    return [@"domain:" stringByAppendingString:host];
}
// Input normalization is separate from validation of existing persisted keys.
static inline NSString *NSGlobalInputHostKey(id value) {
    NSString *key = NSGlobalHostKey(value);
    if ([key hasPrefix:@"domain:"] && ![key hasPrefix:@"domain:www."]) {
        return NSGlobalHostKey([@"www." stringByAppendingString:[key substringFromIndex:7]]);
    }
    return key;
}
static inline NSArray<NSString *> *NSGlobalDomainAliases(NSString *key) {
    if (![key hasPrefix:@"domain:"]) {
        return @[];
    }
    NSString *host = [key substringFromIndex:7];
    return @[
        host, [host hasPrefix:@"www."] ? [host substringFromIndex:4] : [@"www." stringByAppendingString:host]
    ];
}
static inline NSString *NSGlobalPortKey(id value) {
    if (![value isKindOfClass:NSString.class]) {
        return nil;
    }
    NSString *port = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
    if (!port.length || port.length > 5 || [port rangeOfCharacterFromSet:invalid].location != NSNotFound ||
        port.integerValue < 1 || port.integerValue > 65535) {
        return nil;
    }
    return [NSString stringWithFormat:@"port:%ld", (long)port.integerValue];
}
static inline BOOL NSValidGlobalRuleKey(id key) {
    if (![key isKindOfClass:NSString.class]) {
        return NO;
    }
    NSRange colon = [key rangeOfString:@":"];
    if (colon.location == NSNotFound) {
        return NO;
    }
    NSString *value = [key substringFromIndex:colon.location + 1];
    NSString *canonical = [key hasPrefix:@"port:"] ? NSGlobalPortKey(value) : NSGlobalHostKey(value);
    return [key isEqual:canonical];
}
