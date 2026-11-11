#import "NSStore.h"
#import "NSConfigurationRecord.h"
#import "NSDestination.h"
#import "NSGlobalRule.h"
#import "NSDNSCache.h"
#import "NSBoundedFile.h"
#import "NSMonitorSchema.h"
#import "NSValidation.h"
#import "NSRuleChoices.h"
#import "NSPermissionRequest.h"
#import "NSProviderHealth.h"
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
                             NSPermissionResponsesFile, NSExportCacheDirectory
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
    return NSEnsureCompatiblePolicyIn(directory, NO, error);
}
BOOL NSEnsureCompatiblePolicyIn(NSSharedDirectory *directory, BOOL legacyActive, NSError **error) {
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
        NSMutableDictionary *defaults = [[NSPolicy defaultDocument] mutableCopy];
        if (legacyActive) {
            defaults[@"schema"] = @3;
        }
        return NSWriteDocumentIn(directory, defaults, NSPolicyFile, error);
    } @finally {
        [lock unlock];
    }
}
BOOL NSSetUnidentifiedMode(NSMutableDictionary *document, NSString *mode, BOOL preferencesLoaded,
                           BOOL enabled, NSInteger configuredEngine, NSString *activation, NSError **error) {
    if ([mode isEqual:@"ask"]) {
        NSDictionary *monitor = NSReadMonitor();
        NSDate *now = NSDate.date;
        NSTimeInterval age = [now timeIntervalSinceDate:monitor[@"updated"] ?: NSDate.distantPast];
        BOOL running =
            enabled || ([monitor[@"controlRunning"] boolValue] && age >= 0 && age < NSMonitorFreshness);
        if (!preferencesLoaded || (running && (configuredEngine != NSEngineVersion ||
                                               ![monitor[@"engine"] isEqual:@(NSEngineVersion)] ||
                                               ![monitor[@"schema"] isEqual:@(NSMonitorSchemaVersion)] ||
                                               !NSHasCurrentControlHeartbeat(monitor, activation, now)))) {
            if (error) {
                *error = NSStorageError(@"Unidentified Ask Me needs the current filter activation. "
                                        @"Restart Firewall or turn it off, then try again.");
            }
            return NO;
        }
        document[@"schema"] = @(NSSchemaVersion);
    }
    document[@"unattributed"] = mode;
    return YES;
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
        if ([document[@"schema"] isEqual:@(NSSchemaVersion)] &&
            ![document[@"unattributed"] isEqual:current.document[@"unattributed"]]) {
            document[@"unidentifiedAskGeneration"] = NSUUID.UUID.UUIDString;
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
                        if (replacement[@"unidentifiedAskGeneration"]) {
                            replacement[@"unidentifiedAskGeneration"] = NSUUID.UUID.UUIDString;
                        }
                        replacement[@"revision"] = NSUUID.UUID.UUIDString;
                    }
                    if (!NSWriteDocumentIn(directory, replacement, NSPolicyFile, error)) {
                        return NO;
                    }
                    for (NSString *name in @[
                             NSMonitorFile, NSNotificationRetryFile, NSActivityClearFile,
                             NSPermissionResponsesFile, NSExportCacheDirectory
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

static NSDictionary *NSPermissionError(NSError **error, NSString *message) {
    if (error) {
        *error = NSStorageError(message);
    }
    return nil;
}

static NSDictionary *NSCurrentPermissionRequest(NSDictionary *request, NSDictionary *monitor,
                                                NSPolicy *policy, NSDate *now, NSError **error) {
    if (![request isKindOfClass:NSDictionary.class] || !NSBoundedString(request[@"token"], 128, YES) ||
        !NSBoundedString(request[@"identity"], NSMaximumIdentityLength, !NSUnidentifiedRequest(request))) {
        return NSPermissionError(error, @"Invalid permission response payload.");
    }
    NSDate *updated = monitor[@"updated"];
    NSTimeInterval age = [now timeIntervalSinceDate:updated ?: NSDate.distantPast];
    if ([monitor[@"controlRunning"] boolValue] && age >= 0 && age < NSMonitorFreshness) {
        for (NSDictionary *current in monitor[@"requests"]) {
            if (![current[@"token"] isEqual:request[@"token"]]) {
                continue;
            }
            if (!NSPermissionPresentationMatches(request, current) ||
                ![(monitor[@"session"] ?: @"") isEqual:(current[@"session"] ?: @"")] ||
                ![(monitor[@"activation"] ?: @"") isEqual:(current[@"activation"] ?: @"")] ||
                (NSUnidentifiedRequest(current) && ![monitor[@"engine"] isEqual:@(NSEngineVersion)])) {
                break;
            }
            if (!NSPermissionGenerationMatches(policy, current)) {
                return NSPermissionError(error, @"This request was replaced. Retry the connection.");
            }
            if (![policy requiresPermissionForRequest:current]) {
                return NSPermissionError(error, @"A policy change already handles this connection.");
            }
            return current;
        }
    }
    return NSPermissionError(error, @"This request is no longer current or the filter is unavailable. "
                                    @"Open NetShield2 to review it.");
}

static NSDictionary *NSPermissionPolicyWithDecision(NSDictionary *current, NSPolicy *policy, NSString *rule,
                                                    NSError **error) {
    if (![NSPermissionRuleValues(current) containsObject:rule]) {
        return NSPermissionError(error, @"That decision does not apply to this request's direction.");
    }
    NSMutableDictionary *document = [policy.document mutableCopy];
    NSString *identity = current[@"identity"];
    NSDictionary *destination = current[@"destination"] ?: @{};
    if (NSUnidentifiedRequest(current)) {
        if (![current[@"mode"] isEqual:@"rule"]) {
            return NSPermissionError(error, @"This connection only supports a one-time decision.");
        }
        NSString *key = NSExactGlobalRuleKey(@[], destination, NSGlobalCoverage(rule));
        NSMutableDictionary *global = [document[@"globalRules"] mutableCopy];
        if (!key) {
            return NSPermissionError(error, @"The requested rule could not be encoded.");
        }
        if (!NSValidateGlobalRuleChange(global, key, rule, nil, error)) {
            return nil;
        }
        global[key] = rule;
        document[@"globalRules"] = global;
        NSPolicy *validated = [NSPolicy policyWithDocument:document error:error];
        if (!validated) {
            return nil;
        }
        NSFlowEvaluation verdict = [validated evaluateIdentity:nil
                                                     direction:NSPermissionDirection(current[@"direction"])
                                                   destination:destination
                                                        socket:NO];
        NSFlowDisposition expected = NSGlobalActionIsAllow(rule) ? NSFlowAllow : NSFlowDrop;
        return verdict.reason == NSFlowReasonGlobal && verdict.disposition == expected
                   ? validated.document
                   : NSPermissionError(error, @"The new rule would not decide this connection as requested.");
    }

    NSMutableDictionary *rules = [document[@"rules"] mutableCopy];
    rules[identity] = NSAppRuleBySelecting(rules[identity], rule);
    document[@"rules"] = rules;
    if (current[@"destination"]) {
        NSMutableDictionary *destinations =
            [document[@"ruleDestinations"] mutableCopy] ?: [NSMutableDictionary new];
        if (!destinations[identity]) {
            destinations[identity] = destination;
        }
        document[@"ruleDestinations"] = destinations;
    }
    document[@"revision"] = NSUUID.UUID.UUIDString;
    return [NSPolicy policyWithDocument:document error:error].document;
}

static NSArray<NSDictionary *> *NSReadPermissionResponses(NSSharedDirectory *directory, NSError **error) {
    NSError *readError = nil;
    NSDictionary *document = NSReadDocumentIn(directory, NSPermissionResponsesFile, &readError);
    if (NSFileIsAbsent(readError)) {
        return @[];
    }
    if (!document) {
        if (error) {
            *error = readError;
        }
        return nil;
    }
    id records = document[@"responses"];
    NSMutableSet *tokens = [NSMutableSet new];
    if (document.count == 1 && [records isKindOfClass:NSArray.class] &&
        [records count] <= NSMaximumActiveRequests) {
        for (id value in records) {
            if (![value isKindOfClass:NSDictionary.class]) {
                break;
            }
            NSDictionary *record = value;
            BOOL once = [record[@"mode"] isEqual:@"once"];
            NSString *action = record[@"action"];
            if (record.count != (once ? 12 : 11) || !NSUnidentifiedRequest(record) ||
                !(once || [record[@"mode"] isEqual:@"rule"]) ||
                !([action isEqual:@"defer"] || (once && [@[ @"allow", @"block" ] containsObject:action])) ||
                !NSBoundedString(record[@"token"], 128, YES) || [tokens containsObject:record[@"token"]] ||
                !NSBoundedString(record[@"session"], 128, YES) ||
                !NSBoundedString(record[@"activation"], 128, YES) ||
                !NSBoundedString(record[@"fingerprint"], 512, YES) ||
                !NSBoundedString(record[@"askGeneration"], 128, NO) ||
                ![@[ @"inbound", @"outbound", @"unknown" ] containsObject:record[@"direction"]] ||
                (once ? !NSBoundedString(record[@"flow"], 128, NO) : record[@"flow"] != nil) ||
                ![record[@"expires"] isKindOfClass:NSDate.class] ||
                ![record[@"validUntil"] isKindOfClass:NSDate.class] ||
                (![action isEqual:@"defer"] && ![record[@"expires"] isEqual:record[@"validUntil"]])) {
                break;
            }
            [tokens addObject:record[@"token"]];
        }
        if (tokens.count == [records count]) {
            return records;
        }
    }
    if (error) {
        *error = NSStorageError(@"Invalid transient permission responses.");
    }
    return nil;
}

static BOOL NSPermissionResponseIsCurrent(NSDictionary *record, NSString *session, NSString *activation,
                                          NSDate *now) {
    NSTimeInterval remaining = [record[@"validUntil"] timeIntervalSinceDate:now];
    return remaining > 0 && remaining <= NSPermissionTimeout && [record[@"session"] isEqual:session] &&
           [record[@"activation"] isEqual:activation];
}

static BOOL NSSubmitPermissionResponse(NSDictionary *request, NSString *rule, NSError **error) {
    return NSUnownedConfigurationMutation(
        ^BOOL(NSSharedDirectory *directory, NSError **localError) {
            NSStoreLock *lock = [NSStoreLock tryLockInDirectory:directory
                                                           leaf:@"policy.lock"
                                                          error:localError];
            if (!lock) {
                return NO;
            }
            @try {
                NSDate *now = NSDate.date;
                NSPolicy *policy = NSReadPolicyIn(directory, localError);
                NSDictionary *current =
                    policy ? NSCurrentPermissionRequest(request, NSReadMonitor(), policy, now, localError)
                           : nil;
                if (!current) {
                    return NO;
                }
                BOOL defer = [rule isEqual:@"defer"];
                if (!NSUnidentifiedRequest(current) ||
                    (!defer && (![current[@"mode"] isEqual:@"once"] ||
                                ![NSPermissionRuleValues(current) containsObject:rule]))) {
                    NSPermissionError(localError, @"That action does not apply to this permission request.");
                    return NO;
                }
                if (defer && [current[@"deferred"] boolValue]) {
                    return YES;
                }
                if (!defer && ([current[@"expired"] boolValue] ||
                               [current[@"expires"] timeIntervalSinceDate:now] <= 0)) {
                    NSPermissionError(localError,
                                      @"This connection timed out. Retry to create a new request.");
                    return NO;
                }
                NSMutableDictionary *response = [NSMutableDictionary dictionaryWithObject:rule
                                                                                   forKey:@"action"];
                for (NSString *key in @[
                         @"token", @"kind", @"direction", @"mode", @"fingerprint", @"flow", @"session",
                         @"activation", @"askGeneration", @"expires"
                     ]) {
                    response[key] = current[key];
                }
                response[@"validUntil"] =
                    defer ? [now dateByAddingTimeInterval:NSMonitorFreshness] : current[@"expires"];
                NSArray *existing = NSReadPermissionResponses(directory, localError);
                if (!existing) {
                    return NO;
                }
                NSMutableArray *pending = [NSMutableArray new];
                for (NSDictionary *record in existing) {
                    if (!NSPermissionResponseIsCurrent(record, current[@"session"], current[@"activation"],
                                                       now)) {
                        continue;
                    }
                    if ([record[@"token"] isEqual:current[@"token"]]) {
                        if ([record isEqual:response] || (defer && [record[@"action"] isEqual:@"defer"])) {
                            return YES;
                        }
                        // An explicit decision can follow a queued deferral. It cannot replace another
                        // decision.
                        if (!defer && [record[@"action"] isEqual:@"defer"]) {
                            continue;
                        }
                        NSPermissionError(localError,
                                          @"A decision has already been submitted for this request.");
                        return NO;
                    }
                    [pending addObject:record];
                }
                if (pending.count >= NSMaximumActiveRequests) {
                    NSPermissionError(localError,
                                      @"The permission response queue is full. Try again shortly.");
                    return NO;
                }
                [pending addObject:response];
                return NSWriteDocumentIn(directory, @{@"responses" : pending}, NSPermissionResponsesFile,
                                         localError);
            } @finally {
                [lock unlock];
            }
        },
        error);
}

void NSDrainPermissionResponses(NSString *session, NSString *activation,
                                dispatch_block_t (^detach)(NSDictionary *, NSPolicy *)) {
    NSError *probe = nil;
    NSReadDocument(NSPermissionResponsesFile, &probe);
    if (NSFileIsAbsent(probe)) {
        return;
    }
    NSMutableArray<dispatch_block_t> *completions = [NSMutableArray new];
    NSUnownedConfigurationMutation(
        ^BOOL(NSSharedDirectory *directory, NSError **error) {
            NSStoreLock *lock = [NSStoreLock tryLockInDirectory:directory leaf:@"policy.lock" error:error];
            if (!lock) {
                return NO;
            }
            @try {
                NSArray *records = NSReadPermissionResponses(directory, error);
                if (records && !records.count) {
                    return YES;
                }
                NSPolicy *policy = records ? NSReadPolicyIn(directory, error) : nil;
                // Consume before detach. A failed cleanup leaves the response eligible for a bounded retry.
                if (!NSUnlinkBoundedFile(directory, NSPermissionResponsesFile, NULL) || !policy) {
                    return NO;
                }
                for (NSDictionary *record in records) {
                    if (NSPermissionResponseIsCurrent(record, session, activation, NSDate.date)) {
                        dispatch_block_t completion = detach(record, policy);
                        if (completion) {
                            [completions addObject:completion];
                        }
                    }
                }
                return YES;
            } @finally {
                [lock unlock];
            }
        },
        NULL);
    for (dispatch_block_t completion in completions) {
        completion();
    }
}

void NSClearPermissionResponses(NSStoreLock *providerLock) {
    NSSharedDirectory *directory = providerLock.directory;
    NSStoreLock *lock = [NSStoreLock tryLockInDirectory:directory leaf:@"policy.lock" error:NULL];
    if (lock) {
        NSUnlinkBoundedFile(directory, NSPermissionResponsesFile, NULL);
        [lock unlock];
    }
}

BOOL NSAnswerPermissionRequest(NSDictionary *request, BOOL allow, NSError **error) {
    NSArray *rules = [request isKindOfClass:NSDictionary.class] ? NSPermissionRuleValues(request) : @[];
    NSString *rule = allow ? rules.firstObject : rules.lastObject;
    return NSAnswerPermissionRequestWithRule(request, rule ?: @"", error);
}

BOOL NSAnswerPermissionRequestWithRule(NSDictionary *request, NSString *rule, NSError **error) {
    if (![request isKindOfClass:NSDictionary.class] || ![rule isKindOfClass:NSString.class]) {
        NSPermissionError(error, @"Invalid permission response payload.");
        return NO;
    }
    if ([rule isEqual:@"defer"] || (NSUnidentifiedRequest(request) && [request[@"mode"] isEqual:@"once"])) {
        return NSSubmitPermissionResponse(request, rule, error);
    }
    if (![NSDirectionRuleValues() containsObject:rule ?: @""]) {
        NSPermissionError(error, @"Unsupported permission rule.");
        return NO;
    }
    return NSUnownedConfigurationMutation(
        ^BOOL(NSSharedDirectory *directory, NSError **localError) {
            return NSUpdatePolicy(
                ^BOOL(NSMutableDictionary *document, NSError **mutationError) {
                    NSPolicy *policy = [NSPolicy policyWithDocument:document error:mutationError];
                    NSDictionary *current = policy
                                                ? NSCurrentPermissionRequest(request, NSReadMonitor(), policy,
                                                                             NSDate.date, mutationError)
                                                : nil;
                    NSDictionary *response =
                        current ? NSPermissionPolicyWithDecision(current, policy, rule, mutationError) : nil;
                    if (!response) {
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
    NSDictionary *validated = NSValidateMonitor(monitor, error);
    NSDictionary *current =
        validated ? NSCurrentPermissionRequest(request, validated, policy, now, error) : nil;
    if (!current) {
        return nil;
    }
    NSArray *actions = NSPermissionRuleValues(current);
    return NSPermissionPolicyWithDecision(current, policy, allow ? actions.firstObject : actions.lastObject,
                                          error);
}
