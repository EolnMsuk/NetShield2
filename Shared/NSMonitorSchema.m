#import "NSMonitorSchema.h"
#import "NSValidation.h"
#import "NSConstants.h"
#import "NSPermissionRequest.h"
#include <limits.h>

static NSDictionary *NSBadMonitor(NSError **error) {
    if (error) {
        *error = [NSError errorWithDomain:@"NetShield2.Monitor"
                                     code:1
                                 userInfo:@{
                                     NSLocalizedDescriptionKey :
                                         @"The provider report is corrupt or uses an unsupported schema."
                                 }];
    }
    return nil;
}
NSDictionary *NSValidateMonitor(id document, NSError **error) {
    if (![document isKindOfClass:NSDictionary.class]) {
        return NSBadMonitor(error);
    }
    NSDictionary *d = document;
    BOOL typed = [d[@"schema"] isEqual:@(NSMonitorSchemaVersion)];
    if (!NSUnsignedInteger(d[@"schema"], NSMonitorSchemaVersion) || (!typed && ![d[@"schema"] isEqual:@2]) ||
        ![d[@"updated"] isKindOfClass:NSDate.class] || ![d[@"lastReport"] isKindOfClass:NSDate.class] ||
        !NSBoolean(d[@"controlRunning"]) || !NSBoundedString(d[@"policyError"], 4096, NO) ||
        ![d[@"events"] isKindOfClass:NSArray.class] || [d[@"events"] count] > NSMaximumEvents) {
        return NSBadMonitor(error);
    }
    if (d[@"activityGenerations"] && !NSBoolean(d[@"activityGenerations"])) {
        return NSBadMonitor(error);
    }
    for (NSString *key in @[ @"notificationDeliveryIssue", @"dnsIssue" ]) {
        if (d[key] && !NSBoundedString(d[key], 4096, NO)) {
            return NSBadMonitor(error);
        }
    }
    for (NSString *key in @[ @"activation", @"session", @"revision", @"activityClearRevision" ]) {
        if (d[key] && !NSBoundedString(d[key], 128, NO)) {
            return NSBadMonitor(error);
        }
    }
    for (NSString *key in @[ @"overflowCount", @"evictedRequestCount", @"droppedWorkCount", @"engine" ]) {
        if (d[key] && !NSUnsignedInteger(d[key], ULLONG_MAX)) {
            return NSBadMonitor(error);
        }
    }
    NSMutableArray *events = [NSMutableArray new];
    for (id event in d[@"events"]) {
        if (![event isKindOfClass:NSDictionary.class]) {
            return NSBadMonitor(error);
        }
        NSDictionary *e = event;
        if (!NSBoundedString(e[@"identity"], NSMaximumIdentityLength, NO) ||
            !NSBoundedString(e[@"flow"], 128, NO) || !NSBoundedString(e[@"action"], 64, YES) ||
            ![@[ @"inbound", @"outbound", @"unknown" ] containsObject:e[@"direction"]] ||
            !NSUnsignedInteger(e[@"bytesIn"], ULLONG_MAX) || !NSUnsignedInteger(e[@"bytesOut"], ULLONG_MAX) ||
            !NSUnsignedInteger(e[@"event"], NSIntegerMax) || ![e[@"time"] isKindOfClass:NSDate.class] ||
            (e[@"destination"] && !NSValidDestination(e[@"destination"])) ||
            (e[@"activityGeneration"] && !NSBoundedString(e[@"activityGeneration"], 128, YES))) {
            return NSBadMonitor(error);
        }
        [events addObject:[e dictionaryWithValuesForKeys:@[
                    @"identity", @"flow", @"action", @"direction", @"bytesIn", @"bytesOut", @"event", @"time"
                ]]];
        NSMutableDictionary *canonical = [events.lastObject mutableCopy];
        if (e[@"destination"]) {
            canonical[@"destination"] = e[@"destination"];
        }
        if (e[@"activityGeneration"]) {
            canonical[@"activityGeneration"] = e[@"activityGeneration"];
        }
        events[events.count - 1] = [canonical copy];
    }
    id rawRequests = d[@"requests"] ?: @[];
    if (![rawRequests isKindOfClass:NSArray.class] ||
        [rawRequests count] > NSMaximumActiveRequests + NSMaximumRequestHistory) {
        return NSBadMonitor(error);
    }
    NSMutableSet *tokens = [NSMutableSet new];
    NSMutableArray *requests = [NSMutableArray new];
    NSUInteger active = 0, historical = 0, waiters = 0;
    for (id value in rawRequests) {
        if (![value isKindOfClass:NSDictionary.class]) {
            return NSBadMonitor(error);
        }
        NSDictionary *r = value;
        BOOL unidentified = NSUnidentifiedRequest(r);
        if ((unidentified && !typed) || (r[@"kind"] && !unidentified && ![r[@"kind"] isEqual:@"app"]) ||
            !NSBoundedString(r[@"token"], 128, YES) || [tokens containsObject:r[@"token"]] ||
            !NSBoundedString(r[@"identity"], NSMaximumIdentityLength, !unidentified) ||
            ![r[@"created"] isKindOfClass:NSDate.class] || ![r[@"expires"] isKindOfClass:NSDate.class] ||
            !NSUnsignedInteger(r[@"waiting"], NSMaximumWaiters) || !NSBoolean(r[@"expired"]) ||
            (r[@"destination"] && !NSValidDestination(r[@"destination"])) ||
            (r[@"direction"] && ![@[ @"inbound", @"outbound", @"unknown" ] containsObject:r[@"direction"]])) {
            return NSBadMonitor(error);
        }
        for (NSString *key in @[ @"askGeneration", @"session", @"activation" ]) {
            if (r[key] &&
                !NSBoundedString(
                    r[key], [key isEqual:@"askGeneration"] ? NSMaximumPermissionGenerationLength : 128, NO)) {
                return NSBadMonitor(error);
            }
        }
        if (unidentified) {
            NSDictionary *destination = r[@"destination"];
            NSString *direction = r[@"direction"];
            if ([r[@"identity"] length] || !direction || !destination ||
                ![destination isEqual:NSCanonicalConnectionDestination(destination)] ||
                ![r[@"fingerprint"] isEqual:NSConnectionFingerprint(destination, direction)] ||
                !NSBoolean(r[@"deferred"]) ||
                !NSBoundedString(r[@"askGeneration"], NSMaximumPermissionGenerationLength, NO) ||
                !NSBoundedString(d[@"activation"], 128, YES) ||
                ![r[@"activation"] isEqual:d[@"activation"]] || !NSBoundedString(d[@"session"], 128, YES) ||
                ![r[@"session"] isEqual:d[@"session"]] ||
                ![r[@"expires"] isEqual:[r[@"created"] dateByAddingTimeInterval:NSPermissionTimeout]]) {
                return NSBadMonitor(error);
            }
            BOOL once = !NSConnectionHasConditions(destination, direction);
            if (![r[@"mode"] isEqual:(once ? @"once" : @"rule")] ||
                (once ? !NSBoundedString(r[@"flow"], 128, NO) : r[@"flow"] != nil) ||
                [r[@"waiting"] unsignedIntegerValue] > (once ? 1 : NSMaximumWaitersPerIdentity)) {
                return NSBadMonitor(error);
            }
        } else if (r[@"fingerprint"] || r[@"mode"] || r[@"flow"] || r[@"deferred"]) {
            return NSBadMonitor(error);
        }
        if (typed) {
            NSUInteger count = [r[@"waiting"] unsignedIntegerValue];
            BOOL expired = [r[@"expired"] boolValue];
            if ((expired ? (count != 0 || ++historical > NSMaximumRequestHistory)
                         : (count == 0 || ++active > NSMaximumActiveRequests)) ||
                (waiters += count) > NSMaximumWaiters) {
                return NSBadMonitor(error);
            }
        }
        [tokens addObject:r[@"token"]];
        NSMutableDictionary *canonical = [NSMutableDictionary new];
        for (NSString *key in @[
                 @"token", @"identity", @"created", @"expires", @"waiting", @"expired", @"destination",
                 @"direction", @"askGeneration", @"session", @"activation", @"kind", @"fingerprint", @"mode",
                 @"flow", @"deferred"
             ]) {
            if (r[key]) {
                canonical[key] = r[key];
            }
        }
        // Supported schema-2 reports predate direction/generation metadata.
        canonical[@"direction"] = r[@"direction"] ?: @"unknown";
        [requests addObject:[canonical copy]];
    }
    id results = d[@"permissionResults"];
    if (results) {
        if (!typed || ![results isKindOfClass:NSArray.class] || [results count] > NSMaximumActiveRequests) {
            return NSBadMonitor(error);
        }
        NSMutableSet *completed = [NSMutableSet new];
        for (id result in results) {
            if (![result isKindOfClass:NSDictionary.class] || [result count] != 2 ||
                !NSBoundedString(result[@"token"], 128, YES) || [completed containsObject:result[@"token"]] ||
                [tokens containsObject:result[@"token"]] ||
                ![@[ @"allow", @"block" ] containsObject:result[@"action"]]) {
                return NSBadMonitor(error);
            }
            [completed addObject:result[@"token"]];
        }
    }
    NSMutableDictionary *canonical = [NSMutableDictionary new];
    for (NSString *key in @[
             @"schema", @"engine", @"activityGenerations", @"controlRunning", @"updated", @"lastReport",
             @"policyError", @"notificationDeliveryIssue", @"dnsIssue", @"activation", @"session",
             @"revision", @"activityClearRevision", @"overflowCount", @"evictedRequestCount",
             @"droppedWorkCount", @"permissionResults"
         ]) {
        if (d[key]) {
            canonical[key] = d[key];
        }
    }
    canonical[@"events"] = [events copy];
    canonical[@"requests"] = [requests copy];
    return [canonical copy];
}
