#import "NSPolicy.h"

static inline BOOL NSShouldWithdrawPermissionNotification(NSPolicy *policy, NSString *identity,
                                                          BOOL current) {
    return !current || !policy || ![policy requiresPermissionForIdentity:identity];
}
