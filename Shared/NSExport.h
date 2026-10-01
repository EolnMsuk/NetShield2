#import "NSPolicy.h"

static inline NSData *NSRulesAndActivityJSON(NSPolicy *policy, NSArray<NSDictionary *> *events,
                                             NSString *version, NSError **error) {
    NSDictionary *document = policy.document;
    NSMutableDictionary *appRules = [NSMutableDictionary new];
    NSMutableDictionary *systemRules = [NSMutableDictionary new];
    for (NSString *identity in document[@"rules"]) {
        NSMutableDictionary *rules = NSIsAppleSystemIdentity(identity) ? systemRules : appRules;
        rules[identity] = document[@"rules"][identity];
    }
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    NSMutableArray *activity = [NSMutableArray new];
    for (NSDictionary *event in events) {
        NSMutableDictionary *entry = [event mutableCopy];
        entry[@"time"] = [formatter stringFromDate:event[@"time"]];
        [activity addObject:entry];
    }
    NSDictionary *export = @{
        @"schemaVersion" : @1,
        @"appVersion" : version,
        @"exportedAt" : [formatter stringFromDate:NSDate.date],
        @"defaultRule" : document[@"default"],
        @"unidentifiedRule" : document[@"unattributed"],
        @"allowAppleSystemProcesses" : @([document[@"allowAppleSystemProcesses"] boolValue]),
        @"appRules" : appRules,
        @"systemRules" : systemRules,
        @"globalRules" : document[@"globalRules"] ?: @{},
        @"ruleDestinations" : document[@"ruleDestinations"] ?: @{},
        @"recentActivity" : activity
    };
    return [NSJSONSerialization dataWithJSONObject:export
                                           options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                             error:error];
}
