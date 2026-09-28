#import <Foundation/Foundation.h>
#import "../Shared/NSStore.h"
#import "../Shared/NSNotificationPolicy.h"

static void check(BOOL value, NSString *message) {
    if (!value) { NSLog(@"FAIL: %@", message); exit(1); }
}
int main(void) {
    @autoreleasepool {
        NSDate *now = [NSDate dateWithTimeIntervalSince1970:1000];
        NSDictionary *request = @{@"token": @"current-token", @"identity": @"app.test"};
        NSMutableDictionary *monitor = [@{@"controlRunning": @YES, @"updated": now, @"requests": @[request]} mutableCopy];
        NSPolicy *policy = [NSPolicy policyWithDocument:[NSPolicy defaultDocument] error:NULL];
        NSDictionary *allowed = NSPermissionResponseDocument(request, monitor, policy, now, YES, NULL);
        check([allowed[@"rules"][@"app.test"] isEqual:@"allow"], @"Background allow saves identity");
        check(![allowed[@"revision"] isEqual:policy.document[@"revision"]], @"New revision wakes provider");
        NSDictionary *blocked = NSPermissionResponseDocument(request, monitor, policy, now, NO, NULL);
        check([blocked[@"rules"][@"app.test"] isEqual:@"block"], @"Background deny saves identity");
        check(!NSPermissionResponseDocument(@{@"token": @"old-session", @"identity": @"app.test"}, monitor, policy, now, YES, NULL), @"Reject old token");
        check(!NSPermissionResponseDocument(@{@"token": @"current-token", @"identity": @"other.app"}, monitor, policy, now, YES, NULL), @"Reject altered identity");
        check(!NSPermissionResponseDocument(@{}, monitor, policy, now, YES, NULL), @"Reject missing fields");
        monitor[@"updated"] = [now dateByAddingTimeInterval:-8];
        check(!NSPermissionResponseDocument(request, monitor, policy, now, YES, NULL), @"Reject stale heartbeat");
        monitor[@"updated"] = [now dateByAddingTimeInterval:1];
        check(!NSPermissionResponseDocument(request, monitor, policy, now, YES, NULL), @"Reject future heartbeat");
        monitor[@"updated"] = now;
        monitor[@"controlRunning"] = @NO;
        check(!NSPermissionResponseDocument(request, monitor, policy, now, YES, NULL), @"Reject stopped provider");
        monitor[@"controlRunning"] = @YES;
        NSPolicy *decided = [NSPolicy policyWithDocument:blocked error:NULL];
        check(!NSPermissionResponseDocument(request, monitor, decided, now, YES, NULL), @"Late action cannot override explicit decision");
        monitor[@"requests"] = @[];
        check(!NSPermissionResponseDocument(request, monitor, policy, now, YES, NULL), @"Reject removed request");
        NSDictionary *appleRequest = @{@"token": @"apple-token", @"identity": @"com.apple.test"};
        monitor[@"requests"] = @[appleRequest];
        NSMutableDictionary *appleDocument = [[NSPolicy defaultDocument] mutableCopy];
        appleDocument[@"allowAppleSystemProcesses"] = @YES;
        NSPolicy *applePolicy = [NSPolicy policyWithDocument:appleDocument error:NULL];
        check(!NSPermissionResponseDocument(appleRequest, monitor, applePolicy, now, NO, NULL), @"Stale notification cannot save a block while Apple allowance is on");
        check(!NSShouldWithdrawPermissionNotification(nil, @"app.test"), @"Failed policy read must not withdraw an unanswered notification");
        check(!NSShouldWithdrawPermissionNotification(policy, @"app.test"), @"Ask policy preserves third-party notification");
        check(!NSShouldWithdrawPermissionNotification(applePolicy, @"app.test"), @"Apple allowance preserves third-party notification");
        check(NSShouldWithdrawPermissionNotification(applePolicy, @"com.apple.test"), @"Apple allowance withdraws Apple notification");
        check(NSShouldWithdrawPermissionNotification(applePolicy, @".com.apple.test"), @"Apple allowance withdraws leading-dot Apple notification");
        check(NSShouldWithdrawPermissionNotification(applePolicy, @"Apple.com.apple.test"), @"Apple allowance withdraws Apple signing-prefix notification");
        check(NSShouldWithdrawPermissionNotification(decided, @"app.test"), @"Saved decision withdraws answered notification");
        NSMutableDictionary *handoff = [@{@"handoff": @"link-1", @"started": now,
            @"background": @NO, @"tokens": @[@"current-token"]} mutableCopy];
        NSSet *empty = [NSSet set];
        NSArray *pending = @[request];
        check(NSLinkHandoffRetries(handoff, pending, empty, empty, policy, now).count == 0, @"Foreground handoff never retries");
        handoff[@"background"] = @YES;
        check(NSLinkHandoffRetries(handoff, pending, empty, empty, policy, now).count == 1, @"Background handoff retries suppressed token");
        NSSet *tokenSet = [NSSet setWithObject:@"current-token"];
        check(NSLinkHandoffRetries(handoff, pending, tokenSet, empty, policy, now).count == 0, @"Same handoff retries each token only once");
        check(NSLinkHandoffRetries(handoff, pending, empty, tokenSet, policy, now).count == 0, @"Wait for original submission completion before retry");
        check(NSLinkHandoffRetries(handoff, pending, empty, empty, decided, now).count == 0, @"Decision before retry cancels replay");
        check(NSLinkHandoffRetries(handoff, pending, empty, empty, nil, now).count == 0, @"Unreadable policy cannot authorize replay");
        check(NSLinkHandoffRetries(handoff, @[], empty, empty, policy, now).count == 0, @"Old provider token cannot replay");
        check(NSLinkHandoffRetries(@{}, pending, empty, empty, policy, now).count == 0, @"Cancelled handoff cannot replay");
        check(NSLinkHandoffRetries(handoff, pending, empty, empty, policy, [now dateByAddingTimeInterval:31]).count == 0, @"Stale handoff cannot replay");
        check(NSLinkHandoffRetries(handoff, pending, empty, empty, policy, [now dateByAddingTimeInterval:-1]).count == 0, @"Future handoff cannot replay");
        check(NSLinkHandoffRetries(handoff, @[@{@"token": @"other-token", @"identity": @"other.app"}], empty, empty, policy, now).count == 0, @"Unrelated request is never replayed");
        NSArray *preferences = @[@{@"token": @"current-token", @"identity": @"Apple.com.apple.Preferences"}];
        check(NSLinkHandoffRetries(handoff, preferences, empty, empty, applePolicy, now).count == 0, @"Apple auto-allow prevents handoff notification");
        NSLog(@"Passed 31 notification-response checks");
    }
    return 0;
}
