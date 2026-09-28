#import "NSPolicy.h"

// A failed policy read is not evidence that a permission request was answered.
// Notification cleanup must only act on a positively known policy decision.
static inline BOOL NSShouldWithdrawPermissionNotification(NSPolicy *policy, NSString *identity) {
    return policy != nil && ![policy requiresPermissionForIdentity:identity];
}

// Only a recent, confirmed background handoff may replay a suppressed request.
// Queue tokens bind retries to the current provider session and identity.
static inline NSArray<NSDictionary *> *NSLinkHandoffRetries(NSDictionary *handoff, NSArray<NSDictionary *> *requests,
        NSSet<NSString *> *consumed, NSSet<NSString *> *inFlight, NSPolicy *policy, NSDate *now) {
    if (![handoff[@"handoff"] isKindOfClass:NSString.class] || ![handoff[@"handoff"] length] ||
        ![handoff[@"background"] isEqual:@YES] || ![handoff[@"started"] isKindOfClass:NSDate.class] ||
        ![handoff[@"tokens"] isKindOfClass:NSArray.class] || [handoff[@"tokens"] count] > 64) return @[];
    NSTimeInterval age = [now timeIntervalSinceDate:handoff[@"started"]];
    if (age < 0 || age > 30) return @[];
    NSMutableArray *result = [NSMutableArray new];
    for (NSDictionary *request in requests) {
        NSString *token = request[@"token"];
        if ([handoff[@"tokens"] containsObject:token] && ![consumed containsObject:token] &&
            ![inFlight containsObject:token] && [policy requiresPermissionForIdentity:request[@"identity"]])
            [result addObject:request];
    }
    return result;
}
