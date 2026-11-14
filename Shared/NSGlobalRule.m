#import "NSGlobalRule.h"
#import "NSRuleChoices.h"
#import "NSValidation.h"
#import "NSDNSCache.h"
#include <arpa/inet.h>
#include <string.h>

static NSString *NSTrim(NSString *text) {
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
static NSString *NSAddressText(int family, const uint8_t *bytes) {
    char text[INET6_ADDRSTRLEN];
    return inet_ntop(family == 4 ? AF_INET : AF_INET6, bytes, text, sizeof(text)) ? @(text) : nil;
}
static int NSAddressBytes(id value, uint8_t *bytes) {
    if (!NSBoundedString(value, 256, YES)) {
        return 0;
    }
    NSString *text = NSTrim(value);
    if ([text hasPrefix:@"["] && [text hasSuffix:@"]"]) {
        text = [text substringWithRange:NSMakeRange(1, text.length - 2)];
    }
    NSRange scope = [text rangeOfString:@"%"];
    if (scope.location != NSNotFound) {
        NSString *zone = [text substringFromIndex:scope.location + 1];
        NSCharacterSet *bad = [[NSCharacterSet
            characterSetWithCharactersInString:
                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-"] invertedSet];
        text = [text substringToIndex:scope.location];
        if (!zone.length || [zone rangeOfCharacterFromSet:bad].location != NSNotFound ||
            inet_pton(AF_INET6, text.UTF8String, bytes) != 1) {
            return 0;
        }
        return 6;
    }
    if (inet_pton(AF_INET, text.UTF8String, bytes) == 1) {
        return 4;
    }
    return inet_pton(AF_INET6, text.UTF8String, bytes) == 1 ? 6 : 0;
}
NSString *NSGlobalHostKey(id value) {
    if (!NSBoundedString(value, 256, YES)) {
        return nil;
    }
    NSString *host = NSTrim(value).lowercaseString;
    uint8_t bytes[16] = {0};
    int family = NSAddressBytes(host, bytes);
    if (family) {
        struct in6_addr mapped;
        memcpy(&mapped, bytes, 16);
        if (family == 6 && IN6_IS_ADDR_V4MAPPED(&mapped)) {
            return [@"ip:" stringByAppendingString:NSAddressText(4, bytes + 12)];
        }
        return [@"ip:" stringByAppendingString:NSAddressText(family, bytes)];
    }
    if ([host hasSuffix:@"."]) {
        host = [host substringToIndex:host.length - 1];
    }
    if (!host.length || host.length > 253 ||
        [host rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location == NSNotFound) {
        return nil;
    }
    NSCharacterSet *invalid = [[NSCharacterSet
        characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-"] invertedSet];
    for (NSString *label in [host componentsSeparatedByString:@"."]) {
        if (!label.length || label.length > 63 || [label hasPrefix:@"-"] || [label hasSuffix:@"-"] ||
            [label rangeOfCharacterFromSet:invalid].location != NSNotFound) {
            return nil;
        }
    }
    return [@"domain:" stringByAppendingString:host];
}
static BOOL NSParseDecimal(NSString *text, NSUInteger maximum, NSUInteger *number) {
    if (![text isKindOfClass:NSString.class] || !text.length || text.length > 5 ||
        [text rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"]
                                          invertedSet]]
                .location != NSNotFound ||
        text.integerValue > (NSInteger)maximum) {
        return NO;
    }
    *number = text.integerValue;
    return YES;
}
NSString *NSGlobalPortKey(id value) {
    NSUInteger port;
    return [value isKindOfClass:NSString.class] && NSParseDecimal(NSTrim(value), 65535, &port) && port
               ? [NSString stringWithFormat:@"port:%lu", (unsigned long)port]
               : nil;
}
NSString *NSGlobalLocalPortKey(id value) {
    NSString *key = NSGlobalPortKey(value);
    return key ? [@"localPort:" stringByAppendingString:[key substringFromIndex:5]] : nil;
}
NSDictionary *NSCanonicalConnectionDestination(NSDictionary *destination) {
    NSMutableDictionary *result = [NSMutableDictionary new];
    for (NSString *field in @[ @"domain", @"address" ]) {
        NSString *key = NSGlobalHostKey(destination[field]);
        NSString *prefix = [field isEqual:@"domain"] ? @"domain:" : @"ip:";
        if ([key hasPrefix:prefix]) {
            result[field] = [key substringFromIndex:prefix.length];
        }
    }
    for (NSString *field in @[ @"port", @"localPort", @"protocol" ]) {
        id value = destination[field];
        if (value && NSValidDestination(@{field : value})) {
            result[field] = [field isEqual:@"protocol"] ? value : @([value integerValue]);
        }
    }
    return [result copy];
}
BOOL NSGlobalActionIsAllow(NSString *action) {
    return [@[ @"allow", @"allow-inbound", @"allow-outbound" ] containsObject:action ?: @""];
}
NSString *NSMergeGlobalActions(NSString *left, NSString *right) {
    if (!left || [left isEqual:right]) {
        return right;
    }
    return NSGlobalActionIsAllow(left) && NSGlobalActionIsAllow(right) ? @"allow" : @"block";
}
NSString *NSGlobalCoverage(NSString *action) {
    return [action hasSuffix:@"-inbound"]    ? @"incoming"
           : [action hasSuffix:@"-outbound"] ? @"outgoing"
                                             : @"both";
}
static BOOL NSKeys(id object, NSArray *keys) {
    return [object isKindOfClass:NSDictionary.class] &&
           [[NSSet setWithArray:[object allKeys]] isEqual:[NSSet setWithArray:keys]];
}
static NSDictionary *NSInterval(int family, const uint8_t *first, const uint8_t *last) {
    return @{
        @"family" : @(family),
        @"first" : NSAddressText(family, first),
        @"last" : NSAddressText(family, last)
    };
}
// Split the mapped IPv6 block into IPv4, including networks which contain it.
static NSArray *NSAddressIntervals(int family, const uint8_t *first, const uint8_t *last) {
    size_t size = family == 4 ? 4 : 16;
    if (memcmp(first, last, size) > 0) {
        return nil;
    }
    uint8_t mappedFirst[16] = {0}, mappedLast[16] = {0};
    mappedFirst[10] = mappedLast[10] = mappedFirst[11] = mappedLast[11] = 255;
    memset(mappedLast + 12, 255, 4);
    if (family == 4 || memcmp(last, mappedFirst, 16) < 0 || memcmp(first, mappedLast, 16) > 0) {
        return @[ NSInterval(family, first, last) ];
    }
    NSMutableArray *result = [NSMutableArray new];
    if (memcmp(first, mappedFirst, 16) < 0) {
        uint8_t end[16];
        memcpy(end, mappedFirst, 16);
        for (NSInteger i = 15; i >= 0 && !end[i]--; i--) {
        }
        [result addObject:NSInterval(6, first, end)];
    }
    const uint8_t *start = memcmp(first, mappedFirst, 16) > 0 ? first : mappedFirst;
    const uint8_t *end = memcmp(last, mappedLast, 16) < 0 ? last : mappedLast;
    [result addObject:NSInterval(4, start + 12, end + 12)];
    if (memcmp(last, mappedLast, 16) > 0) {
        uint8_t startBytes[16];
        memcpy(startBytes, mappedLast, 16);
        for (NSInteger i = 15; i >= 0 && ++startBytes[i] == 0; i--) {
        }
        [result addObject:NSInterval(6, startBytes, last)];
    }
    return result;
}
static NSArray *NSParseAddressInput(NSString *text) {
    uint8_t first[16] = {0}, last[16] = {0};
    NSArray *prefix = [text componentsSeparatedByString:@"/"];
    if (prefix.count == 2) {
        int family = NSAddressBytes(prefix[0], first);
        NSUInteger bits;
        if (!family || !NSParseDecimal(prefix[1], family == 4 ? 32 : 128, &bits)) {
            return nil;
        }
        size_t size = family == 4 ? 4 : 16;
        for (NSUInteger i = 0; i < size; i++) {
            uint8_t mask = bits >= 8 ? 255 : bits ? (uint8_t)(255 << (8 - bits)) : 0;
            first[i] &= mask;
            last[i] = first[i] | (uint8_t)~mask;
            bits = bits >= 8 ? bits - 8 : 0;
        }
        return NSAddressIntervals(family, first, last);
    }
    if (prefix.count != 1) {
        return nil;
    }
    int family = NSAddressBytes(text, first);
    if (family) {
        return NSAddressIntervals(family, first, first);
    }
    NSArray *ends = [text componentsSeparatedByString:@"-"];
    if (ends.count != 2 || !(family = NSAddressBytes(NSTrim(ends[0]), first)) ||
        NSAddressBytes(NSTrim(ends[1]), last) != family) {
        return nil;
    }
    return NSAddressIntervals(family, first, last);
}
static NSData *NSIntervalBytes(NSDictionary *interval, NSString *field) {
    uint8_t bytes[16] = {0};
    int family = NSAddressBytes(interval[field], bytes);
    return family ? [NSData dataWithBytes:bytes length:family == 4 ? 4 : 16] : nil;
}
static NSComparisonResult NSByteCompare(NSData *left, NSData *right) {
    int order = memcmp(left.bytes, right.bytes, left.length);
    return order < 0 ? NSOrderedAscending : order > 0 ? NSOrderedDescending : NSOrderedSame;
}
static BOOL NSAdjacent(NSData *leftEnd, NSData *rightStart) {
    uint8_t bytes[16];
    memcpy(bytes, leftEnd.bytes, leftEnd.length);
    for (NSInteger i = (NSInteger)leftEnd.length - 1; i >= 0; i--) {
        if (++bytes[i]) {
            return memcmp(bytes, rightStart.bytes, leftEnd.length) == 0;
        }
    }
    return NO;
}
static NSArray *NSNormalizeDestinations(id input) {
    if (![input isKindOfClass:NSArray.class] || [input count] > NSMaximumRules) {
        return nil;
    }
    NSMutableArray *items = [NSMutableArray new];
    for (id item in input) {
        if (![item isKindOfClass:NSDictionary.class] || ![item count] || [item count] > 2 ||
            (!item[@"domain"] && !item[@"address"])) {
            return nil;
        }
        for (id key in item) {
            if (![@[ @"domain", @"address" ] containsObject:key]) {
                return nil;
            }
        }
        NSString *domain = nil;
        if (item[@"domain"]) {
            NSString *key = NSGlobalHostKey(item[@"domain"]);
            if (![key hasPrefix:@"domain:"]) {
                return nil;
            }
            domain = [key substringFromIndex:7];
        }
        NSArray *intervals = @[];
        if (item[@"address"]) {
            NSDictionary *ip = item[@"address"];
            if (!NSKeys(ip, @[ @"family", @"first", @"last" ]) || !NSUnsignedInteger(ip[@"family"], 6) ||
                ![@[ @4, @6 ] containsObject:ip[@"family"]]) {
                return nil;
            }
            uint8_t first[16] = {0}, last[16] = {0};
            int family = [ip[@"family"] intValue];
            if (NSAddressBytes(ip[@"first"], first) != family ||
                NSAddressBytes(ip[@"last"], last) != family ||
                !(intervals = NSAddressIntervals(family, first, last))) {
                return nil;
            }
        }
        if (!intervals.count) {
            [items addObject:@{@"domain" : domain}];
        }
        for (NSDictionary *interval in intervals) {
            NSMutableDictionary *entry = [@{@"address" : interval} mutableCopy];
            if (domain) {
                entry[@"domain"] = domain;
            }
            [items addObject:entry];
        }
    }
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult domain = [a[@"domain"] ?: @"" compare:b[@"domain"] ?: @""];
        if (domain != NSOrderedSame) {
            return domain;
        }
        if (!a[@"address"] || !b[@"address"]) {
            return a[@"address"] ? NSOrderedDescending : b[@"address"] ? NSOrderedAscending : NSOrderedSame;
        }
        NSComparisonResult family = [a[@"address"][@"family"] compare:b[@"address"][@"family"]];
        if (family != NSOrderedSame) {
            return family;
        }
        NSComparisonResult first =
            NSByteCompare(NSIntervalBytes(a[@"address"], @"first"), NSIntervalBytes(b[@"address"], @"first"));
        return first != NSOrderedSame ? first
                                      : NSByteCompare(NSIntervalBytes(a[@"address"], @"last"),
                                                      NSIntervalBytes(b[@"address"], @"last"));
    }];
    NSMutableArray *merged = [NSMutableArray new];
    for (NSDictionary *item in items) {
        NSDictionary *previous = merged.lastObject;
        BOOL sameDomain = [(previous[@"domain"] ?: @"") isEqual:item[@"domain"] ?: @""];
        if (previous && sameDomain) {
            if (!previous[@"address"]) {
                continue;
            }
            NSDictionary *a = previous[@"address"], *b = item[@"address"];
            if ([a[@"family"] isEqual:b[@"family"]] &&
                (NSByteCompare(NSIntervalBytes(b, @"first"), NSIntervalBytes(a, @"last")) !=
                     NSOrderedDescending ||
                 NSAdjacent(NSIntervalBytes(a, @"last"), NSIntervalBytes(b, @"first")))) {
                NSString *end = NSByteCompare(NSIntervalBytes(a, @"last"), NSIntervalBytes(b, @"last")) ==
                                        NSOrderedAscending
                                    ? b[@"last"]
                                    : a[@"last"];
                NSMutableDictionary *entry = [previous mutableCopy];
                entry[@"address"] = @{@"family" : a[@"family"], @"first" : a[@"first"], @"last" : end};
                merged[merged.count - 1] = entry;
                continue;
            }
        }
        [merged addObject:item];
    }
    return merged.count <= NSMaximumRules ? [merged copy] : nil;
}
NSArray *NSGlobalParseDestinations(NSString *text) {
    if (!NSBoundedString(text, NSMaximumDocumentBytes, NO)) {
        return nil;
    }
    if (!NSTrim(text).length) {
        return @[];
    }
    NSMutableArray *result = [NSMutableArray new];
    for (NSString *part in [text componentsSeparatedByString:@","]) {
        NSString *domain = nil;
        NSArray *addresses = nil;
        NSArray *fields = [part componentsSeparatedByString:@"&"];
        if (fields.count > 2) {
            return nil;
        }
        for (NSString *field in fields) {
            NSString *value = NSTrim(field);
            if (!value.length) {
                return nil;
            }
            NSArray *intervals = NSParseAddressInput(value);
            NSString *key = intervals ? nil : NSGlobalHostKey(value);
            if (intervals) {
                if (addresses) {
                    return nil;
                }
                addresses = intervals;
            } else if ([key hasPrefix:@"domain:"] && !domain) {
                domain = [key substringFromIndex:7];
            } else {
                return nil;
            }
        }
        if (!addresses) {
            [result addObject:@{@"domain" : domain}];
        }
        for (NSDictionary *address in addresses) {
            NSMutableDictionary *entry = [@{@"address" : address} mutableCopy];
            if (domain) {
                entry[@"domain"] = domain;
            }
            [result addObject:entry];
        }
        if (result.count > NSMaximumRules) {
            return nil;
        }
    }
    return NSNormalizeDestinations(result);
}
static NSArray *NSNormalizePorts(id ports) {
    if (![ports isKindOfClass:NSArray.class] || [ports count] > NSMaximumRules) {
        return nil;
    }
    for (id interval in ports) {
        if (![interval isKindOfClass:NSArray.class] || [interval count] != 2 ||
            !NSUnsignedInteger(interval[0], 65535) || ![interval[0] unsignedIntegerValue] ||
            !NSUnsignedInteger(interval[1], 65535) ||
            [interval[0] compare:interval[1]] == NSOrderedDescending) {
            return nil;
        }
    }
    NSArray *sorted = [ports sortedArrayUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        NSComparisonResult first = [a[0] compare:b[0]];
        return first != NSOrderedSame ? first : [a[1] compare:b[1]];
    }];
    NSMutableArray *merged = [NSMutableArray new];
    for (NSArray *item in sorted) {
        NSArray *previous = merged.lastObject;
        if (previous && [item[0] unsignedIntegerValue] <= [previous[1] unsignedIntegerValue] + 1) {
            merged[merged.count - 1] =
                @[ previous[0], @(MAX([previous[1] integerValue], [item[1] integerValue])) ];
        } else {
            [merged addObject:item];
        }
    }
    return [merged copy];
}
NSArray *NSGlobalParsePorts(NSString *text) {
    if (!NSBoundedString(text, NSMaximumDocumentBytes, NO)) {
        return nil;
    }
    if (!NSTrim(text).length) {
        return @[];
    }
    NSMutableArray *result = [NSMutableArray new];
    for (NSString *part in [text componentsSeparatedByString:@","]) {
        NSArray *ends = [NSTrim(part) componentsSeparatedByString:@"-"];
        NSUInteger first, last;
        if (ends.count > 2 || !NSParseDecimal(NSTrim(ends[0]), 65535, &first) || !first ||
            !NSParseDecimal(NSTrim(ends.lastObject), 65535, &last) || last < first) {
            return nil;
        }
        [result addObject:@[ @(first), @(last) ]];
        if (result.count > NSMaximumRules) {
            return nil;
        }
    }
    return NSNormalizePorts(result);
}
NSString *NSGlobalDestinationsText(NSArray *destinations) {
    NSMutableArray *parts = [NSMutableArray new];
    for (NSDictionary *item in destinations) {
        NSDictionary *address = item[@"address"];
        NSString *ip = !address ? nil
                       : [address[@"first"] isEqual:address[@"last"]]
                           ? address[@"first"]
                           : [NSString stringWithFormat:@"%@-%@", address[@"first"], address[@"last"]];
        NSString *domain = item[@"domain"];
        [parts addObject:domain && ip ? [NSString stringWithFormat:@"%@ & %@", domain, ip] : domain ?: ip];
    }
    return [parts componentsJoinedByString:@", "];
}
NSString *NSGlobalPortsText(NSArray *ports) {
    NSMutableArray *parts = [NSMutableArray new];
    for (NSArray *item in ports) {
        [parts addObject:[item[0] isEqual:item[1]] ? [item[0] stringValue]
                                                   : [NSString stringWithFormat:@"%@-%@", item[0], item[1]]];
    }
    return [parts componentsJoinedByString:@", "];
}
NSUInteger NSGlobalConditionCost(NSDictionary *condition) {
    return MAX((NSUInteger)1, [condition[@"identities"] count] + [condition[@"destinations"] count] +
                                  [condition[@"remotePorts"] count] + [condition[@"localPorts"] count] +
                                  [condition[@"protocols"] count]);
}
NSDictionary *NSGlobalCondition(NSArray *identities, NSArray *destinations, NSArray *remotePorts,
                                NSArray *localPorts, NSArray *protocols, NSString *direction,
                                BOOL resolveDomains) {
    if (![identities isKindOfClass:NSArray.class] || identities.count > NSMaximumRules ||
        ![protocols isKindOfClass:NSArray.class] || protocols.count > 3 ||
        ![@[ @"incoming", @"outgoing", @"both" ] containsObject:direction ?: @""]) {
        return nil;
    }
    for (id identity in identities) {
        if (!NSBoundedString(identity, NSMaximumIdentityLength, YES)) {
            return nil;
        }
    }
    for (id protocol in protocols) {
        if (![@[ @"tcp", @"udp", @"other" ] containsObject:protocol]) {
            return nil;
        }
    }
    NSArray *hosts = NSNormalizeDestinations(destinations), *remote = NSNormalizePorts(remotePorts),
            *local = NSNormalizePorts(localPorts);
    if (!hosts || !remote || !local) {
        return nil;
    }
    NSDictionary *result = @{
        @"identities" :
            [[NSSet setWithArray:identities].allObjects sortedArrayUsingSelector:@selector(compare:)],
        @"destinations" : hosts,
        @"remotePorts" : remote,
        @"localPorts" : local,
        @"protocols" :
            [[NSSet setWithArray:protocols].allObjects sortedArrayUsingSelector:@selector(compare:)],
        @"direction" : direction,
        @"resolveDomains" : @(resolveDomains)
    };
    return NSGlobalConditionCost(result) <= NSMaximumRules ? result : nil;
}
static NSDictionary *NSCheckedCondition(id condition) {
    if (!NSKeys(condition,
                @[
                    @"identities", @"destinations", @"remotePorts", @"localPorts", @"protocols", @"direction",
                    @"resolveDomains"
                ]) ||
        !NSBoolean(condition[@"resolveDomains"])) {
        return nil;
    }
    NSDictionary *normalized =
        NSGlobalCondition(condition[@"identities"], condition[@"destinations"], condition[@"remotePorts"],
                          condition[@"localPorts"], condition[@"protocols"], condition[@"direction"],
                          [condition[@"resolveDomains"] boolValue]);
    return [normalized isEqual:condition] ? normalized : nil;
}
NSString *NSGlobalRuleKey(NSDictionary *condition) {
    NSDictionary *checked = NSCheckedCondition(condition);
    NSData *data = checked ? [NSJSONSerialization dataWithJSONObject:checked
                                                             options:NSJSONWritingSortedKeys
                                                               error:NULL]
                           : nil;
    return data ? [@"condition:" stringByAppendingString:[[NSString alloc] initWithData:data
                                                                               encoding:NSUTF8StringEncoding]]
                : nil;
}
NSDictionary *NSGlobalRuleCondition(NSString *key) {
    if (![key isKindOfClass:NSString.class] || ![key hasPrefix:@"condition:"] ||
        key.length > NSMaximumDocumentBytes) {
        return nil;
    }
    id condition = [NSJSONSerialization
        JSONObjectWithData:[[key substringFromIndex:10] dataUsingEncoding:NSUTF8StringEncoding]
                   options:0
                     error:NULL];
    return [key isEqual:NSGlobalRuleKey(condition)] ? condition : nil;
}
BOOL NSValidGlobalRuleKey(id key) {
    return NSGlobalRuleCondition(key) != nil;
}
BOOL NSGlobalCoverageAgrees(NSString *key, NSString *action) {
    return [NSDirectionRuleValues() containsObject:action ?: @""] &&
           [NSGlobalRuleCondition(key)[@"direction"] isEqual:NSGlobalCoverage(action)];
}
NSString *NSExactGlobalRuleKey(NSArray<NSString *> *identities, NSDictionary *destination,
                               NSString *coverage) {
    NSDictionary *canonical = NSCanonicalConnectionDestination(destination);
    if (canonical.count != destination.count) {
        return nil;
    }
    NSMutableArray *fields = [NSMutableArray new];
    if (canonical[@"domain"]) {
        [fields addObject:canonical[@"domain"]];
    }
    if (canonical[@"address"]) {
        [fields addObject:canonical[@"address"]];
    }
    NSArray *hosts = NSGlobalParseDestinations([fields componentsJoinedByString:@" & "]);
    NSArray *remote = canonical[@"port"] ? @[ @[ canonical[@"port"], canonical[@"port"] ] ] : @[];
    NSArray *local =
        canonical[@"localPort"] ? @[ @[ canonical[@"localPort"], canonical[@"localPort"] ] ] : @[];
    NSArray *protocols = canonical[@"protocol"] ? @[ canonical[@"protocol"] ] : @[];
    return NSGlobalRuleKey(NSGlobalCondition(identities, hosts, remote, local, protocols, coverage, NO));
}
NSDictionary *NSCompileGlobalCondition(NSDictionary *condition) {
    if (!NSCheckedCondition(condition)) {
        return nil;
    }
    NSMutableDictionary *compiled = [condition mutableCopy];
    compiled[@"identities"] = [NSSet setWithArray:condition[@"identities"]];
    compiled[@"protocols"] = [NSSet setWithArray:condition[@"protocols"]];
    NSMutableArray *destinations = [NSMutableArray new];
    for (NSDictionary *item in condition[@"destinations"]) {
        NSMutableDictionary *entry = [item mutableCopy];
        if (item[@"address"]) {
            entry[@"address"] = @{
                @"family" : item[@"address"][@"family"],
                @"first" : NSIntervalBytes(item[@"address"], @"first"),
                @"last" : NSIntervalBytes(item[@"address"], @"last")
            };
        }
        [destinations addObject:entry];
    }
    compiled[@"destinations"] = [destinations copy];
    return [compiled copy];
}
static BOOL NSSetsIntersect(NSSet *left, NSSet *right) {
    return !left.count || !right.count || [left intersectsSet:right];
}
static BOOL NSPortsIntersect(NSArray *left, NSArray *right) {
    if (!left.count || !right.count) {
        return YES;
    }
    NSUInteger i = 0, j = 0;
    while (i < left.count && j < right.count) {
        NSArray *a = left[i], *b = right[j];
        if ([a[1] compare:b[0]] == NSOrderedAscending) {
            i++;
        } else if ([b[1] compare:a[0]] == NSOrderedAscending) {
            j++;
        } else {
            return YES;
        }
    }
    return NO;
}
static BOOL NSAddressesIntersect(NSDictionary *left, NSDictionary *right) {
    return !left || !right ||
           ([left[@"family"] isEqual:right[@"family"]] &&
            NSByteCompare(left[@"first"], right[@"last"]) != NSOrderedDescending &&
            NSByteCompare(right[@"first"], left[@"last"]) != NSOrderedDescending);
}
BOOL NSGlobalConditionsIntersect(NSDictionary *left, NSDictionary *right) {
    if (!NSSetsIntersect(left[@"identities"], right[@"identities"]) ||
        (![left[@"direction"] isEqual:@"both"] && ![right[@"direction"] isEqual:@"both"] &&
         ![left[@"direction"] isEqual:right[@"direction"]]) ||
        !NSSetsIntersect(left[@"protocols"], right[@"protocols"]) ||
        !NSPortsIntersect(left[@"remotePorts"], right[@"remotePorts"]) ||
        !NSPortsIntersect(left[@"localPorts"], right[@"localPorts"])) {
        return NO;
    }
    NSArray *a = left[@"destinations"], *b = right[@"destinations"];
    if (!a.count || !b.count) {
        return YES;
    }
    for (NSDictionary *x in a) {
        for (NSDictionary *y in b) {
            if (x[@"domain"] && y[@"domain"] && ![x[@"domain"] isEqual:y[@"domain"]]) {
                continue;
            }
            if (NSAddressesIntersect(x[@"address"], y[@"address"])) {
                return YES;
            }
        }
    }
    return NO;
}
static BOOL NSRuleError(NSString *message, NSString *conflict, NSError **error) {
    if (error) {
        NSMutableDictionary *info = [@{NSLocalizedDescriptionKey : message} mutableCopy];
        if (conflict) {
            info[@"conflictingRule"] = conflict;
        }
        *error = [NSError errorWithDomain:@"NetShield2.Policy" code:2 userInfo:info];
    }
    return NO;
}
static NSString *const NSOverlapMessage = @"This rule overlaps an existing global rule. Edit or merge the "
                                          @"existing rule instead of saving a duplicate.";
NSArray *NSCompileGlobalRules(NSDictionary *rules, NSError **error) {
    if (![rules isKindOfClass:NSDictionary.class] || rules.count > NSMaximumRules) {
        NSRuleError(@"Invalid global rule collection.", nil, error);
        return nil;
    }
    for (id key in rules) {
        if (![key isKindOfClass:NSString.class]) {
            NSRuleError(@"Invalid global rule key.", nil, error);
            return nil;
        }
    }
    NSMutableArray *compiled = [NSMutableArray new];
    NSUInteger cost = 0;
    for (NSString *key in [rules.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *condition = NSGlobalRuleCondition(key);
        if (!condition || ![NSDirectionRuleValues() containsObject:rules[key]] ||
            ![condition[@"direction"] isEqual:NSGlobalCoverage(rules[key])] ||
            (cost += NSGlobalConditionCost(condition)) > NSMaximumRules) {
            NSRuleError(@"Invalid global rule or predicate capacity exceeded.", key, error);
            return nil;
        }
        NSMutableDictionary *rule = [NSCompileGlobalCondition(condition) mutableCopy];
        for (NSDictionary *other in compiled) {
            if (NSGlobalConditionsIntersect(rule, other)) {
                NSRuleError(NSOverlapMessage, other[@"key"], error);
                return nil;
            }
        }
        rule[@"key"] = [key copy];
        rule[@"action"] = [rules[key] copy];
        [compiled addObject:[rule copy]];
    }
    return [compiled copy];
}
BOOL NSValidateGlobalRuleChange(NSDictionary *rules, NSString *key, NSString *action, NSString *original,
                                NSError **error) {
    NSDictionary *condition = NSGlobalRuleCondition(key);
    if (!condition || ![NSDirectionRuleValues() containsObject:action ?: @""] ||
        ![condition[@"direction"] isEqual:NSGlobalCoverage(action)]) {
        return NSRuleError(@"Invalid rule conditions or direction/action mismatch.", nil, error);
    }
    if (original && !rules[original]) {
        return NSRuleError(@"The original rule was removed. Reopen the editor and try again.", nil, error);
    }
    NSArray *existing = NSCompileGlobalRules(rules, error);
    if (!existing) {
        return NO;
    }
    NSDictionary *compiled = NSCompileGlobalCondition(condition);
    for (NSDictionary *other in existing) {
        if ([other[@"key"] isEqual:original]) {
            continue;
        }
        if (NSGlobalConditionsIntersect(compiled, other)) {
            return NSRuleError(NSOverlapMessage, other[@"key"], error);
        }
    }
    return YES;
}
NSDictionary *NSGlobalRuleConditions(NSDictionary *rules) {
    NSMutableDictionary *domains = [NSMutableDictionary new];
    if (![rules isKindOfClass:NSDictionary.class]) {
        return domains;
    }
    for (NSString *key in rules) {
        NSDictionary *condition = NSGlobalRuleCondition(key);
        if (!condition || ![condition[@"resolveDomains"] boolValue] ||
            ![NSDirectionRuleValues() containsObject:rules[key]]) {
            continue;
        }
        for (NSDictionary *host in condition[@"destinations"]) {
            // Tuples with an address never use DNS expansion.
            if (host[@"domain"] && !host[@"address"]) {
                NSString *domain = [@"domain:" stringByAppendingString:host[@"domain"]];
                domains[domain] = NSMergeGlobalActions(domains[domain], rules[key]);
            }
        }
    }
    return [domains copy];
}
static NSGlobalMatch NSMatchPorts(NSArray *ports, id value) {
    if (!ports.count) {
        return NSGlobalMatched;
    }
    if (!value) {
        return NSGlobalMissingEndpoints;
    }
    for (NSArray *interval in ports) {
        if ([interval[0] compare:value] != NSOrderedDescending &&
            [interval[1] compare:value] != NSOrderedAscending) {
            return NSGlobalMatched;
        }
    }
    return NSGlobalMismatch;
}
NSGlobalMatch NSMatchGlobalCondition(NSDictionary *compiled, NSString *identity, NSFlowDirection direction,
                                     NSDictionary *destination, BOOL allow, NSDictionary *document) {
    NSSet *identities = compiled[@"identities"], *protocols = compiled[@"protocols"];
    if ((identities.count && ![identities containsObject:identity ?: @""]) ||
        ([compiled[@"direction"] isEqual:@"incoming"] && direction != NSFlowDirectionInbound) ||
        ([compiled[@"direction"] isEqual:@"outgoing"] && direction != NSFlowDirectionOutbound) ||
        (protocols.count && ![protocols containsObject:destination[@"protocol"] ?: @""])) {
        return NSGlobalMismatch;
    }
    NSDictionary *canonical = NSCanonicalConnectionDestination(destination);
    NSGlobalMatch remote = NSMatchPorts(compiled[@"remotePorts"], canonical[@"port"]),
                  local = NSMatchPorts(compiled[@"localPorts"], canonical[@"localPort"]);
    if (remote == NSGlobalMismatch || local == NSGlobalMismatch) {
        return NSGlobalMismatch;
    }
    BOOL missingPort = remote == NSGlobalMissingEndpoints || local == NSGlobalMissingEndpoints;
    NSArray *hosts = compiled[@"destinations"];
    if (!hosts.count) {
        return missingPort ? NSGlobalMissingEndpoints : NSGlobalMatched;
    }
    NSString *domain = canonical[@"domain"], *address = canonical[@"address"];
    uint8_t bytes[16] = {0};
    int family = NSAddressBytes(address, bytes);
    NSData *actual = family ? [NSData dataWithBytes:bytes length:family == 4 ? 4 : 16] : nil;
    BOOL possible = NO;
    for (NSDictionary *host in hosts) {
        BOOL missing = missingPort;
        NSDictionary *ip = host[@"address"];
        if (ip) {
            if (actual && (![ip[@"family"] isEqual:@(family)] ||
                           NSByteCompare(actual, ip[@"first"]) == NSOrderedAscending ||
                           NSByteCompare(actual, ip[@"last"]) == NSOrderedDescending)) {
                continue;
            }
            missing |= !actual;
        }
        NSString *required = host[@"domain"];
        if (required) {
            if (domain && ![domain isEqual:required]) {
                continue;
            }
            if (!domain) {
                NSString *key = [@"domain:" stringByAppendingString:required];
                NSString *addressKey = address ? [@"ip:" stringByAppendingString:address] : nil;
                BOOL fallback = [compiled[@"resolveDomains"] boolValue] && !allow && !ip && addressKey &&
                                NSDNSAddressIsLive(document, key, NSDate.date) &&
                                [document[@"globalDomainAddresses"][key] containsObject:addressKey];
                // Socket peek can supply numeric endpoints, never a hostname.
                if (!fallback) {
                    if ([compiled[@"resolveDomains"] boolValue] && !ip && (allow || address)) {
                        continue;
                    }
                    missing = YES;
                }
            }
        }
        if (!missing) {
            return NSGlobalMatched;
        }
        possible = YES;
    }
    return possible ? NSGlobalMissingEndpoints : NSGlobalMismatch;
}
