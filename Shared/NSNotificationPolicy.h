#import "NSPolicy.h"

static inline BOOL NSShouldWithdrawPermissionNotification(NSPolicy *policy, NSString *identity,
                                                          BOOL current) {
    return !current || !policy || ![policy requiresPermissionForIdentity:identity];
}

static inline BOOL NSShouldWithdrawPermissionRequestNotification(NSPolicy *policy, NSDictionary *request,
                                                                 BOOL current) {
    return !current || !policy || ![policy requiresPermissionForRequest:request];
}
