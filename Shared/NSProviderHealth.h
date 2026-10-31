#import "NSConstants.h"

// A fresh heartbeat from an older activation must not verify a new configuration.
// This checks control-provider health only.
static inline BOOL NSHasCurrentControlHeartbeat(NSDictionary *monitor, NSString *activation, NSDate *now) {
    if (![activation isKindOfClass:NSString.class] || !activation.length ||
        ![monitor[@"activation"] isEqual:activation] || ![monitor[@"updated"] isKindOfClass:NSDate.class]) {
        return NO;
    }
    NSTimeInterval age = [now timeIntervalSinceDate:monitor[@"updated"]];
    return age >= 0 && age < NSMonitorFreshness && [monitor[@"controlRunning"] boolValue];
}
