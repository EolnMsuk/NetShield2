#import <Foundation/Foundation.h>
#import "../Shared/NSPermissionQueue.h"
#include <stdio.h>
#include <stdlib.h>

static unsigned checks;
static void check(BOOL pass, const char *message) {
    checks++;
    if (!pass) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static NSPolicy *policy(NSString *action, NSDictionary *rules) {
    NSMutableDictionary *d = [[NSPolicy defaultDocument] mutableCopy];
    d[@"default"] = action;
    d[@"rules"] = rules;
    return [NSPolicy policyWithDocument:d error:NULL];
}
int main(void) {
    @autoreleasepool {
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:1000];
        NSPermissionQueue *q = [NSPermissionQueue new];
        __block unsigned callbacks = 0, allowed = 0;
        void (^done)(BOOL) = ^(BOOL allow) { callbacks++; allowed += allow ? 1 : 0; };
        NSDictionary *request = [q enqueueIdentity:@"A" direction:NSFlowDirectionOutbound now:10 date:date completion:done];
        check(request != nil && q.waitingCount == 1 && callbacks == 0, "new flow waits for consent");
        check([q enqueueIdentity:@"A" direction:NSFlowDirectionInbound now:11 date:date completion:done] == nil, "same app generates only one notification");
        check(q.requests.count == 1 && q.waitingCount == 2, "same-app attempts coalesce");
        [q resolveWithPolicy:policy(@"ask", @{}) now:20];
        check(callbacks == 0, "unanswered flow not allowed");
        [q resolveWithPolicy:policy(@"ask", @{@"A": @"block-inbound"}) now:25];
        check(callbacks == 2 && allowed == 1 && q.requests.count == 0, "saved directional rule resolves each direction correctly");
        [q resolveWithPolicy:policy(@"allow", @{}) now:26];
        check(callbacks == 2, "completion is exactly once");

        callbacks = allowed = 0;
        [q enqueueIdentity:@"B" direction:NSFlowDirectionOutbound now:100 date:date completion:done];
        [q resolveWithPolicy:policy(@"ask", @{}) now:129];
        check(callbacks == 0, "deadline not reached");
        [q resolveWithPolicy:policy(@"ask", @{}) now:130];
        check(callbacks == 1 && allowed == 0 && q.waitingCount == 0, "deadline denies outstanding connection");
        check(q.requests.count == 1 && [q.requests[0][@"expired"] boolValue], "expired request remains answerable");
        check([q enqueueIdentity:@"B" direction:NSFlowDirectionOutbound now:131 date:date completion:done] == nil, "retry does not notify again");
        check(callbacks == 2 && q.waitingCount == 0, "retry after timeout is immediately denied");
        [q resolveWithPolicy:policy(@"ask", @{@"B": @"allow"}) now:132];
        check(callbacks == 2 && q.requests.count == 0, "late allow clears request without resurrecting closed flow");

        callbacks = allowed = 0;
        [q enqueueIdentity:@"C" direction:NSFlowDirectionOutbound now:200 date:date completion:done];
        [q resolveWithPolicy:policy(@"ask", @{@"C": @"allow"}) now:230];
        check(callbacks == 1 && allowed == 0, "deadline beats simultaneous late permission");
        [q enqueueIdentity:@"D" direction:NSFlowDirectionOutbound now:300 date:date completion:done];
        [q resolveWithPolicy:nil now:301];
        check(callbacks == 2 && allowed == 0 && q.requests.count == 0, "invalid policy fails closed");

        callbacks = allowed = 0;
        for (unsigned i = 0; i < 17; i++) [q enqueueIdentity:@"busy" direction:NSFlowDirectionOutbound now:400 date:date completion:done];
        check(q.waitingCount == 16 && callbacks == 1 && allowed == 0, "per-app wait bound denies overflow");
        [q cancelAll];
        check(callbacks == 17 && q.waitingCount == 0 && q.requests.count == 0, "stop cancels all waiters");
        [q cancelAll];
        check(callbacks == 17, "second stop never invokes completion again");

        callbacks = allowed = 0;
        for (unsigned i = 0; i < 65; i++) [q enqueueIdentity:[NSString stringWithFormat:@"app%u", i] direction:NSFlowDirectionOutbound now:500 date:date completion:done];
        check(q.requests.count == 64 && callbacks == 1, "distinct-app queue is bounded");
        [q cancelAll];
        check(callbacks == 65 && allowed == 0, "overflow and shutdown deny every unapproved flow");

        callbacks = allowed = 0;
        for (unsigned app = 0; app < 17; app++)
            for (unsigned flow = 0; flow < 16; flow++) [q enqueueIdentity:[NSString stringWithFormat:@"load%u", app] direction:NSFlowDirectionOutbound now:600 date:date completion:done];
        check(q.waitingCount == 256 && callbacks == 16, "global waiter cap enforced");
        [q cancelAll];
        check(callbacks == 272 && allowed == 0, "all retained completions released on stop");
        callbacks = allowed = 0;
        NSMutableDictionary *appleDocument = [[NSPolicy defaultDocument] mutableCopy];
        appleDocument[@"allowAppleSystemProcesses"] = @YES;
        NSPolicy *applePolicy = [NSPolicy policyWithDocument:appleDocument error:NULL];
        [q enqueueIdentity:@"com.apple.test" direction:NSFlowDirectionOutbound now:700 date:date completion:done];
        [q resolveWithPolicy:applePolicy now:701];
        check(callbacks == 1 && allowed == 1 && q.requests.count == 0, "enabling switch resolves pending Apple request");
        [q resolveWithPolicy:applePolicy now:702];
        check(callbacks == 1, "switch resolves each pending flow exactly once");
        [q enqueueIdentity:@".com.apple.test" direction:NSFlowDirectionOutbound now:800 date:date completion:done];
        [q resolveWithPolicy:applePolicy now:830];
        check(callbacks == 2 && allowed == 1 && q.requests.count == 0, "late switch clears request without admitting timed-out flow");
        printf("Passed %u permission queue checks\n", checks);
    }
    return 0;
}
