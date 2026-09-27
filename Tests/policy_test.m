#import <Foundation/Foundation.h>
#import "../Shared/NSPolicy.h"
#include <stdio.h>
#include <stdlib.h>

static unsigned checks;
static void check(BOOL result, const char *message) {
    checks++;
    if (!result) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static NSPolicy *parse(NSDictionary *d) {
    NSError *error = nil;
    NSPolicy *policy = [NSPolicy policyWithDocument:d error:&error];
    check(policy != nil && error == nil, "valid policy parses");
    return policy;
}
int main(void) {
    @autoreleasepool {
        NSMutableDictionary *d = [[NSPolicy defaultDocument] mutableCopy];
        NSPolicy *policy = parse(d);
        check([policy allowsIdentity:nil direction:NSFlowDirectionUnknown], "fresh unknown policy allows");
        check(![policy allowsIdentity:@"app" direction:NSFlowDirectionOutbound], "fresh app cannot bypass consent");
        check([policy requiresPermissionForIdentity:@"app"], "fresh app requests permission");
        check(![policy requiresPermissionForIdentity:nil], "unattributed traffic cannot pretend to be an app");
        d[@"default"] = @"block";
        d[@"unattributed"] = @"block";
        NSMutableDictionary *rules = [@{@"TEAM.app": @"allow", @"blocked": @"block",
            @"client": @"block-inbound", @"server": @"block-outbound"} mutableCopy];
        d[@"rules"] = rules;
        policy = parse(d);
        check([policy allowsIdentity:@"TEAM.app" direction:NSFlowDirectionUnknown], "explicit allow wins");
        check(![policy requiresPermissionForIdentity:@"TEAM.app"], "saved rule does not prompt");
        check(![policy allowsIdentity:@"app" direction:NSFlowDirectionOutbound], "never strip a signing prefix");
        check(![policy allowsIdentity:nil direction:NSFlowDirectionOutbound], "nil uses unknown policy");
        check(![policy allowsIdentity:@"" direction:NSFlowDirectionInbound], "empty uses unknown policy");
        check(![policy allowsIdentity:@"blocked" direction:NSFlowDirectionOutbound], "block outbound");
        check(![policy allowsIdentity:@"blocked" direction:NSFlowDirectionInbound], "block inbound");
        check([policy allowsIdentity:@"client" direction:NSFlowDirectionOutbound], "client outbound allowed");
        check(![policy allowsIdentity:@"client" direction:NSFlowDirectionInbound], "client inbound blocked");
        check(![policy allowsIdentity:@"client" direction:NSFlowDirectionUnknown], "directional unknown blocked");
        check([policy allowsIdentity:@"server" direction:NSFlowDirectionInbound], "server inbound allowed");
        check(![policy allowsIdentity:@"server" direction:NSFlowDirectionOutbound], "server outbound blocked");
        rules[@"TEAM.app"] = @"block";
        check([policy allowsIdentity:@"TEAM.app" direction:NSFlowDirectionOutbound], "snapshot cannot be mutated externally");
        check(![parse(d) allowsIdentity:@"TEAM.app" direction:NSFlowDirectionOutbound], "new snapshot sees edit");
        // Optional switch preserves old documents and overrides without deleting rules.
        NSMutableDictionary *apple = [[NSPolicy defaultDocument] mutableCopy];
        check(![parse(apple) automaticallyAllowsIdentity:@"com.apple.test"], "switch defaults off");
        [apple removeObjectForKey:@"allowAppleSystemProcesses"];
        check([parse(apple) requiresPermissionForIdentity:@"com.apple.test"], "legacy policy keeps asking");
        apple[@"allowAppleSystemProcesses"] = @YES;
        apple[@"rules"] = @{@"com.apple.test": @"block", @".com.apple.test": @"block-outbound"};
        NSPolicy *applePolicy = parse(apple);
        for (NSString *identity in @[@"com.apple.test", @".com.apple.test", @"com.apple.new"]) {
            check(![applePolicy requiresPermissionForIdentity:identity], "Apple allowance bypasses prompt");
            for (NSNumber *direction in @[@0, @1, @2])
                check([applePolicy allowsIdentity:identity direction:direction.integerValue], "Apple allowance overrides all directions");
        }
        for (NSString *identity in @[@"com.appleevil.test", @"com.apple", @"TEAM.com.apple.test", @"other.com.apple.test", @"COM.APPLE.test", @""]) {
            check(![applePolicy automaticallyAllowsIdentity:identity], "only exact leading namespaces match");
        }
        check(![applePolicy automaticallyAllowsIdentity:nil], "nil is not auto-allowed");
        check([applePolicy requiresPermissionForIdentity:@"third.party"], "other apps still ask");
        apple[@"default"] = @"block";
        apple[@"unattributed"] = @"block";
        applePolicy = parse(apple);
        check([applePolicy allowsIdentity:@"com.apple.new" direction:NSFlowDirectionOutbound], "allowance overrides default block");
        check(![applePolicy allowsIdentity:@"third.party" direction:NSFlowDirectionOutbound], "other apps still block");
        check(![applePolicy allowsIdentity:nil direction:NSFlowDirectionOutbound], "unidentified policy is preserved");
        apple[@"allowAppleSystemProcesses"] = @NO;
        applePolicy = parse(apple);
        check(![applePolicy allowsIdentity:@"com.apple.test" direction:NSFlowDirectionOutbound], "saved block restored when disabled");
        check(![applePolicy allowsIdentity:@".com.apple.test" direction:NSFlowDirectionOutbound], "saved directional block restored");
        check([applePolicy allowsIdentity:@".com.apple.test" direction:NSFlowDirectionInbound], "saved directional allow restored");
        check([applePolicy.document[@"rules"] isEqual:apple[@"rules"]], "original rules remain intact");
        for (id invalid in @[@"yes", @1, @[], NSNull.null]) {
            apple[@"allowAppleSystemProcesses"] = invalid;
            check([NSPolicy policyWithDocument:apple error:NULL] == nil, "malformed allowance rejected");
        }
        for (id bad in @[@[], @"x", @{}, @{@"schema": @1}, @{@"schema": @YES}]) {
            NSError *error = nil;
            check([NSPolicy policyWithDocument:bad error:&error] == nil && error != nil, "malformed root rejected");
        }
        for (NSString *key in @[@"schema", @"revision", @"default", @"unattributed", @"rules"]) {
            NSMutableDictionary *bad = [[NSPolicy defaultDocument] mutableCopy];
            [bad removeObjectForKey:key];
            check([NSPolicy policyWithDocument:bad error:NULL] == nil, "missing field rejected");
            bad[key] = NSNull.null;
            check([NSPolicy policyWithDocument:bad error:NULL] == nil, "wrong field type rejected");
        }
        for (NSDictionary *badRules in @[@{@"app": @"typo"}, @{@"": @"allow"}, @{@"app": @1}]) {
            d[@"rules"] = badRules;
            check([NSPolicy policyWithDocument:d error:NULL] == nil, "bad rule rejected");
        }
        d = [[NSPolicy defaultDocument] mutableCopy];
        d[@"unattributed"] = @"block-inbound";
        check([NSPolicy policyWithDocument:d error:NULL] == nil, "unknown policy must allow or block");
        d = [[NSPolicy defaultDocument] mutableCopy];
        NSMutableDictionary *oversized = [NSMutableDictionary new];
        for (unsigned i = 0; i < 4097; i++) oversized[[NSString stringWithFormat:@"app%u", i]] = @"allow";
        d[@"rules"] = oversized;
        check([NSPolicy policyWithDocument:d error:NULL] == nil, "rule limit enforced");
        printf("Passed %u policy checks\n", checks);
    }
    return 0;
}
