#import "NSStore.h"
#import "NSDestination.h"
#import "NSGlobalRule.h"
#import "NSPolicyCache.h"
#import "NSRuleChoices.h"
#include <errno.h>

NSString *const NSGroupIdentifier = @"group.com.eolnmsuk.netshield";
static NSError *NSStorageError(NSString *message) {
    return [NSError errorWithDomain:@"NetShield2.Storage"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}
#ifdef NS_TESTING
static NSURL *NSTestContainer;
void NSSetTestContainer(NSURL *url) {
    NSTestContainer = url;
    NSInvalidatePolicyCache();
}
#endif
NSURL *NSSharedURL(NSString *name) {
#ifdef NS_TESTING
    if (NSTestContainer) {
        return [NSTestContainer URLByAppendingPathComponent:name];
    }
#endif
    NSURL *root =
        [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:NSGroupIdentifier];
    return root ? [root URLByAppendingPathComponent:name] : nil;
}
NSDictionary *NSReadDocument(NSString *name, NSError **error) {
    NSURL *url = NSSharedURL(name);
    if (!url) {
        if (error) {
            *error = NSStorageError(@"The shared app-group container is unavailable. Check entitlements and "
                                    @"app/extension registration; filtering is not verified.");
        }
        return nil;
    }
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:error];
    if (!attributes) {
        return nil;
    }
    if ([attributes fileSize] > NSMaximumDocumentBytes) {
        if (error) {
            *error = NSStorageError(@"Shared document exceeds the 2 MiB limit.");
        }
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!data) {
        return nil;
    }
    id value = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListImmutable
                                                          format:NULL
                                                           error:error];
    if (![value isKindOfClass:NSDictionary.class]) {
        if (error) {
            *error = NSStorageError(@"Shared document is not a dictionary.");
        }
        return nil;
    }
    return value;
}
BOOL NSWriteDocument(NSDictionary *document, NSString *name, NSError **error) {
    NSURL *url = NSSharedURL(name);
    if (!url) {
        if (error) {
            *error = NSStorageError(@"The shared app-group container is unavailable.");
        }
        return NO;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:document
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:error];
    if (!data) {
        return NO;
    }
    if (data.length > NSMaximumDocumentBytes) {
        if (error) {
            *error = NSStorageError(@"Shared document exceeds the 2 MiB limit.");
        }
        return NO;
    }
    return [data writeToURL:url options:NSDataWritingAtomic | NSDataWritingFileProtectionNone error:error];
}
static NSPolicyCache *NSSharedPolicyCache(void) {
    static NSPolicyCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSPolicyCache new];
    });
    return cache;
}
void NSInvalidatePolicyCache(void) {
    [NSSharedPolicyCache() invalidate];
}
NSPolicy *NSReadPolicy(NSError **error) {
    NSURL *url = NSSharedURL(NSPolicyFile);
    if (!url) {
        NSInvalidatePolicyCache();
        if (error) {
            *error = NSStorageError(@"The shared app-group container is unavailable.");
        }
        return nil;
    }
    return [NSSharedPolicyCache() readURL:url error:error];
}
static NSStoreLock *NSAcquireLock(NSString *name, NSError **error) {
    NSURL *url = NSSharedURL(name);
    if (!url) {
        if (error) {
            *error = NSStorageError(@"The shared app-group container is unavailable.");
        }
        return nil;
    }
    return [NSStoreLock tryLockURL:url error:error];
}
NSStoreLock *NSAcquireProviderLock(NSError **error) {
    return NSAcquireLock(@"provider.lock", error);
}
static NSDictionary *NSReadActivityBoundary(NSError **error) {
    NSError *readError = nil;
    NSDictionary *boundary = NSReadDocument(NSActivityClearFile, &readError);
    if (!boundary &&
        (([readError.domain isEqual:NSPOSIXErrorDomain] && readError.code == ENOENT) ||
         ([readError.domain isEqual:NSCocoaErrorDomain] &&
          (readError.code == NSFileReadNoSuchFileError || readError.code == NSFileNoSuchFileError)))) {
        return @{};
    }
    if (![boundary[@"cutoff"] isKindOfClass:NSDate.class] ||
        ![boundary[@"revision"] isKindOfClass:NSString.class] || ![boundary[@"revision"] length]) {
        if (error) {
            *error = readError ?: NSStorageError(@"The saved activity clear boundary is unreadable.");
        }
        return nil;
    }
    return boundary;
}
static NSArray *NSActivityAfterBoundary(NSArray *events, NSDictionary *boundary) {
    if (![events isKindOfClass:NSArray.class]) {
        return @[];
    }
    NSDate *cutoff = boundary[@"cutoff"];
    if (![cutoff isKindOfClass:NSDate.class]) {
        return events ?: @[];
    }
    return [events filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *event,
                                                                                     NSDictionary *bindings) {
                       return [event isKindOfClass:NSDictionary.class] &&
                              [event[@"time"] isKindOfClass:NSDate.class] &&
                              [event[@"time"] compare:cutoff] == NSOrderedDescending;
                   }]]
               ?: @[];
}
NSArray<NSDictionary *> *NSActivityAfterClear(NSArray<NSDictionary *> *events) {
    // Retain the live buffer on read failure; publication will fail until the boundary is readable.
    return NSActivityAfterBoundary(events, NSReadActivityBoundary(NULL));
}
static NSDictionary *NSMonitorAfterBoundary(NSDictionary *snapshot, NSDictionary *boundary) {
    NSMutableDictionary *filtered = [snapshot mutableCopy];
    filtered[@"events"] = NSActivityAfterBoundary(snapshot[@"events"], boundary);
    if ([boundary[@"revision"] isKindOfClass:NSString.class]) {
        filtered[@"activityClearRevision"] = boundary[@"revision"];
    }
    return filtered;
}
BOOL NSWriteMonitorSnapshot(NSDictionary *snapshot, NSError **error) {
    __attribute__((objc_precise_lifetime)) NSStoreLock *lock = NSAcquireLock(@"activity.lock", error);
    if (!lock) {
        return NO;
    }
    @try {
        NSDictionary *boundary = NSReadActivityBoundary(error);
        return boundary && NSWriteDocument(NSMonitorAfterBoundary(snapshot, boundary), NSMonitorFile, error);
    } @finally {
        [lock unlock];
    }
}
BOOL NSClearActivity(NSError **error) {
    __attribute__((objc_precise_lifetime)) NSStoreLock *lock = NSAcquireLock(@"activity.lock", error);
    if (!lock) {
        return NO;
    }
    @try {
        NSDictionary *boundary = @{@"cutoff" : NSDate.date, @"revision" : NSUUID.UUID.UUIDString};
        // Persist first. Readers filter old snapshots even if publication or the provider is interrupted.
        if (!NSWriteDocument(boundary, NSActivityClearFile, error)) {
            return NO;
        }
        NSError *readError = nil;
        NSDictionary *snapshot = NSReadDocument(NSMonitorFile, &readError);
        if (!snapshot &&
            !(([readError.domain isEqual:NSPOSIXErrorDomain] && readError.code == ENOENT) ||
              ([readError.domain isEqual:NSCocoaErrorDomain] &&
               (readError.code == NSFileReadNoSuchFileError || readError.code == NSFileNoSuchFileError)))) {
            if (error) {
                *error = readError;
            }
            return NO;
        }
        return !snapshot || NSWriteDocument(NSMonitorAfterBoundary(snapshot, boundary), NSMonitorFile, error);
    } @finally {
        [lock unlock];
    }
}
BOOL NSEnsurePolicy(NSError **error) {
    __attribute__((objc_precise_lifetime)) NSStoreLock *lock = NSAcquireLock(@"policy.lock", error);
    if (!lock) {
        return NO;
    }
    @try {
        NSError *readError = nil;
        NSPolicy *existing = NSReadPolicy(&readError);
        if (existing) {
            NSDictionary *stored = NSReadDocument(NSPolicyFile, error);
            return stored && ([stored isEqual:existing.document] ||
                              NSWriteDocument(existing.document, NSPolicyFile, error));
        }
        if (![readError.domain isEqual:NSPOSIXErrorDomain] || readError.code != ENOENT) {
            if (error) {
                *error = readError;
            }
            return NO;
        }
        return NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, error);
    } @finally {
        [lock unlock];
    }
}
BOOL NSUpdatePolicy(BOOL (^mutation)(NSMutableDictionary *, NSError **), NSError **error) {
    __attribute__((objc_precise_lifetime)) NSStoreLock *lock = NSAcquireLock(@"policy.lock", error);
    if (!lock) {
        return NO;
    }
    @try {
        NSPolicy *current = NSReadPolicy(error);
        if (!current) {
            return NO;
        }
        NSMutableDictionary *document = [current.document mutableCopy];
        document[@"rules"] = [document[@"rules"] mutableCopy];
        if (!mutation(document, error)) {
            return NO;
        }
        // Existing legacy overlaps remain readable; every added/changed rule is checked atomically.
        NSDictionary *before = current.document[@"globalRules"] ?: @{};
        NSDictionary *after = document[@"globalRules"] ?: @{};
        if (![after isKindOfClass:NSDictionary.class]) {
            if (error) {
                *error = NSStorageError(@"Invalid global rules.");
            }
            return NO;
        }
        for (NSString *key in after) {
            if (!NSValidGlobalRuleKey(key) || ![after[key] isKindOfClass:NSString.class]) {
                if (error) {
                    *error = NSStorageError(@"Invalid global rule.");
                }
                return NO;
            }
            if (![after[key] isEqual:before[key]] &&
                !NSValidateGlobalRuleChange(after, key, after[key], key, error)) {
                return NO;
            }
        }
        NSMutableDictionary *destinations = [document[@"ruleDestinations"] mutableCopy];
        for (NSString *identity in destinations.allKeys) {
            if (!document[@"rules"][identity]) {
                [destinations removeObjectForKey:identity];
            }
        }
        if (destinations) {
            document[@"ruleDestinations"] = destinations;
        }
        NSDictionary *globalRules = NSGlobalRuleConditions(document[@"globalRules"]);
        NSMutableDictionary *addresses = [document[@"globalDomainAddresses"] mutableCopy];
        for (NSString *key in addresses.allKeys) {
            if (!globalRules[key] || [globalRules[key] isEqual:@"allow"]) {
                [addresses removeObjectForKey:key];
            }
        }
        if (addresses) {
            document[@"globalDomainAddresses"] = addresses;
        }
        NSMutableDictionary *expirations = [document[@"globalDomainExpirations"] mutableCopy];
        for (NSString *key in expirations.allKeys) {
            if (!addresses[key]) {
                [expirations removeObjectForKey:key];
            }
        }
        if (expirations) {
            document[@"globalDomainExpirations"] = expirations;
        }
        document[@"revision"] = NSUUID.UUID.UUIDString;
        NSPolicy *validated = [NSPolicy policyWithDocument:document error:error];
        return validated && NSWriteDocument(validated.document, NSPolicyFile, error);
    } @finally {
        [lock unlock];
    }
}
BOOL NSUseDefaultRule(NSMutableDictionary *document, NSString *identity, NSError **error) {
    NSMutableDictionary *generations = [document[@"askGenerations"] mutableCopy] ?: [NSMutableDictionary new];
    if (!generations[identity] && generations.count >= NSMaximumRules) {
        if (error) {
            *error = NSStorageError(@"The ask-again history is full. Reset Rules & History to clear it.");
        }
        return NO;
    }
    generations[identity] = NSUUID.UUID.UUIDString;
    document[@"askGenerations"] = generations;
    [document[@"rules"] removeObjectForKey:identity];
    return YES;
}
NSArray<NSString *> *NSClearIdentityRules(NSMutableDictionary *document, BOOL system, NSArray *events,
                                          NSError **error) {
    NSMutableSet *identities = [NSMutableSet setWithArray:[document[@"rules"] allKeys]];
    for (NSDictionary *event in events) {
        if ([event[@"identity"] length]) {
            [identities addObject:event[@"identity"]];
        }
    }
    NSMutableArray *removed = [NSMutableArray new];
    for (NSString *identity in identities) {
        if (NSIsAppleSystemIdentity(identity) != system) {
            continue;
        }
        if (!NSUseDefaultRule(document, identity, error)) {
            return nil;
        }
        [removed addObject:identity];
    }
    return removed;
}
BOOL NSResetSharedState(BOOL legacyProviderMayBeRunning, NSError **error) {
    return NSResetSharedStateWithOptions(legacyProviderMayBeRunning, NO, error);
}
BOOL NSResetSharedStateWithOptions(BOOL legacyProviderMayBeRunning, BOOL preserveSettings, NSError **error) {
    __attribute__((objc_precise_lifetime)) NSStoreLock *provider = NSAcquireProviderLock(error);
    if (!provider) {
        return NO;
    }
    @try {
        NSDictionary *monitor = NSReadMonitor();
        if ((legacyProviderMayBeRunning && (!monitor.count || [monitor[@"controlRunning"] boolValue])) ||
            ([monitor[@"controlRunning"] boolValue] && [monitor[@"engine"] integerValue] < 20014)) {
            if (error) {
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                             code:EBUSY
                                         userInfo:@{
                                             NSLocalizedDescriptionKey :
                                                 @"The previous provider has not confirmed shutdown. Turn "
                                                 @"Firewall on and off with this version, then retry reset."
                                         }];
            }
            return NO;
        }
        __attribute__((objc_precise_lifetime)) NSStoreLock *policy = NSAcquireLock(@"policy.lock", error);
        if (!policy) {
            return NO;
        }
        @try {
            NSMutableDictionary *replacement = [[NSPolicy defaultDocument] mutableCopy];
            if (preserveSettings) {
                NSPolicy *current = NSReadPolicy(error);
                if (!current) {
                    return NO;
                }
                replacement = [current.document mutableCopy];
                replacement[@"rules"] = @{};
                replacement[@"globalRules"] = @{};
                [replacement removeObjectForKey:@"globalDomainAddresses"];
                [replacement removeObjectForKey:@"globalDomainExpirations"];
                [replacement removeObjectForKey:@"ruleDestinations"];
                [replacement removeObjectForKey:@"askGenerations"];
                replacement[@"revision"] = NSUUID.UUID.UUIDString;
            }
            if (!NSWriteDocument(replacement, NSPolicyFile, error)) {
                return NO;
            }
            for (NSString *name in @[ NSMonitorFile, NSNotificationRetryFile, NSActivityClearFile ]) {
                NSError *removeError = nil;
                if (![NSFileManager.defaultManager removeItemAtURL:NSSharedURL(name) error:&removeError] &&
                    !([removeError.domain isEqual:NSCocoaErrorDomain] &&
                      removeError.code == NSFileNoSuchFileError)) {
                    if (error) {
                        *error = NSStorageError(
                            [NSString stringWithFormat:@"Rules were reset, but history cleanup failed: %@",
                                                       removeError.localizedDescription]);
                    }
                    return NO;
                }
            }
            return YES;
        } @finally {
            [policy unlock];
        }
    } @finally {
        [provider unlock];
    }
}
NSDictionary *NSReadMonitor(void) {
    NSDictionary *d = NSReadDocument(NSMonitorFile, NULL);
    if (![d[@"schema"] isEqual:@2] || ![d[@"updated"] isKindOfClass:NSDate.class] ||
        ![d[@"lastReport"] isKindOfClass:NSDate.class] ||
        ![d[@"controlRunning"] isKindOfClass:NSNumber.class] ||
        ![d[@"policyError"] isKindOfClass:NSString.class] || ![d[@"events"] isKindOfClass:NSArray.class] ||
        [d[@"events"] count] > NSMaximumEvents) {
        return @{};
    }
    for (id e in d[@"events"]) {
        if (![e isKindOfClass:NSDictionary.class]) {
            return @{};
        }
        for (NSString *key in @[ @"identity", @"action", @"direction", @"flow" ]) {
            if (![e[key] isKindOfClass:NSString.class]) {
                return @{};
            }
        }
        for (NSString *key in @[ @"bytesIn", @"bytesOut", @"event" ]) {
            if (![e[key] isKindOfClass:NSNumber.class]) {
                return @{};
            }
        }
        if ((e[@"destination"] && !NSValidDestination(e[@"destination"])) ||
            ![e[@"time"] isKindOfClass:NSDate.class]) {
            return @{};
        }
    }
    if (d[@"requests"]) {
        if (![d[@"requests"] isKindOfClass:NSArray.class] ||
            [d[@"requests"] count] > NSMaximumActiveRequests + NSMaximumRequestHistory) {
            return @{};
        }
        for (id request in d[@"requests"]) {
            if (![request isKindOfClass:NSDictionary.class] ||
                ![request[@"token"] isKindOfClass:NSString.class] ||
                ![request[@"identity"] isKindOfClass:NSString.class] ||
                ![request[@"created"] isKindOfClass:NSDate.class] ||
                ![request[@"expires"] isKindOfClass:NSDate.class] ||
                ![request[@"waiting"] isKindOfClass:NSNumber.class] ||
                ![request[@"expired"] isKindOfClass:NSNumber.class] ||
                (request[@"destination"] && !NSValidDestination(request[@"destination"])) ||
                (request[@"direction"] &&
                 ![@[ @"inbound", @"outbound", @"unknown" ] containsObject:request[@"direction"]])) {
                return @{};
            }
        }
    }
    if (d[@"notificationDeliveryIssue"] && ![d[@"notificationDeliveryIssue"] isKindOfClass:NSString.class]) {
        return @{};
    }
    for (NSString *key in @[ @"dnsIssue", @"activation", @"session" ]) {
        if (d[key] && ![d[key] isKindOfClass:NSString.class]) {
            return @{};
        }
    }
    for (NSString *key in @[ @"overflowCount", @"evictedRequestCount", @"engine" ]) {
        if (d[key] && ![d[key] isKindOfClass:NSNumber.class]) {
            return @{};
        }
    }
    NSDictionary *boundary = NSReadActivityBoundary(NULL);
    NSMutableDictionary *filtered = [NSMonitorAfterBoundary(d, boundary) mutableCopy];
    // Never expose pre-clear history while the persisted boundary cannot be read.
    if (!boundary) {
        filtered[@"events"] = @[];
    }
    return filtered;
}

