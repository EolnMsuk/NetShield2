#import <UIKit/UIKit.h>
#import "../Shared/NSRuleChoices.h"

// Shared by rule rows, activity rows, and action pickers. Dark-mode colors are
// brighter than the light palette; row backgrounds use the same tint.
static inline UIColor *NSRuleColor(NSString *rule) {
    BOOL allow = [rule isEqual:@"allow"] || [rule isEqual:@"allow-outbound"];
    BOOL incoming = [rule isEqual:@"block-inbound"] || [rule isEqual:@"allow-inbound"];
    BOOL block = [@[ @"block", @"block-outbound", @"remove" ] containsObject:rule ?: @""];
    if (!allow && !incoming && !block) {
        return nil;
    }
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
        if (allow) {
            return dark ? [UIColor colorWithRed:0.30 green:0.85 blue:0.42 alpha:1]
                        : [UIColor colorWithRed:0.17 green:0.68 blue:0.30 alpha:1];
        }
        if (incoming) {
            return dark ? [UIColor colorWithRed:1 green:0.65 blue:0.22 alpha:1]
                        : [UIColor colorWithRed:0.88 green:0.49 blue:0 alpha:1];
        }
        return dark ? [UIColor colorWithRed:1 green:0.36 blue:0.33 alpha:1]
                    : [UIColor colorWithRed:0.88 green:0.20 blue:0.17 alpha:1];
    }];
}

// App/system rows use outgoing when both explicit directions are present.
static inline UIColor *NSAppRuleColor(id value) {
    NSDictionary *record = NSAppRuleRecord(value);
    if (record[@"both"]) {
        return NSRuleColor(record[@"both"]);
    }
    NSString *direction = record[@"outbound"] ? @"outbound" : @"inbound";
    return record[direction] ? NSRuleColor([NSString stringWithFormat:@"%@-%@", record[direction], direction])
                             : nil;
}
