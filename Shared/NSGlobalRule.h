#import <Foundation/Foundation.h>
#import "NSConstants.h"
#include <arpa/inet.h>
#include <string.h>

static inline NSString *NSGlobalRawHostKey(id value) {
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
static inline NSString *NSGlobalHostKey(id value) {
    if ([value isKindOfClass:NSString.class]) {
        NSString *host =
            [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([host hasPrefix:@"["] && [host hasSuffix:@"]"]) {
            host = [host substringWithRange:NSMakeRange(1, host.length - 2)];
        }
        NSRange scope = [host rangeOfString:@"%"];
        if (scope.location != NSNotFound) {
            NSString *address = [host substringToIndex:scope.location];
            struct in6_addr bytes;
            if (scope.location + 1 == host.length || inet_pton(AF_INET6, address.UTF8String, &bytes) != 1) {
                return nil;
            }
            value = address;
        }
    }
    NSString *key = NSGlobalRawHostKey(value);
    if ([key hasPrefix:@"ip:"]) {
        struct in6_addr bytes;
        if (inet_pton(AF_INET6, [key substringFromIndex:3].UTF8String, &bytes) == 1 &&
            IN6_IS_ADDR_V4MAPPED(&bytes)) {
            char text[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &bytes.s6_addr[12], text, sizeof(text));
            return [@"ip:" stringByAppendingString:@(text)];
        }
    }
    return key;
}
static inline NSString *NSMergeGlobalActions(NSString *left, NSString *right) {
    if (!left || [left isEqual:right]) {
        return right;
    }
    if ([left isEqual:@"allow"]) {
        return right;
    }
    if ([right isEqual:@"allow"]) {
        return left;
    }
    return @"block";
}
static inline NSString *NSGlobalInputHostKey(id value) {
    return NSGlobalHostKey(value);
}
static inline NSArray<NSString *> *NSGlobalDomainAliases(NSString *key) {
    if (![key hasPrefix:@"domain:"]) {
        return @[];
    }
    return @[ [key substringFromIndex:7] ];
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
static inline NSString *NSGlobalLocalPortKey(id value) {
    NSString *remoteKey = NSGlobalPortKey(value);
    return remoteKey ? [@"localPort:" stringByAppendingString:[remoteKey substringFromIndex:5]] : nil;
}
static inline BOOL NSValidGlobalMemberKey(id key) {
    if (![key isKindOfClass:NSString.class]) {
        return NO;
    }
    NSRange colon = [key rangeOfString:@":"];
    if (colon.location == NSNotFound) {
        return NO;
    }
    NSString *value = [key substringFromIndex:colon.location + 1];
    NSString *canonical = [key hasPrefix:@"localPort:"] ? NSGlobalLocalPortKey(value)
                          : [key hasPrefix:@"port:"]    ? NSGlobalPortKey(value)
                                                        : NSGlobalHostKey(value);
    return [key isEqual:canonical] || ([key hasPrefix:@"ip:"] && [key isEqual:NSGlobalRawHostKey(value)]);
}

// Custom rules store independent AND conditions; entries within a host/port group are OR conditions.
static inline NSArray *NSCustomGlobalRuleComponents(NSString *key) {
    if (![key hasPrefix:@"custom:"]) {
        return nil;
    }
    id parts = [NSJSONSerialization
        JSONObjectWithData:[[key substringFromIndex:7] dataUsingEncoding:NSUTF8StringEncoding]
                   options:0
                     error:NULL];
    if (![parts isKindOfClass:NSArray.class] || [parts count] != 4) {
        return nil;
    }
    id apps = parts[0];
    if (![apps isKindOfClass:NSString.class] && ![apps isKindOfClass:NSArray.class]) {
        return nil;
    }
    if ([apps isKindOfClass:NSArray.class]) {
        for (id identity in apps) {
            if (![identity isKindOfClass:NSString.class] || ![identity length]) {
                return nil;
            }
        }
    }
    for (NSUInteger index = 1; index < 4; index++) {
        if (![parts[index] isKindOfClass:NSString.class]) {
            return nil;
        }
    }
    return parts;
}
// Single-app keys retain their original representation for compatibility with 2.3.5.
// Display labels must never replace the exact OS identities stored here.
static inline NSArray<NSString *> *NSCustomGlobalRuleIdentities(NSArray *parts) {
    if (!parts) {
        return @[];
    }
    id apps = parts[0];
    return [apps isKindOfClass:NSArray.class] ? apps : [apps length] ? @[ apps ] : @[];
}
static inline NSString *NSCustomGlobalRuleKey(id identity, NSString *hosts, NSString *ports,
                                              NSString *protocol) {
    if ([identity isKindOfClass:NSArray.class]) {
        NSArray *apps =
            [[NSSet setWithArray:identity].allObjects sortedArrayUsingSelector:@selector(compare:)];
        identity = apps.count > 1 ? apps : apps.firstObject ?: @"";
    }
    NSData *data = [NSJSONSerialization
        dataWithJSONObject:@[ identity ?: @"", hosts ?: @"", ports ?: @"", protocol ?: @"any" ]
                   options:0
                     error:NULL];
    return data ? [@"custom:" stringByAppendingString:[[NSString alloc] initWithData:data
                                                                            encoding:NSUTF8StringEncoding]]
                : nil;
}
// A group remains one saved rule; only the filtering view expands its members.
static inline NSArray<NSString *> *NSGlobalRuleMembers(NSString *key) {
    NSArray *parts = NSCustomGlobalRuleComponents(key);
    if (parts) {
        NSMutableArray *members = [NSMutableArray new];
        for (NSUInteger index = 1; index <= 2; index++) {
            NSString *condition = parts[index];
            if (condition.length && ![condition hasPrefix:@"custom:"]) {
                [members addObjectsFromArray:NSGlobalRuleMembers(condition)];
            }
        }
        return members;
    }
    return [key hasPrefix:@"group:"] ? [[key substringFromIndex:6] componentsSeparatedByString:@","]
                                     : @[ key ];
}
static inline NSString *NSGlobalKeyFromMembers(NSArray<NSString *> *members) {
    NSArray *unique = [[NSSet setWithArray:members].allObjects sortedArrayUsingSelector:@selector(compare:)];
    return unique.count == 1 ? unique.firstObject
                             : [@"group:" stringByAppendingString:[unique componentsJoinedByString:@","]];
}
static inline BOOL NSValidGlobalRuleKey(id key) {
    if (![key isKindOfClass:NSString.class] || [key length] > NSMaximumDocumentBytes) {
        return NO;
    }
    if ([key hasPrefix:@"custom:"]) {
        NSArray *parts = NSCustomGlobalRuleComponents(key);
        NSArray *identities = NSCustomGlobalRuleIdentities(parts);
        if (!parts || identities.count > NSMaximumRules ||
            ![@[ @"any", @"tcp", @"udp" ] containsObject:parts[3]]) {
            return NO;
        }
        for (NSString *identity in identities) {
            if (identity.length > NSMaximumIdentityLength) {
                return NO;
            }
        }
        for (NSUInteger index = 1; index <= 2; index++) {
            NSString *condition = parts[index];
            if (!condition.length) {
                continue;
            }
            if ([condition hasPrefix:@"custom:"] || !NSValidGlobalRuleKey(condition)) {
                return NO;
            }
            for (NSString *member in NSGlobalRuleMembers(condition)) {
                BOOL host = [member hasPrefix:@"ip:"] || [member hasPrefix:@"domain:"];
                if (host != (index == 1)) {
                    return NO;
                }
            }
        }
        return NSGlobalRuleMembers(key).count <= NSMaximumRules &&
               [key isEqual:NSCustomGlobalRuleKey(parts[0], parts[1], parts[2], parts[3])];
    }
    if (![key hasPrefix:@"group:"]) {
        return NSValidGlobalMemberKey(key);
    }
    NSArray *members = NSGlobalRuleMembers(key);
    if (members.count < 2 || members.count > NSMaximumRules) {
        return NO;
    }
    NSString *kind = nil;
    for (NSString *member in members) {
        if (!NSValidGlobalMemberKey(member)) {
            return NO;
        }
        NSString *memberKind = [member hasPrefix:@"localPort:"] ? @"localPort"
                               : [member hasPrefix:@"port:"]    ? @"port"
                                                                : @"host";
        if (kind && ![kind isEqual:memberKind]) {
            return NO;
        }
        kind = memberKind;
    }
    return [key isEqual:NSGlobalKeyFromMembers(members)];
}
static inline NSDictionary *NSExpandedGlobalRules(NSDictionary *rules) {
    NSMutableDictionary *expanded = [NSMutableDictionary new];
    if (![rules isKindOfClass:NSDictionary.class]) {
        return expanded;
    }
    for (NSString *key in rules) {
        // Mutations are validated before publication; do not crash while pruning
        // their DNS cache if a candidate document contains a malformed rule.
        if (!NSValidGlobalRuleKey(key) || [key hasPrefix:@"custom:"] ||
            ![rules[key] isKindOfClass:NSString.class]) {
            continue;
        }
        for (NSString *member in NSGlobalRuleMembers(key)) {
            NSString *canonical =
                [member hasPrefix:@"ip:"] ? NSGlobalHostKey([member substringFromIndex:3]) : member;
            expanded[canonical] = NSMergeGlobalActions(expanded[canonical], rules[key]);
        }
    }
    return expanded;
}
// Used only for DNS resolution and missing endpoint checks, never for rule decisions.
static inline NSDictionary *NSGlobalRuleConditions(NSDictionary *rules) {
    NSMutableDictionary *conditions = [NSExpandedGlobalRules(rules) mutableCopy];
    if (![rules isKindOfClass:NSDictionary.class]) {
        return conditions;
    }
    for (NSString *key in rules) {
        if (!NSValidGlobalRuleKey(key) || ![key hasPrefix:@"custom:"] ||
            ![rules[key] isKindOfClass:NSString.class]) {
            continue;
        }
        for (NSString *member in NSGlobalRuleMembers(key)) {
            conditions[member] = NSMergeGlobalActions(conditions[member], rules[key]);
        }
    }
    return conditions;
}
static inline NSString *NSGlobalRuleInputText(NSString *key) {
    NSMutableArray *values = [NSMutableArray new];
    for (NSString *member in NSGlobalRuleMembers(key)) {
        [values addObject:[member substringFromIndex:[member rangeOfString:@":"].location + 1]];
    }
    return [values componentsJoinedByString:@", "];
}
static inline NSString *NSGlobalInputRuleKey(id value, BOOL port, BOOL local) {
    if (![value isKindOfClass:NSString.class] || [value length] > NSMaximumDocumentBytes) {
        return nil;
    }
    NSMutableOrderedSet *members = [NSMutableOrderedSet new];
    for (NSString *part in [value componentsSeparatedByString:@","]) {
        NSString *entry =
            [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSArray *ends = [entry componentsSeparatedByString:@"-"];
        // A hyphen is also valid in a domain. Only numeric endpoints denote a range.
        uint8_t first[16] = {0}, last[16] = {0};
        int family = 0;
        if (!port && ends.count == 2) {
            NSString *start =
                [ends[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSString *finish =
                [ends[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            for (NSNumber *candidate in @[ @(AF_INET), @(AF_INET6) ]) {
                if (inet_pton(candidate.intValue, start.UTF8String, first) == 1 &&
                    inet_pton(candidate.intValue, finish.UTF8String, last) == 1) {
                    family = candidate.intValue;
                    break;
                }
            }
        }
        if (family) {
            size_t length = family == AF_INET ? 4 : 16;
            if (memcmp(first, last, length) > 0) {
                return nil;
            }
            for (NSUInteger count = 0;; count++) {
                if (count == NSMaximumRules) {
                    return nil;
                }
                char text[INET6_ADDRSTRLEN];
                inet_ntop(family, first, text, sizeof(text));
                [members addObject:NSGlobalHostKey(@(text))];
                if (memcmp(first, last, length) == 0) {
                    break;
                }
                for (NSInteger byte = (NSInteger)length - 1; byte >= 0; byte--) {
                    if (++first[byte] != 0) {
                        break;
                    }
                }
            }
        } else {
            NSString *key = port ? (local ? NSGlobalLocalPortKey(entry) : NSGlobalPortKey(entry))
                                 : NSGlobalInputHostKey(entry);
            if (!key) {
                return nil;
            }
            [members addObject:key];
        }
        if (members.count > NSMaximumRules) {
            return nil;
        }
    }
    return members.count ? NSGlobalKeyFromMembers(members.array) : nil;
}