BOOL NSAnswerPermissionRequest(NSDictionary *request, BOOL allow, NSError **error) {
    return NSAnswerPermissionRequestWithRule(request,
                                             [NSString stringWithFormat:@"%@-%@", allow ? @"allow" : @"block",
                                                                        request[@"direction"] ?: @"unknown"],
                                             error);
}
BOOL NSAnswerPermissionRequestWithRule(NSDictionary *request, NSString *rule, NSError **error) {
    if (![NSDirectionRuleValues() containsObject:rule ?: @""]) {
        if (error) {
            *error = NSStorageError(@"Unsupported permission rule.");
        }
        return NO;
    }
    return NSUpdatePolicy(
        ^BOOL(NSMutableDictionary *document, NSError **mutationError) {
            NSPolicy *policy = [NSPolicy policyWithDocument:document error:mutationError];
            if (!policy) {
                return NO;
            }
            NSDictionary *monitor = NSReadMonitor();
            NSDictionary *response = NSPermissionResponseDocument(request, monitor, policy, NSDate.date,
                                                                  [rule hasPrefix:@"allow"], mutationError);
            if (!response) {
                return NO;
            }
            NSString *direction = nil;
            for (NSDictionary *candidate in monitor[@"requests"]) {
                if ([candidate[@"token"] isEqual:request[@"token"]]) {
                    direction = candidate[@"direction"];
                }
            }
            if (![NSConnectionRuleValues(direction) containsObject:rule] ||
                (request[@"direction"] && ![request[@"direction"] isEqual:direction])) {
                if (mutationError) {
                    *mutationError =
                        NSStorageError(@"This connection changed direction. Review its current request.");
                }
                return NO;
            }
            [document setDictionary:response];
            return YES;
        },
        error);
}
NSDictionary *NSPermissionResponseDocument(NSDictionary *request, NSDictionary *monitor, NSPolicy *policy,
                                           NSDate *now, BOOL allow, NSError **error) {
    NSDate *updated = monitor[@"updated"];
    BOOL current = NO;
    NSDictionary *destination = nil;
    NSDictionary *currentRequest = nil;
    if ([request[@"token"] isKindOfClass:NSString.class] &&
        [request[@"identity"] isKindOfClass:NSString.class] && [monitor[@"controlRunning"] boolValue] &&
        updated && [updated timeIntervalSinceDate:now] <= 0 &&
        [updated timeIntervalSinceDate:now] > -NSMonitorFreshness) {
        for (NSDictionary *candidate in monitor[@"requests"]) {
            if ([candidate[@"token"] isEqual:request[@"token"]] &&
                [candidate[@"identity"] isEqual:request[@"identity"]]) {
                current = YES;
                currentRequest = candidate;
                destination = candidate[@"destination"];
                break;
            }
        }
    }
    if (!current) {
        if (error) {
            *error = NSStorageError(@"This request is no longer current or the filter is unavailable. Open "
                                    @"NetShield2 to review it.");
        }
        return nil;
    }
    for (NSDictionary *candidate in monitor[@"requests"]) {
        if ([candidate[@"token"] isEqual:request[@"token"]] &&
            ![(candidate[@"askGeneration"]
                   ?: @"") isEqual:(policy.document[@"askGenerations"][request[@"identity"]] ?: @"")]) {
            if (error) {
                *error = NSStorageError(@"This request was replaced by Ask Again. Retry the app.");
            }
            return nil;
        }
    }
    if (![policy requiresPermissionForRequest:currentRequest]) {
        if (error) {
            *error =
                NSStorageError(@"A rule already handles this app. Review its current rule in NetShield2.");
        }
        return nil;
    }
    NSMutableDictionary *document = [policy.document mutableCopy];
    NSMutableDictionary *rules = [document[@"rules"] mutableCopy];
    NSString *direction = currentRequest[@"direction"];
    NSString *action = [NSString stringWithFormat:@"%@-%@", allow ? @"allow" : @"block", direction];
    if (![NSConnectionRuleValues(direction) containsObject:action]) {
        if (error) {
            *error = NSStorageError(@"Connection direction is unavailable. Review the app rule.");
        }
        return nil;
    }
    rules[request[@"identity"]] = NSAppRuleBySelecting(rules[request[@"identity"]], action);
    document[@"rules"] = rules;
    if (NSValidDestination(destination)) {
        NSMutableDictionary *destinations =
            [document[@"ruleDestinations"] mutableCopy] ?: [NSMutableDictionary new];
        if (!destinations[request[@"identity"]]) {
            destinations[request[@"identity"]] = destination;
        }
        document[@"ruleDestinations"] = destinations;
    }
    document[@"revision"] = NSUUID.UUID.UUIDString;
    NSPolicy *validated = [NSPolicy policyWithDocument:document error:error];
    return validated.document;
}
