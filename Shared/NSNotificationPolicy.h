#import "NSPolicy.h"

static inline BOOL NSShouldWithdrawPermissionNotification(NSPolicy *policy, NSString *identity) {
    return policy != nil && ![policy requiresPermissionForIdentity:identity];
}
