#import <Foundation/Foundation.h>

static inline NSArray<NSString *> *NSDirectionRuleValues(void) {
    return @[ @"allow", @"allow-outbound", @"allow-inbound", @"block-inbound", @"block-outbound", @"block" ];
}

static inline NSString *NSDirectionRuleTitle(NSString *rule) {
    return @{
        @"allow" : @"Allow",
        @"allow-outbound" : @"Allow Outgoing",
        @"allow-inbound" : @"Allow Incoming",
        @"block-inbound" : @"Block Incoming",
        @"block-outbound" : @"Block Outgoing",
        @"block" : @"Block In & Out"
    }[rule];
}
