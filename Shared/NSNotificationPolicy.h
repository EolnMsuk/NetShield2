#import "NSPolicy.h"

// A failed policy read is not evidence that a permission request was answered.
// Notification cleanup must only act on a positively known policy decision.
static inline BOOL NSShouldWithdrawPermissionNotification(NSPolicy *policy, NSString *identity) {
    return policy != nil && ![policy requiresPermissionForIdentity:identity];
}
