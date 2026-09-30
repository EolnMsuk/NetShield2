#import <Foundation/Foundation.h>
#import "NSGlobalRule.h"

// A display-only projection of the retained event history. Never persist these totals.
static inline NSArray<NSDictionary *> *NSGroupedActivity(NSArray<NSDictionary *> *events) {
    NSMutableDictionary<NSArray *, NSMutableDictionary *> *groups = [NSMutableDictionary new];
    NSMutableArray<NSMutableDictionary *> *ordered = [NSMutableArray new];
    NSArray *newestFirst = [[events reverseObjectEnumerator].allObjects
        sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            return [right[@"time"] compare:left[@"time"]];
        }];
    // Reports carry cumulative flow totals. Coalesce admission, permission, and
    // closure events before grouping; never add the same flow's totals twice.
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
        // A data-provider verdict takes precedence over a synthetic permission
        // event, even when callback scheduling records the permission later.
        if ([flow[@"action"] hasPrefix:@"permission-"] && ![event[@"action"] hasPrefix:@"permission-"]) {
            flow[@"action"] = event[@"action"];
        }
    }
    for (NSDictionary *event in unique) {
        NSString *action = event[@"action"];
        NSString *outcome = @{
            @"allow" : @"allow",
            @"permission-allow" : @"allow",
            @"block" : @"block",
            @"permission-block" : @"block"
        }[action]
                                ?: @"other";
        NSDictionary *destination = event[@"destination"];
        // Newest first: retain the latest destination/domain while aggregating by IP.
        NSArray *key = @[
            event[@"identity"], NSGlobalHostKey(destination[@"address"]) ?: NSGlobalHostKey(destination[@"domain"]) ?: @"", destination[@"localPort"] ?: @0,
            destination[@"port"] ?: @0, event[@"direction"], outcome
        ];
        NSMutableDictionary *group = groups[key];
        if (!group) {
            group = [event mutableCopy];
            group[@"groupKey"] = key;
            group[@"action"] = outcome;
            group[@"connections"] = @0;
            group[@"bytesIn"] = @0;
            group[@"bytesOut"] = @0;
            groups[key] = group;
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
