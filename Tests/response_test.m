#import <Foundation/Foundation.h>
#import "../Shared/NSStore.h"

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
        NSLog(@"Passed 12 notification-response checks");
    }
    return 0;
}
