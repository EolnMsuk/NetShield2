#import <Foundation/Foundation.h>

// A display-only projection of the retained event history. Never persist these totals.
static inline NSArray<NSDictionary *> *NSGroupedActivity(NSArray<NSDictionary *> *events) {
    NSMutableDictionary<NSArray *, NSMutableDictionary *> *groups = [NSMutableDictionary new];
    NSMutableArray<NSMutableDictionary *> *ordered = [NSMutableArray new];
    NSArray *newestFirst = [[events reverseObjectEnumerator].allObjects
        sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            return [right[@"time"] compare:left[@"time"]];
        }];
    for (NSDictionary *event in newestFirst) {
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
            event[@"identity"], destination[@"address"] ?: @"", destination[@"localPort"] ?: @0,
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
