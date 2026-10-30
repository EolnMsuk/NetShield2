#import <Foundation/Foundation.h>

static inline NSArray<NSString *> *NSDirectionRuleValues(void) {
    return @[ @"allow", @"allow-outbound", @"allow-inbound", @"block-inbound", @"block-outbound", @"block" ];
}

static inline NSString *NSDirectionRuleTitle(NSString *rule) {
    return @{
        @"allow" : @"Allow",
        @"allow-outbound" : @"Allow Outgoing",
        @"allow-inbound" : @"Allow Incoming",
        @"block-inbound" : @"Block Incoming",
        @"block-outbound" : @"Block Outgoing",
        @"block" : @"Block"
    }[rule];
}

// App/system records distinguish an explicit both-directions selection from two decisions.
static inline NSDictionary *NSAppRuleRecord(id value) {
    if ([value isKindOfClass:NSString.class]) {
        if ([value isEqual:@"allow"] || [value isEqual:@"block"]) {
            return @{@"both" : value};
        }
        if (![NSDirectionRuleValues() containsObject:value]) {
            return nil;
        }
        return @{
            [value hasSuffix:@"-inbound"]              ? @"inbound"
            : @"outbound" : [value hasPrefix:@"allow"] ? @"allow"
                                                       : @"block"
        };
    }
    if (![value isKindOfClass:NSDictionary.class] || ![value count]) {
        return nil;
    }
    for (id key in value) {
        if (![@[ @"both", @"inbound", @"outbound" ] containsObject:key] ||
            ![@[ @"allow", @"block" ] containsObject:value[key]]) {
            return nil;
        }
    }
    if (value[@"both"] && [value count] != 1) {
        return nil;
    }
    return value;
}
static inline NSArray<NSString *> *NSAppRuleSelections(id value) {
    NSDictionary *record = NSAppRuleRecord(value);
    if (record[@"both"]) {
        return @[ record[@"both"] ];
    }
    NSMutableArray *choices = [NSMutableArray new];
    for (NSString *direction in @[ @"outbound", @"inbound" ]) {
        if (record[direction]) {
            [choices addObject:[NSString stringWithFormat:@"%@-%@", record[direction], direction]];
        }
    }
    return choices;
}
static inline NSDictionary *NSAppRuleBySelecting(id value, NSString *action) {
    NSDictionary *record = NSAppRuleRecord(value);
    if ([action isEqual:@"allow"] || [action isEqual:@"block"]) {
        return @{@"both" : action};
    }
    if (![NSDirectionRuleValues() containsObject:action]) {
        return record;
    }
    NSMutableDictionary *result = [record mutableCopy] ?: [NSMutableDictionary new];
    if (result[@"both"]) {
        result[@"inbound"] = result[@"both"];
        result[@"outbound"] = result[@"both"];
        [result removeObjectForKey:@"both"];
    }
    result[[action hasSuffix:@"-inbound"] ? @"inbound" : @"outbound"] =
        [action hasPrefix:@"allow"] ? @"allow" : @"block";
    return result;
}
static inline NSArray<NSString *> *NSConnectionRuleValues(NSString *direction) {
    if ([direction isEqual:@"inbound"]) {
        return @[ @"allow-inbound", @"block-inbound" ];
    }
    if ([direction isEqual:@"outbound"]) {
        return @[ @"allow-outbound", @"block-outbound" ];
    }
    return @[];
}
// Persistent editors toggle explicit choices; connection decisions never toggle.
static inline NSDictionary *NSAppRuleByTogglingSelection(id value, NSString *action) {
    NSDictionary *record = NSAppRuleRecord(value);
    if (![NSDirectionRuleValues() containsObject:action]) {
        return record;
    }
    if ([action isEqual:@"allow"] || [action isEqual:@"block"]) {
        return [record[@"both"] isEqual:action] ? nil : @{@"both" : action};
    }
    NSMutableDictionary *result =
        record[@"both"] ? [NSMutableDictionary new] : ([record mutableCopy] ?: [NSMutableDictionary new]);
    NSString *direction = [action hasSuffix:@"-inbound"] ? @"inbound" : @"outbound";
    NSString *decision = [action hasPrefix:@"allow"] ? @"allow" : @"block";
    if ([result[direction] isEqual:decision]) {
        [result removeObjectForKey:direction];
    } else {
        result[direction] = decision;
    }
    return result.count ? result : nil;
}
static inline NSString *NSAppRuleSummary(id value) {
    NSMutableArray *titles = [NSMutableArray new];
    for (NSString *action in NSAppRuleSelections(value)) {
        [titles addObject:NSDirectionRuleTitle(action)];
    }
    return titles.count ? [titles componentsJoinedByString:@" / "] : @"Default Rule";
}
