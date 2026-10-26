#import <UIKit/UIKit.h>

// Shared by rule rows, activity rows, and action pickers. Dark-mode colors are
// deeper versions of the light palette; row backgrounds use the same tint.
static inline UIColor *NSRuleColor(NSString *rule) {
    BOOL allow = [rule isEqual:@"allow"];
    BOOL incoming = [rule isEqual:@"block-inbound"];
    BOOL block = [@[ @"block", @"block-outbound", @"remove" ] containsObject:rule ?: @""];
    if (!allow && !incoming && !block) {
        return nil;
    }
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
        if (allow) {
            return dark ? [UIColor colorWithRed:0.20 green:0.65 blue:0.32 alpha:1]
                        : [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1];
        }
        if (incoming) {
            return dark ? [UIColor colorWithRed:0.85 green:0.48 blue:0.12 alpha:1]
                        : [UIColor colorWithRed:1 green:0.58 blue:0 alpha:1];
        }
        return dark ? [UIColor colorWithRed:0.85 green:0.25 blue:0.23 alpha:1]
                    : [UIColor colorWithRed:1 green:0.23 blue:0.19 alpha:1];
    }];
}
