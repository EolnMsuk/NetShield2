#import "NSMonitorSchema.h"
#import "NSValidation.h"
#import "NSConstants.h"
#import "NSDestination.h"
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
    if (!NSUnsignedInteger(d[@"schema"], 2) || ![d[@"schema"] isEqual:@2] ||
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
    for (id value in rawRequests) {
        if (![value isKindOfClass:NSDictionary.class]) {
            return NSBadMonitor(error);
        }
        NSDictionary *r = value;
        if (!NSBoundedString(r[@"token"], 128, YES) || [tokens containsObject:r[@"token"]] ||
            !NSBoundedString(r[@"identity"], NSMaximumIdentityLength, YES) ||
            ![r[@"created"] isKindOfClass:NSDate.class] || ![r[@"expires"] isKindOfClass:NSDate.class] ||
            !NSUnsignedInteger(r[@"waiting"], NSMaximumWaiters) || !NSBoolean(r[@"expired"]) ||
            (r[@"destination"] && !NSValidDestination(r[@"destination"])) ||
            (r[@"direction"] && ![@[ @"inbound", @"outbound", @"unknown" ] containsObject:r[@"direction"]])) {
            return NSBadMonitor(error);
        }
        for (NSString *key in @[ @"askGeneration", @"session", @"activation" ]) {
            if (r[key] && !NSBoundedString(r[key], 128, NO)) {
                return NSBadMonitor(error);
            }
        }
        [tokens addObject:r[@"token"]];
        NSMutableDictionary *canonical = [NSMutableDictionary new];
        for (NSString *key in @[
                 @"token", @"identity", @"created", @"expires", @"waiting", @"expired", @"destination",
                 @"direction", @"askGeneration", @"session", @"activation"
             ]) {
            if (r[key]) {
                canonical[key] = r[key];
            }
        }
        // Supported schema-2 reports predate direction/generation metadata.
        canonical[@"direction"] = r[@"direction"] ?: @"unknown";
        [requests addObject:[canonical copy]];
    }
    NSMutableDictionary *canonical = [NSMutableDictionary new];
    for (NSString *key in @[
             @"schema", @"engine", @"activityGenerations", @"controlRunning", @"updated", @"lastReport",
             @"policyError", @"notificationDeliveryIssue", @"dnsIssue", @"activation", @"session",
             @"revision", @"activityClearRevision", @"overflowCount", @"evictedRequestCount",
             @"droppedWorkCount"
         ]) {
        if (d[key]) {
            canonical[key] = d[key];
        }
    }
    canonical[@"events"] = [events copy];
    canonical[@"requests"] = [requests copy];
    return [canonical copy];
}
