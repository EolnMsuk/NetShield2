#import <Foundation/Foundation.h>
#import "NSGlobalRule.h"
#import "NSDestination.h"
#import "NSIdentityDisplay.h"

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
            NSArray *key = @[ event[@"identity"], destination[@"port"] ?: @0, event[@"direction"], host ];
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
        NSString *action = event[@"action"];
        NSString *outcome = @{
            @"allow" : @"allow",
            @"permission-allow" : @"allow",
            @"block" : @"block",
            @"permission-block" : @"block"
        }[action]
                                ?: @"other";
        NSDictionary *destination = event[@"destination"];
        NSArray *key = @[
            event[@"identity"], NSGlobalHostKey(destination[@"address"]) ?: NSGlobalHostKey(destination[@"domain"]) ?: @"",
            destination[@"port"] ?: @0, event[@"direction"]
        ];
        NSNumber *root = @(NSActivityRoot(parents, index));
        NSMutableDictionary *group = groups[root];
        if (!group) {
            group = [event mutableCopy];
            group[@"action"] = outcome;
            group[@"connections"] = @0;
            group[@"bytesIn"] = @0;
            group[@"bytesOut"] = @0;
            group[@"groupKey"] = [key[1] length] ? key : [key arrayByAddingObject:@(index)];
            groups[root] = group;
            [ordered addObject:group];
        }
        group[@"connections"] = @([group[@"connections"] unsignedIntegerValue] + 1);
        group[@"bytesIn"] =
            @([group[@"bytesIn"] unsignedLongLongValue] + [event[@"bytesIn"] unsignedLongLongValue]);
        group[@"bytesOut"] =
            @([group[@"bytesOut"] unsignedLongLongValue] + [event[@"bytesOut"] unsignedLongLongValue]);
    }
    NSMutableArray *result = [NSMutableArray new];
    for (NSDictionary *group in ordered) {
        [result addObject:[group copy]];
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
    if (connection[@"connections"]) {
        [details addObject:@[ @"Connections", [connection[@"connections"] stringValue] ]];
    }
    NSString *outcome =
        @{@"allow" : @"Allowed", @"block" : @"Blocked"}[connection[@"action"] ?: @""] ?: @"Connection";
    if (connection[@"action"]) {
        [details addObject:@[ @"Result", outcome ]];
    }
    if (connection[@"bytesIn"] || connection[@"bytesOut"]) {
        [details addObject:@[
            @"Received", [NSByteCountFormatter stringFromByteCount:[connection[@"bytesIn"] longLongValue]
                                                        countStyle:NSByteCountFormatterCountStyleFile]
        ]];
        [details addObject:@[
            @"Sent", [NSByteCountFormatter stringFromByteCount:[connection[@"bytesOut"] longLongValue]
                                                    countStyle:NSByteCountFormatterCountStyleFile]
        ]];
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
