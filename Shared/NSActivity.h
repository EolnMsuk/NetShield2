#import <Foundation/Foundation.h>
#import "NSGlobalRule.h"
#import "NSDestination.h"
#import "NSIdentityDisplay.h"
#include <limits.h>

static inline NSString *NSActivityOutcome(NSString *action) {
    return @{
        @"allow" : @"allow",
        @"permission-allow" : @"allow",
        @"block" : @"block",
        @"permission-block" : @"block"
    }[action]
               ?: @"other";
}
static inline unsigned long long NSActivityAdd(unsigned long long left, unsigned long long right) {
    return ULLONG_MAX - left < right ? ULLONG_MAX : left + right;
}
static inline NSString *NSActivityBytes(NSNumber *value) {
    unsigned long long bytes = value.unsignedLongLongValue;
    return bytes > LLONG_MAX ? [NSString stringWithFormat:@"%llu bytes", bytes]
                             : [NSByteCountFormatter stringFromByteCount:(long long)bytes
                                                              countStyle:NSByteCountFormatterCountStyleFile];
}

static inline NSUInteger NSActivityRoot(NSMutableArray<NSNumber *> *parents, NSUInteger index) {
    while (parents[index].unsignedIntegerValue != index) {
        parents[index] = parents[parents[index].unsignedIntegerValue];
        index = parents[index].unsignedIntegerValue;
    }
    return index;
}

static inline NSArray<NSDictionary *> *NSGroupedActivity(NSArray<NSDictionary *> *events) {
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *groups = [NSMutableDictionary new];
    NSMutableArray<NSMutableDictionary *> *ordered = [NSMutableArray new];
    NSArray *newestFirst = [[events reverseObjectEnumerator].allObjects
        sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            return [right[@"time"] compare:left[@"time"]];
        }];
    NSMutableDictionary *flows = [NSMutableDictionary new];
    NSMutableArray *unique = [NSMutableArray new];
    for (NSDictionary *event in newestFirst) {
        NSString *identifier = event[@"flow"];
        NSArray *flowKey = identifier.length ? @[ event[@"identity"], identifier ] : nil;
        NSMutableDictionary *flow = flowKey ? flows[flowKey] : nil;
        if (!flow) {
            flow = [event mutableCopy];
            [unique addObject:flow];
            if (flowKey) {
                flows[flowKey] = flow;
            }
            continue;
        }
        for (NSString *bytes in @[ @"bytesIn", @"bytesOut" ]) {
            flow[bytes] = @(MAX([flow[bytes] unsignedLongLongValue], [event[bytes] unsignedLongLongValue]));
        }
        NSMutableDictionary *peer = [flow[@"destination"] mutableCopy] ?: [NSMutableDictionary new];
        for (NSString *key in event[@"destination"]) {
            if (!peer[key] || ([peer[key] isKindOfClass:NSString.class] && ![peer[key] length])) {
                peer[key] = event[@"destination"][key];
            }
        }
        flow[@"destination"] = peer;
    }
    NSMutableArray<NSNumber *> *parents = [NSMutableArray new];
    NSMutableDictionary<NSArray *, NSNumber *> *hosts = [NSMutableDictionary new];
    for (NSUInteger index = 0; index < unique.count; index++) {
        [parents addObject:@(index)];
        NSDictionary *event = unique[index];
        NSDictionary *destination = event[@"destination"];
        for (NSString *field in @[ @"address", @"domain" ]) {
            NSString *host = NSGlobalHostKey(destination[field]);
            if (!host) {
                continue;
            }
            NSArray *key = @[
                event[@"identity"], destination[@"port"] ?: @0, event[@"direction"],
                destination[@"protocol"] ?: @"unknown", host
            ];
            NSNumber *previous = hosts[key];
            if (previous) {
                NSUInteger left = NSActivityRoot(parents, index);
                NSUInteger right = NSActivityRoot(parents, previous.unsignedIntegerValue);
                parents[MAX(left, right)] = @(MIN(left, right));
            } else {
                hosts[key] = @(index);
            }
        }
    }
    for (NSUInteger index = 0; index < unique.count; index++) {
        NSDictionary *event = unique[index];
        NSString *outcome = NSActivityOutcome(event[@"action"]);
        NSDictionary *destination = event[@"destination"];
        NSArray *key = @[
            event[@"identity"], NSGlobalHostKey(destination[@"address"]) ?: NSGlobalHostKey(destination[@"domain"]) ?: @"",
            destination[@"port"] ?: @0, event[@"direction"], destination[@"protocol"] ?: @"unknown"
        ];
        NSNumber *root = @(NSActivityRoot(parents, index));
        NSMutableDictionary *group = groups[root];
        if (!group) {
            group = [event mutableCopy];
            group[@"action"] = outcome;
            group[@"connections"] = @0;
            group[@"outcomeCounts"] = [NSMutableDictionary new];
            group[@"hosts"] = [NSMutableSet new];
            group[@"bytesIn"] = @0;
            group[@"bytesOut"] = @0;
            group[@"groupKey"] = [key[1] length] ? key : [key arrayByAddingObject:@(index)];
            groups[root] = group;
            [ordered addObject:group];
        }
        group[@"connections"] = @([group[@"connections"] unsignedIntegerValue] + 1);
        NSMutableDictionary *counts = group[@"outcomeCounts"];
        counts[outcome] = @([counts[outcome] unsignedIntegerValue] + 1);
        if (counts.count > 1) {
            group[@"action"] = @"mixed";
        }
        NSMutableSet *distinctHosts = group[@"hosts"];
        NSString *host = NSGlobalHostKey(destination[@"domain"]) ?: NSGlobalHostKey(destination[@"address"]);
        if (host) {
            [distinctHosts addObject:host];
        }
        for (NSString *field in @[ @"bytesIn", @"bytesOut" ]) {
            unsigned long long left = [group[field] unsignedLongLongValue],
                               right = [event[field] unsignedLongLongValue];
            if (ULLONG_MAX - left < right) {
                group[@"bytesSaturated"] = @YES;
            }
            group[field] = @(NSActivityAdd(left, right));
        }
    }
    NSMutableArray *result = [NSMutableArray new];
    for (NSDictionary *group in ordered) {
        NSMutableDictionary *immutable = [group mutableCopy];
        immutable[@"outcomeCounts"] = [group[@"outcomeCounts"] copy];
        immutable[@"hosts"] = [[group[@"hosts"] allObjects] sortedArrayUsingSelector:@selector(compare:)];
        immutable[@"hostCount"] = @([immutable[@"hosts"] count]);
        if ([immutable[@"hosts"] count]) {
            NSMutableArray *key = [immutable[@"groupKey"] mutableCopy];
            key[1] = [immutable[@"hosts"] firstObject];
            immutable[@"groupKey"] = [key copy];
        } else if ([immutable[@"flow"] length]) {
            immutable[@"groupKey"] = @[ @"flow", immutable[@"identity"], immutable[@"flow"] ];
        }
        [result addObject:[immutable copy]];
    }
    return [result copy];
}

