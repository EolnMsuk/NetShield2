#import "../Shared/NSGlobalRule.h"
#import "../Shared/NSRuleChoices.h"
#import "../Shared/NSBootSession.h"
#import "../Shared/NSPermissionRequest.h"

// Explicit current-schema constructors for test inputs, never stored-data readers.
static inline NSDictionary *NSFixtureRules(NSDictionary *selections) {
    NSMutableDictionary *rules = [NSMutableDictionary new];
    for (NSString *identity in selections) {
        id selection = selections[identity];
        rules[identity] =
            [selection isKindOfClass:NSString.class] ? NSAppRuleBySelecting(nil, selection) : selection;
    }
    return rules;
}
static inline NSString *NSFixtureGlobal(id identities, NSString *hosts, NSString *remote, NSString *local,
                                        NSString *protocol, NSString *action) {
    NSArray *apps = [identities isKindOfClass:NSArray.class] ? identities
                    : [identities length]                    ? @[ identities ]
                                                             : @[];
    NSArray *protocols = [protocol isEqual:@"any"] ? @[] : [protocol componentsSeparatedByString:@"+"];
    return NSGlobalRuleKey(NSGlobalCondition(apps, NSGlobalParseDestinations(hosts),
                                             NSGlobalParsePorts(remote), NSGlobalParsePorts(local), protocols,
                                             NSGlobalCoverage(action), YES));
}
static inline NSDictionary *NSFixtureDNSLifetime(void) {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    return @{@"boot" : NSBootSessionIdentifier() ?: @"", @"issued" : @(now), @"expires" : @(now + 120)};
}

static inline NSDictionary *NSFixtureRequest(NSDictionary *fields, NSPolicy *policy) {
    NSMutableDictionary *request = [fields mutableCopy];
    if (!request[@"askGeneration"]) {
        request[@"askGeneration"] = NSPermissionGeneration(policy, request[@"identity"]);
    }
    return [request copy];
}
