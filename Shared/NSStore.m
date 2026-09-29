#import "NSStore.h"
#import "NSDestination.h"
#import "NSPolicyCache.h"
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
BOOL NSEnsurePolicy(NSError **error) {
    __attribute__((objc_precise_lifetime)) NSStoreLock *lock = NSAcquireLock(@"policy.lock", error);
    if (!lock) {
        return NO;
    }
    @try {
        NSError *readError = nil;
        if (NSReadPolicy(&readError)) {
            return YES;
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
        // Remove stale context when a manually edited rule is deleted.
        NSMutableDictionary *destinations = [document[@"ruleDestinations"] mutableCopy];
        for (NSString *identity in destinations.allKeys) {
            if (!document[@"rules"][identity]) {
                [destinations removeObjectForKey:identity];
            }
        }
        if (destinations) {
            document[@"ruleDestinations"] = destinations;
        }
        document[@"revision"] = NSUUID.UUID.UUIDString;
        NSPolicy *validated = [NSPolicy policyWithDocument:document error:error];
        return validated && NSWriteDocument(validated.document, NSPolicyFile, error);
    } @finally {
        [lock unlock];
    }
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
        // Older providers did not hold the lifetime lock. Require their explicit stop report.
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
                replacement[@"allowAppleSystemProcesses"] = @YES;
                replacement[@"filterSockets"] = @YES;
                [replacement removeObjectForKey:@"ruleDestinations"];
                replacement[@"revision"] = NSUUID.UUID.UUIDString;
            }
            if (!NSWriteDocument(replacement, NSPolicyFile, error)) {
                return NO;
            }
            for (NSString *name in @[ NSMonitorFile, NSNotificationRetryFile ]) {
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
                (request[@"destination"] && !NSValidDestination(request[@"destination"]))) {
                return @{};
            }
        }
    }
    if (d[@"notificationDeliveryIssue"] && ![d[@"notificationDeliveryIssue"] isKindOfClass:NSString.class]) {
        return @{};
    }
    for (NSString *key in @[ @"overflowCount", @"evictedRequestCount", @"engine" ]) {
        if (d[key] && ![d[key] isKindOfClass:NSNumber.class]) {
            return @{};
        }
    }
    return d;
}

BOOL NSAnswerPermissionRequest(NSDictionary *request, BOOL allow, NSError **error) {
    return NSAnswerPermissionRequestWithRule(request, allow ? @"allow" : @"block", error);
}
BOOL NSAnswerPermissionRequestWithRule(NSDictionary *request, NSString *rule, NSError **error) {
    if (![@[ @"allow", @"block", @"block-inbound" ] containsObject:rule ?: @""]) {
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
            NSDictionary *response = NSPermissionResponseDocument(
                request, NSReadMonitor(), policy, NSDate.date, [rule isEqual:@"allow"], mutationError);
            if (!response) {
                return NO;
            }
            [document setDictionary:response];
            NSMutableDictionary *rules = [document[@"rules"] mutableCopy];
            rules[request[@"identity"]] = rule;
            document[@"rules"] = rules;
            return YES;
        },
        error);
}
NSDictionary *NSPermissionResponseDocument(NSDictionary *request, NSDictionary *monitor, NSPolicy *policy,
                                           NSDate *now, BOOL allow, NSError **error) {
    NSDate *updated = monitor[@"updated"];
    BOOL current = NO;
    NSDictionary *destination = nil;
    if ([request[@"token"] isKindOfClass:NSString.class] &&
        [request[@"identity"] isKindOfClass:NSString.class] && [monitor[@"controlRunning"] boolValue] &&
        updated && [updated timeIntervalSinceDate:now] <= 0 &&
        [updated timeIntervalSinceDate:now] > -NSMonitorFreshness) {
        for (NSDictionary *candidate in monitor[@"requests"]) {
            if ([candidate[@"token"] isEqual:request[@"token"]] &&
                [candidate[@"identity"] isEqual:request[@"identity"]]) {
                current = YES;
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
    if (![policy requiresPermissionForIdentity:request[@"identity"]]) {
        if (error) {
            *error =
                NSStorageError(@"A rule already handles this app. Review its current rule in NetShield2.");
        }
        return nil;
    }
    NSMutableDictionary *document = [policy.document mutableCopy];
    NSMutableDictionary *rules = [document[@"rules"] mutableCopy];
    rules[request[@"identity"]] = allow ? @"allow" : @"block";
    document[@"rules"] = rules;
    if (NSValidDestination(destination)) {
        NSMutableDictionary *destinations =
            [document[@"ruleDestinations"] mutableCopy] ?: [NSMutableDictionary new];
        destinations[request[@"identity"]] = destination;
        document[@"ruleDestinations"] = destinations;
    }
    document[@"revision"] = NSUUID.UUID.UUIDString;
    NSPolicy *validated = [NSPolicy policyWithDocument:document error:error];
    return validated.document;
}