// One ordered source for connection sheets, search values, and clipboard output.
static inline NSArray<NSArray<NSString *> *> *NSActivityDetailRows(NSDictionary *connection) {
    NSString *identity = connection[@"identity"];
    NSMutableArray *details = [NSMutableArray
        arrayWithArray:@[ @[ @"Process name", identity.length ? identity : @"Unavailable from iOS" ] ]];
    [details
        addObjectsFromArray:NSConnectionDetailRows(connection[@"destination"], connection[@"direction"])];
    if ([connection[@"hostCount"] unsignedIntegerValue] > 1) {
        [details addObject:@[
            @"Grouped peers",
            [NSString stringWithFormat:@"%@ hosts; endpoint fields show the most recent peer",
                                       connection[@"hostCount"]]
        ]];
    }
    if (connection[@"outcomeCounts"]) {
        NSDictionary *counts = connection[@"outcomeCounts"];
        [details addObject:@[
            @"Outcomes",
            [NSString stringWithFormat:@"%@ allowed / %@ blocked / %@ other", counts[@"allow"] ?: @0,
                                       counts[@"block"] ?: @0, counts[@"other"] ?: @0]
        ]];
    }
    if (connection[@"connections"]) {
        [details addObject:@[ @"Connections", [connection[@"connections"] stringValue] ]];
    }
    NSString *outcome = @{@"allow" : @"Allowed",
                          @"block" : @"Blocked",
                          @"mixed" : @"Mixed outcomes"}[connection[@"action"] ?: @""]
                            ?: @"Connection";
    if (connection[@"action"]) {
        [details addObject:@[ @"Result", outcome ]];
    }
    if (connection[@"bytesIn"] || connection[@"bytesOut"]) {
        [details addObject:@[ @"Received", NSActivityBytes(connection[@"bytesIn"]) ]];
        [details addObject:@[ @"Sent", NSActivityBytes(connection[@"bytesOut"]) ]];
        if ([connection[@"bytesSaturated"] boolValue]) {
            [details
                addObject:@[ @"Byte totals", @"At least the displayed total (counter capacity reached)" ]];
        }
    }
    if (connection[@"time"]) {
        [details addObject:@[
            @"Last activity", [NSDateFormatter localizedStringFromDate:connection[@"time"]
                                                             dateStyle:NSDateFormatterShortStyle
                                                             timeStyle:NSDateFormatterShortStyle]
        ]];
    }
    return details;
}
static inline NSString *NSActivityClipboardLine(NSDictionary *connection) {
    NSMutableArray *parts = [NSMutableArray new];
    for (NSArray *row in NSActivityDetailRows(connection)) {
        NSString *part = [NSString stringWithFormat:@"%@: %@", row[0], row[1]];
        [parts addObject:[[part componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
                             componentsJoinedByString:@" "]];
    }
    return [parts componentsJoinedByString:@" / "];
}
static inline BOOL NSActivityMatchesQuery(NSDictionary *connection, NSString *query) {
    if (!query.length) {
        return YES;
    }
    NSMutableArray *values = [NSMutableArray new];
    for (NSArray *row in NSActivityDetailRows(connection)) {
        [values addObject:row[1]];
    }
    for (NSString *key in @[ @"bytesIn", @"bytesOut", @"direction", @"action" ]) {
        if (connection[key]) {
            [values addObject:[connection[key] description]];
        }
    }
    for (NSString *value in values) {
        if ([value rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}
