#import "NSStore.h"
#import "NSConfigurationRecord.h"
#import "NSDestination.h"
#import "NSGlobalRule.h"
#import "NSDNSCache.h"
#import "NSBoundedFile.h"
#import "NSMonitorSchema.h"
#import "NSValidation.h"
#import "NSRuleChoices.h"
#import "NSExport.h"
#include <errno.h>

static NSError *NSStorageError(NSString *message) {
    return [NSError errorWithDomain:@"NetShield2.Storage"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}
NSDictionary *NSReadDocumentIn(NSSharedDirectory *directory, NSString *name, NSError **error) {
    NSData *data = NSReadBoundedFile(directory, name, error);
    if (!data) {
        return nil;
    }
    NSError *parseError = nil;
    id value = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListImmutable
                                                          format:NULL
                                                           error:&parseError];
    if (![value isKindOfClass:NSDictionary.class]) {
        if (error) {
            NSMutableDictionary *info = [@{
                NSLocalizedDescriptionKey :
                    [NSString stringWithFormat:@"Decode document (%@): invalid dictionary.", name]
            } mutableCopy];
            info[NSUnderlyingErrorKey] = parseError;
            *error = [NSError errorWithDomain:@"NetShield2.Storage" code:1 userInfo:info];
        }
        return nil;
    }
    return value;
}
NSDictionary *NSReadDocument(NSString *name, NSError **error) {
    if (!NSKnownDocumentLeaf(name)) {
        NSFileFailure(@"Validate document name", @"unknown document", EINVAL, error);
        return nil;
    }
    NSSharedDirectory *directory = [NSSharedDirectory openRoot:NSSharedURL(@"") leaf:name error:error];
    return directory ? NSReadDocumentIn(directory, name, error) : nil;
}
static BOOL NSWriteDocumentWithDurability(NSSharedDirectory *directory, NSDictionary *document,
                                          NSString *name, BOOL durable, NSError **error) {
    if (!NSKnownDocumentLeaf(name)) {
        return NSFileFailure(@"Validate document name", @"unknown document", EINVAL, error);
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:document
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:error];
    return data && NSWriteBoundedFile(data, directory, name, durable, error);
}
static BOOL NSDocumentIsDurable(NSString *name) {
    return [@[ NSPolicyFile, NSActivityClearFile, NSPendingConfigurationFile, NSConfigurationRecoveryFile ]
        containsObject:name];
}
BOOL NSWriteDocumentIn(NSSharedDirectory *directory, NSDictionary *document, NSString *name,
                       NSError **error) {
    return NSWriteDocumentWithDurability(directory, document, name, NSDocumentIsDurable(name), error);
}
BOOL NSWriteDocument(NSDictionary *document, NSString *name, NSError **error) {
    if (!NSKnownDocumentLeaf(name)) {
        return NSFileFailure(@"Validate document name", @"unknown document", EINVAL, error);
    }
    NSSharedDirectory *directory = [NSSharedDirectory openRoot:NSSharedURL(@"") leaf:name error:error];
    return directory && NSWriteDocumentIn(directory, document, name, error);
}
static NSStoreLock *NSAcquireLock(NSString *name, NSError **error) {
    return [NSStoreLock tryLockRoot:NSSharedURL(@"") leaf:name error:error];
}
NSString *NSReadNotificationRetryRevision(void) {
    NSDictionary *document = NSReadDocument(NSNotificationRetryFile, NULL);
    return document.count == 1 && NSBoundedString(document[@"revision"], 128, YES) ? document[@"revision"]
                                                                                   : nil;
}
// A raw physical lock no longer grants admission while an app/helper owns a
// logical reservation. These callers cannot preempt configuration operations.
static BOOL NSUnownedConfigurationMutation(BOOL (^work)(NSSharedDirectory *, NSError **), NSError **error) {
    return NSConfigurationSection(
        ^NSStoreLock *(NSError **lockError) {
            return NSAcquireLock(NSConfigurationLockFile, lockError);
        },
        ^BOOL(NSSharedDirectory *directory, NSError **localError) {
            return NSConfigurationAdmission(directory, nil, localError) && work(directory, localError);
        },
        error);
}
BOOL NSWriteNotificationRetryRevision(NSError **error) {
    return NSUnownedConfigurationMutation(
        ^BOOL(NSSharedDirectory *directory, NSError **localError) {
            return NSWriteDocumentIn(directory, @{@"revision" : NSUUID.UUID.UUIDString},
                                     NSNotificationRetryFile, localError);
        },
        error);
}
NSStoreLock *NSAcquireProviderLock(NSError **error) {
    return NSAcquireLock(@"provider.lock", error);
}
static BOOL NSRemoveSavedEntry(NSSharedDirectory *directory, NSString *name, NSError **error) {
    if (![name isEqual:NSExportCacheDirectory]) {
        return NSUnlinkBoundedFile(directory, name, error);
    }
    if (![directory validateForLeaf:name error:error]) {
        return NO;
    }
    NSURL *url = NSExportCacheURL(directory.root, NO, error);
    if (!url || ![directory validateForLeaf:name error:error]) {
        return NO;
    }
    NSError *removeError = nil;
    if ([NSFileManager.defaultManager removeItemAtURL:url error:&removeError] ||
        ([removeError.domain isEqual:NSCocoaErrorDomain] && removeError.code == NSFileNoSuchFileError)) {
        return [directory validateForLeaf:name error:error];
    }
    if (error) {
        *error = [NSError errorWithDomain:removeError.domain
                                     code:removeError.code
                                 userInfo:@{
                                     NSLocalizedDescriptionKey : @"Remove the shared export cache failed.",
                                     NSUnderlyingErrorKey : removeError
                                 }];
    }
    return NO;
}
BOOL NSRemoveSharedStateAfterFilterRemoval(NSError **error) {
    return NSUnownedConfigurationMutation(
        ^BOOL(NSSharedDirectory *directory, NSError **localError) {
            return NSRemoveSharedStateIn(directory, localError);
        },
        error);
}
BOOL NSRemoveSharedStateIn(NSSharedDirectory *directory, NSError **error) {
    // This order matches reset: provider first prevents a control provider from
    // publishing while policy and activity documents are removed.
    __attribute__((objc_precise_lifetime)) NSStoreLock *provider =
        [NSStoreLock tryLockInDirectory:directory leaf:@"provider.lock" error:error];
    if (!provider) {
        return NO;
    }
    @try {
        __attribute__((objc_precise_lifetime)) NSStoreLock *policy =
            [NSStoreLock tryLockInDirectory:directory leaf:@"policy.lock" error:error];
        if (!policy) {
            return NO;
        }
        @try {
            __attribute__((objc_precise_lifetime)) NSStoreLock *activity =
                [NSStoreLock tryLockInDirectory:directory leaf:@"activity.lock" error:error];
            if (!activity) {
                return NO;
            }
            @try {
                __attribute__((objc_precise_lifetime)) NSStoreLock *exports =
                    [NSStoreLock tryLockInDirectory:directory leaf:@"exports.lock" error:error];
                if (!exports) {
                    return NO;
                }
                @try {
                    NSMutableArray *cleared = [NSMutableArray new];
                    for (NSString *name in @[
                             NSPolicyFile, NSMonitorFile, NSNotificationRetryFile, NSActivityClearFile,
                             NSExportCacheDirectory
                         ]) {
                        NSError *removeError = nil;
                        if (!NSRemoveSavedEntry(directory, name, &removeError)) {
                            if (error) {
                                *error = [NSError
                                    errorWithDomain:@"NetShield2.Storage"
                                               code:2
                                           userInfo:@{
                                               NSLocalizedDescriptionKey : [NSString
                                                   stringWithFormat:@"Filter preferences are removed; "
                                                                    @"saved-state cleanup stopped at %@: %@",
                                                                    name, removeError.localizedDescription],
                                               @"clearedEntries" : [cleared copy],
                                               @"cleanupComplete" : @NO,
                                               NSUnderlyingErrorKey : removeError
                                                   ?: NSStorageError(@"Cleanup path unavailable.")
                                           }];
                            }
                            return NO;
                        }
                        [cleared addObject:name];
                    }
                    return YES;
                } @finally {
                    [exports unlock];
                }
            } @finally {
                [activity unlock];
            }
        } @finally {
            [policy unlock];
        }
    } @finally {
        [provider unlock];
        NSInvalidatePolicyCache();
    }
}
static NSDictionary *NSReadActivityBoundary(NSSharedDirectory *directory, NSError **error) {
    NSError *readError = nil;
    NSDictionary *boundary = directory ? NSReadDocumentIn(directory, NSActivityClearFile, &readError)
                                       : NSReadDocument(NSActivityClearFile, &readError);
    if (!boundary && NSFileIsAbsent(readError)) {
        return @{};
    }
    if (![boundary[@"cutoff"] isKindOfClass:NSDate.class] ||
        !NSBoundedString(boundary[@"revision"], 128, YES) ||
        (boundary[@"schema"] && ![boundary[@"schema"] isEqual:@2]) ||
        (boundary[@"schema"] && !NSBoundedString(boundary[@"generation"], 128, YES))) {
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
    if ([boundary[@"schema"] isEqual:@2]) {
        return [events filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(
                                                                    id event, NSDictionary *bindings) {
                           return [event isKindOfClass:NSDictionary.class] &&
                                  [event[@"activityGeneration"] isEqual:boundary[@"generation"]];
                       }]];
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
NSDictionary *NSActivityEventWithCurrentBoundary(NSDictionary *event) {
    NSDictionary *boundary = NSReadActivityBoundary(nil, NULL);
    if (!boundary) {
        return nil;
    }
    NSMutableDictionary *stamped = [event mutableCopy];
    stamped[@"activityGeneration"] = boundary[@"generation"] ?: @"initial";
    return [stamped copy];
}
NSArray<NSDictionary *> *NSActivityAfterClear(NSArray<NSDictionary *> *events) {
    // Retain the live buffer on read failure; publication will fail until the boundary is readable.
    return NSActivityAfterBoundary(events, NSReadActivityBoundary(nil, NULL));
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
        NSDictionary *boundary = NSReadActivityBoundary(lock.directory, error);
        NSDictionary *validated = boundary ? NSValidateMonitor(snapshot, error) : nil;
        return validated && NSWriteDocumentIn(lock.directory, NSMonitorAfterBoundary(validated, boundary),
                                              NSMonitorFile, error);
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
        NSSharedDirectory *directory = lock.directory;
        NSDictionary *current = NSReadDocumentIn(directory, NSMonitorFile, NULL);
        NSString *revision = NSUUID.UUID.UUIDString;
        NSMutableDictionary *boundary = [@{@"cutoff" : NSDate.date, @"revision" : revision} mutableCopy];
        // Legacy providers have no generation tags: retain their cutoff contract.
        // Missing/offline reports use the new contract for the next provider.
        if (!current || [current[@"activityGenerations"] isEqual:@YES] ||
            [NSReadActivityBoundary(directory, NULL)[@"schema"] isEqual:@2]) {
            boundary[@"schema"] = @2;
            boundary[@"generation"] = revision;
        }
        // Persist first. Readers filter old snapshots even if publication or the provider is interrupted.
        if (!NSWriteDocumentIn(directory, boundary, NSActivityClearFile, error)) {
            return NO;
        }
        NSError *readError = nil;
        NSDictionary *snapshot = NSReadDocumentIn(directory, NSMonitorFile, &readError);
        if (!snapshot && !NSFileIsAbsent(readError)) {
            if (error) {
                *error = readError;
            }
            return NO;
        }
        return !snapshot ||
               NSWriteDocumentIn(directory, NSMonitorAfterBoundary(snapshot, boundary), NSMonitorFile, error);
    } @finally {
        [lock unlock];
    }
}
BOOL NSEnsurePolicy(NSError **error) {
    NSSharedDirectory *directory = [NSSharedDirectory openRoot:NSSharedURL(@"")
                                                          leaf:NSPolicyFile
                                                         error:error];
    return directory && NSEnsurePolicyIn(directory, error);
}
BOOL NSEnsurePolicyIn(NSSharedDirectory *directory, NSError **error) {
    __attribute__((objc_precise_lifetime)) NSStoreLock *lock = [NSStoreLock tryLockInDirectory:directory
                                                                                          leaf:@"policy.lock"
                                                                                         error:error];
    if (!lock) {
        return NO;
    }
    @try {
        NSError *readError = nil;
        NSPolicy *existing = NSReadPolicyIn(directory, &readError);
        if (existing) {
            NSDictionary *stored = NSReadDocumentIn(directory, NSPolicyFile, error);
            return stored && ([stored isEqual:existing.document] ||
                              NSWriteDocumentIn(directory, existing.document, NSPolicyFile, error));
        }
        if (!NSFileIsAbsent(readError)) {
            if (error) {
                *error = readError;
            }
            return NO;
        }
        return NSWriteDocumentIn(directory, [NSPolicy defaultDocument], NSPolicyFile, error);
    } @finally {
        [lock unlock];
    }
}
static BOOL NSUpdatePolicyWithDurability(BOOL (^mutation)(NSMutableDictionary *, NSError **), BOOL durable,
                                         NSError **error) {
    __attribute__((objc_precise_lifetime)) NSStoreLock *lock = NSAcquireLock(@"policy.lock", error);
    if (!lock) {
        return NO;
    }
    @try {
        NSPolicy *current = NSReadPolicyIn(lock.directory, error);
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
        if (![before isEqual:after]) {
            document[@"globalRuleGeneration"] = NSUUID.UUID.UUIDString;
            [document removeObjectForKey:@"globalDomainAddresses"];
            [document removeObjectForKey:@"globalDomainExpirations"];
            [document removeObjectForKey:@"globalDomainLifetimes"];
        }
        NSDictionary *globalRules = NSGlobalRuleConditions(document[@"globalRules"]);
        NSMutableDictionary *addresses = [document[@"globalDomainAddresses"] mutableCopy];
        for (NSString *key in addresses.allKeys) {
            if (!globalRules[key] || NSGlobalActionIsAllow(globalRules[key])) {
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
        NSMutableDictionary *lifetimes = [document[@"globalDomainLifetimes"] mutableCopy];
        for (NSString *key in lifetimes.allKeys) {
            if (!addresses[key]) {
                [lifetimes removeObjectForKey:key];
            }
        }
        if (lifetimes) {
            document[@"globalDomainLifetimes"] = lifetimes;
        }
        document[@"revision"] = NSUUID.UUID.UUIDString;
        NSPolicy *validated = [NSPolicy policyWithDocument:document error:error];
        return validated && NSWriteDocumentWithDurability(lock.directory, validated.document, NSPolicyFile,
                                                          durable, error);
    } @finally {
        [lock unlock];
    }
}
BOOL NSUpdatePolicy(BOOL (^mutation)(NSMutableDictionary *, NSError **), NSError **error) {
    return NSUpdatePolicyWithDurability(mutation, YES, error);
}
BOOL NSUpdateResolvedDNS(NSDictionary *pending, BOOL invalidate, NSError **error) {
    return NSUpdatePolicyWithDurability(
        ^BOOL(NSMutableDictionary *document, NSError **mutationError) {
            BOOL hadAnswers = [document[@"globalDomainAddresses"] count] > 0;
            if (invalidate) {
                [document removeObjectForKey:@"globalDomainAddresses"];
                [document removeObjectForKey:@"globalDomainExpirations"];
                [document removeObjectForKey:@"globalDomainLifetimes"];
            }
            return NSApplyDNSResults(document, pending, NSDate.date) || (invalidate && hadAnswers);
        },
        NO, error);
}
BOOL NSUseDefaultRule(NSMutableDictionary *document, NSString *identity, NSError **error) {
    NSMutableDictionary *generations = [document[@"askGenerations"] mutableCopy] ?: [NSMutableDictionary new];
    if (!generations[identity] && generations.count >= NSMaximumRules) {
        if (error) {
            *error = NSStorageError(@"The ask-again history is full. Use Reset Settings to clear it.");
        }
        return NO;
    }
    generations[identity] = NSUUID.UUID.UUIDString;
    document[@"askGenerations"] = generations;
    [document[@"rules"] removeObjectForKey:identity];
    return YES;
}
BOOL NSToggleAppRule(NSMutableDictionary *document, NSString *identity, NSString *action, NSError **error) {
    if (![NSDirectionRuleValues() containsObject:action]) {
        if (error) {
            *error = NSStorageError(@"Unknown app rule selection.");
        }
        return NO;
    }
    NSDictionary *previous = NSAppRuleRecord(document[@"rules"][identity]);
    NSDictionary *next = NSAppRuleByTogglingSelection(previous, action);
    BOOL exposesDefault = !next;
    for (NSString *direction in @[ @"inbound", @"outbound" ]) {
        if ((previous[@"both"] || previous[direction]) && !next[@"both"] && !next[direction]) {
            exposesDefault = YES;
        }
    }
    // Invalidate pending tokens/history before restoring any remaining explicit direction.
    if (exposesDefault && !NSUseDefaultRule(document, identity, error)) {
        return NO;
    }
    if (next) {
        document[@"rules"][identity] = next;
    }
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
    return NSUnownedConfigurationMutation(
        ^BOOL(NSSharedDirectory *directory, NSError **localError) {
            return NSResetSharedStateIn(directory, legacyProviderMayBeRunning, preserveSettings, localError);
        },
        error);
}

BOOL NSResetSharedStateIn(NSSharedDirectory *directory, BOOL legacyProviderMayBeRunning,
                          BOOL preserveSettings, NSError **error) {
    __attribute__((objc_precise_lifetime)) NSStoreLock *provider =
        [NSStoreLock tryLockInDirectory:directory leaf:@"provider.lock" error:error];
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
        __attribute__((objc_precise_lifetime)) NSStoreLock *policy =
            [NSStoreLock tryLockInDirectory:directory leaf:@"policy.lock" error:error];
        if (!policy) {
            return NO;
        }
        @try {
            __attribute__((objc_precise_lifetime)) NSStoreLock *activity =
                [NSStoreLock tryLockInDirectory:directory leaf:@"activity.lock" error:error];
            if (!activity) {
                return NO;
            }
            @try {
                __attribute__((objc_precise_lifetime)) NSStoreLock *exports =
                    [NSStoreLock tryLockInDirectory:directory leaf:@"exports.lock" error:error];
                if (!exports) {
                    return NO;
                }
                @try {
                    NSMutableDictionary *replacement = [[NSPolicy defaultDocument] mutableCopy];
                    if (preserveSettings) {
                        NSPolicy *current = NSReadPolicyIn(directory, error);
                        if (!current) {
                            return NO;
                        }
                        replacement = [current.document mutableCopy];
                        replacement[@"rules"] = @{};
                        replacement[@"globalRules"] = @{};
                        [replacement removeObjectForKey:@"globalDomainAddresses"];
                        [replacement removeObjectForKey:@"globalDomainExpirations"];
                        [replacement removeObjectForKey:@"globalDomainLifetimes"];
                        [replacement removeObjectForKey:@"ruleDestinations"];
                        [replacement removeObjectForKey:@"askGenerations"];
                        replacement[@"revision"] = NSUUID.UUID.UUIDString;
                    }
                    if (!NSWriteDocumentIn(directory, replacement, NSPolicyFile, error)) {
                        return NO;
                    }
                    for (NSString *name in @[
                             NSMonitorFile, NSNotificationRetryFile, NSActivityClearFile,
                             NSExportCacheDirectory
                         ]) {
                        NSError *removeError = nil;
                        if (!NSRemoveSavedEntry(directory, name, &removeError)) {
                            if (error) {
                                *error = [NSError
                                    errorWithDomain:@"NetShield2.Storage"
                                               code:2
                                           userInfo:@{
                                               NSLocalizedDescriptionKey : [NSString
                                                   stringWithFormat:
                                                       @"Rules were reset; cleanup stopped at %@: %@", name,
                                                       removeError.localizedDescription],
                                               @"policyReset" : @YES,
                                               @"cleanupComplete" : @NO,
                                               NSUnderlyingErrorKey : removeError
                                                   ?: NSStorageError(@"Cleanup path unavailable.")
                                           }];
                            }
                            return NO;
                        }
                    }
                    return YES;
                } @finally {
                    [exports unlock];
                }
            } @finally {
                [activity unlock];
            }
        } @finally {
            [policy unlock];
        }
    } @finally {
        [provider unlock];
    }
}
NSDictionary *NSReadMonitor(void) {
    return NSReadMonitorWithError(NULL) ?: @{};
}
NSDictionary *NSReadMonitorWithError(NSError **error) {
    NSDictionary *raw = NSReadDocument(NSMonitorFile, error);
    if (!raw) {
        return nil;
    }
    NSDictionary *d = NSValidateMonitor(raw, error);
    if (!d) {
        return nil;
    }
    NSDictionary *boundary = NSReadActivityBoundary(nil, NULL);
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
    return NSUnownedConfigurationMutation(
        ^BOOL(NSSharedDirectory *directory, NSError **localError) {
            return NSUpdatePolicy(
                ^BOOL(NSMutableDictionary *document, NSError **mutationError) {
                    NSPolicy *policy = [NSPolicy policyWithDocument:document error:mutationError];
                    if (!policy) {
                        return NO;
                    }
                    NSDictionary *monitor = NSReadMonitor();
                    NSDictionary *response = NSPermissionResponseDocument(
                        request, monitor, policy, NSDate.date, [rule hasPrefix:@"allow"], mutationError);
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
                            *mutationError = NSStorageError(
                                @"This connection changed direction. Review its current request.");
                        }
                        return NO;
                    }
                    [document setDictionary:response];
                    return YES;
                },
                localError);
        },
        error);
}

NSDictionary *NSPermissionResponseDocument(NSDictionary *request, NSDictionary *monitor, NSPolicy *policy,
                                           NSDate *now, BOOL allow, NSError **error) {
    if (![request isKindOfClass:NSDictionary.class] || ![monitor isKindOfClass:NSDictionary.class] ||
        !NSBoundedString(request[@"token"], 128, YES) ||
        !NSBoundedString(request[@"identity"], NSMaximumIdentityLength, YES)) {
        if (error) {
            *error = NSStorageError(@"Invalid permission response payload.");
        }
        return nil;
    }
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
    for (NSString *key in @[ @"session", @"activation" ]) {
        if ([monitor[key] length] && ![request[key] isEqual:monitor[key]]) {
            if (error) {
                *error = NSStorageError(
                    @"This request belongs to an earlier provider activation. Review its current request.");
            }
            return nil;
        }
    }
    if (request[@"askGeneration"] &&
        ![request[@"askGeneration"] isEqual:currentRequest[@"askGeneration"] ?: @""]) {
        if (error) {
            *error = NSStorageError(@"This permission request generation is no longer current.");
        }
        return nil;
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
