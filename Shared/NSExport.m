#import "NSExport.h"
#import "NSConstants.h"
#import "NSGlobalRule.h"
#import "NSStoreLock.h"
#import "NSRuleChoices.h"
#import "NSValidation.h"
#import <TargetConditionals.h>

@interface NSRuleImportResult ()
@property(nonatomic, readwrite, copy) NSDictionary *identityRules;
@property(nonatomic, readwrite, copy) NSDictionary *globalRules;
@property(nonatomic, readwrite, copy) NSDictionary *acceptedCounts;
@property(nonatomic, readwrite, copy) NSDictionary *rejectedCounts;
@property(nonatomic, readwrite, copy) NSArray<NSString *> *rejections;
@end
@implementation NSRuleImportResult
- (NSString *)summary {
    NSUInteger global = [self.acceptedCounts[@"globalRules"] unsignedIntegerValue];
    NSUInteger app = [self.acceptedCounts[@"appRules"] unsignedIntegerValue];
    NSUInteger system = [self.acceptedCounts[@"systemRules"] unsignedIntegerValue];
    NSUInteger rejected = 0;
    for (NSNumber *count in self.rejectedCounts.allValues) {
        rejected += count.unsignedIntegerValue;
    }
    NSMutableString *text = [NSMutableString
        stringWithFormat:@"Imported %lu rules (%lu global, %lu app, %lu system). Rejected %lu entries (%@ "
                         @"global, %@ app, %@ system). Previous rules were replaced.",
                         (unsigned long)(global + app + system), (unsigned long)global, (unsigned long)app,
                         (unsigned long)system, (unsigned long)rejected, self.rejectedCounts[@"globalRules"],
                         self.rejectedCounts[@"appRules"], self.rejectedCounts[@"systemRules"]];
    if (!global && !app && !system) {
        [text appendString:@" The replacement contains zero saved rules."];
    }
    if (self.rejections.count) {
        [text appendFormat:@"\n\n%@", [self.rejections componentsJoinedByString:@"\n"]];
    }
    if (rejected > self.rejections.count) {
        [text appendString:@"\nAdditional rejected entries are included in the counts above."];
    }
    return [text copy];
}
@end

static NSRuleImportResult *NSImportFailure(NSString *message, NSError **error) {
    if (error) {
        *error = [NSError errorWithDomain:@"NetShield2.Import"
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey : message}];
    }
    return nil;
}
static BOOL NSImportRecordKeys(id record, NSArray *keys) {
    return [record isKindOfClass:NSDictionary.class] &&
           [[NSSet setWithArray:[record allKeys]] isEqual:[NSSet setWithArray:keys]];
}
NSRuleImportResult *NSParseRulesJSON(NSData *data, NSError **error) {
    if (![data isKindOfClass:NSData.class] || !data.length || data.length > NSMaximumRuleTransferBytes) {
        return NSImportFailure(@"Select a nonempty JSON file no larger than 2 MiB.", error);
    }
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (!root) {
        return nil;
    }
    if (![root isKindOfClass:NSDictionary.class] ||
        !NSUnsignedInteger(root[@"schemaVersion"], NSExportSchemaVersion) ||
        ![root[@"schemaVersion"] isEqual:@(NSExportSchemaVersion)]) {
        return NSImportFailure(
            @"Unsupported rules file. Import requires export schema 3; older exports are not supported.",
            error);
    }
    NSArray *categories = @[ @"globalRules", @"appRules", @"systemRules" ];
    for (NSString *category in categories) {
        if (![root[category] isKindOfClass:NSArray.class]) {
            return NSImportFailure(
                @"The rules file must contain globalRules, appRules and systemRules arrays.", error);
        }
    }
    NSMutableDictionary *identities = [NSMutableDictionary new], *globals = [NSMutableDictionary new],
                        *accepted = [NSMutableDictionary new], *rejected = [NSMutableDictionary new];
    NSMutableArray *compiled = [NSMutableArray new], *details = [NSMutableArray new];
    NSUInteger count = 0, cost = 0;
    for (NSString *category in categories) {
        NSUInteger good = 0, bad = 0, index = 0;
        BOOL global = [category isEqual:@"globalRules"];
        for (id record in root[category]) {
            index++;
            NSString *reason = nil, *key = nil;
            NSDictionary *condition = nil, *descriptor = nil, *appRule = nil;
            NSUInteger entryCost = 1;
            if (global) {
                if (!NSImportRecordKeys(record, @[ @"condition", @"action" ]) ||
                    !(key = NSGlobalRuleKey(record[@"condition"])) ||
                    !NSGlobalCoverageAgrees(key, record[@"action"])) {
                    reason = @"invalid current-format condition or action";
                } else {
                    condition = record[@"condition"];
                    entryCost = NSGlobalConditionCost(condition);
                    descriptor = NSCompileGlobalCondition(condition);
                    for (NSDictionary *other in compiled) {
                        if (NSGlobalConditionsIntersect(descriptor, other)) {
                            reason = @"overlaps an earlier accepted global rule";
                            break;
                        }
                    }
                }
            } else {
                if (!NSImportRecordKeys(record, @[ @"identity", @"rule" ]) ||
                    !NSBoundedString(record[@"identity"], NSMaximumIdentityLength, YES) ||
                    !(appRule = NSAppRuleRecord(record[@"rule"]))) {
                    reason = @"invalid identity or directional rule record";
                } else {
                    key = record[@"identity"];
                    if (NSIsAppleSystemIdentity(key) != [category isEqual:@"systemRules"]) {
                        reason = @"identity is in the wrong app/system collection";
                    } else if (identities[key]) {
                        reason = @"duplicate identity";
                    }
                }
            }
            if (!reason && (count >= NSMaximumRules || cost + entryCost > NSMaximumRules)) {
                reason = @"rule or predicate capacity exceeded";
            }
            if (reason) {
                bad++;
                if (details.count < 20) {
                    // Index and category remain unambiguous without echoing
                    // untrusted identity text into a potentially huge alert.
                    [details addObject:[NSString stringWithFormat:@"%@[%lu]: %@", category,
                                                                  (unsigned long)index, reason]];
                }
                continue;
            }
            if (global) {
                globals[key] = record[@"action"];
                [compiled addObject:descriptor];
            } else {
                identities[key] = appRule;
            }
            good++;
            count++;
            cost += entryCost;
        }
        accepted[category] = @(good);
        rejected[category] = @(bad);
    }
    NSRuleImportResult *result = [NSRuleImportResult new];
    result.identityRules = identities;
    result.globalRules = globals;
    result.acceptedCounts = accepted;
    result.rejectedCounts = rejected;
    result.rejections = details;
    return result;
}

NSError *NSExportError(NSString *message) {
    return [NSError errorWithDomain:@"NetShield2.Export"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

// Validate each cache component without following a symlink. A missing cache is
// fine for cleanup, but the app-group container itself must already exist.
NSURL *NSExportCacheURL(NSURL *container, BOOL create, NSError **error) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSSharedDirectory *root = [NSSharedDirectory openRoot:container leaf:NSExportCacheDirectory error:error];
    if (!root) {
        return nil;
    }
    NSURL *directory = container;
    BOOL missing = NO;
    for (NSString *component in NSExportCacheDirectory.pathComponents) {
        directory = [directory URLByAppendingPathComponent:component isDirectory:YES];
        if (missing) {
            continue;
        }
        NSError *readError = nil;
        NSDictionary *attributes = [files attributesOfItemAtPath:directory.path error:&readError];
        if (!attributes && [readError.domain isEqual:NSCocoaErrorDomain] &&
            (readError.code == NSFileNoSuchFileError || readError.code == NSFileReadNoSuchFileError)) {
            if (!create) {
                missing = YES;
                continue;
            }
            if (![files createDirectoryAtURL:directory
                    withIntermediateDirectories:NO
                                     attributes:nil
                                          error:error]) {
                return nil;
            }
            attributes = [files attributesOfItemAtPath:directory.path error:&readError];
        }
        if (!attributes || ![attributes[NSFileType] isEqual:NSFileTypeDirectory]) {
            if (error) {
                *error =
                    readError
                        ? [NSError errorWithDomain:readError.domain
                                              code:readError.code
                                          userInfo:@{
                                              NSLocalizedDescriptionKey : [NSString
                                                  stringWithFormat:@"Inspect export cache (%@).", component],
                                              NSUnderlyingErrorKey : readError
                                          }]
                        : NSExportError(@"The export cache path contains a non-directory or symbolic link.");
            }
            return nil;
        }
    }
    return [root validateForLeaf:NSExportCacheDirectory error:error] ? directory : nil;
}

BOOL NSIsExportDirectoryName(NSString *name) {
    NSString *prefix = @"NetShield2-Export-";
    return [name hasPrefix:prefix] &&
           [[NSUUID alloc] initWithUUIDString:[name substringFromIndex:prefix.length]] != nil;
}

// Only the app stages exports. Keep active shares even if they remain open for
// more than a day; a terminated process leaves no active share to protect.
// Use the unique folder name within the validated cache: filesystem enumeration
// can return a different spelling of the container path than staging used.
static NSMutableSet<NSString *> *NSActiveExportDirectories(void) {
    static NSMutableSet<NSString *> *active;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        active = [NSMutableSet new];
    });
    return active;
}

// One process registry also retains the interprocess lifetime lock for each
// container while any share is active. Canonical roots preserve /var aliases.
static NSMutableDictionary *NSExportLifetimeLocks(void) {
    static NSMutableDictionary *locks;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        locks = [NSMutableDictionary new];
    });
    return locks;
}
static NSString *NSExportRootKey(NSURL *container) {
    return container.URLByResolvingSymlinksInPath.path;
}

static void NSPruneAbandonedExports(NSURL *cache, NSSet<NSString *> *active) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSDirectoryEnumerator *entries = [files enumeratorAtURL:cache
                                 includingPropertiesForKeys:nil
                                                    options:NSDirectoryEnumerationSkipsSubdirectoryDescendants
                                               errorHandler:nil];
    // Bound both inspection and removal work on the export action.
    for (NSUInteger inspected = 0, removed = 0; inspected < 64 && removed < 16; inspected++) {
        NSURL *entry = entries.nextObject;
        if (!entry) {
            break;
        }
        if (!NSIsExportDirectoryName(entry.lastPathComponent) ||
            [active containsObject:entry.lastPathComponent]) {
            continue;
        }
        NSDictionary *attributes = [files attributesOfItemAtPath:entry.path error:NULL];
        NSDate *modified = attributes[NSFileModificationDate];
        if ([attributes[NSFileType] isEqual:NSFileTypeDirectory] && modified &&
            [modified timeIntervalSinceNow] < -24 * 60 * 60) {
            // removeItem removes nested symlinks themselves, not their targets.
            if ([files removeItemAtURL:entry error:NULL]) {
                removed++;
            }
        }
    }
}

NSURL *NSStageRulesAndActivityExport(NSData *data, NSURL *container, NSError **error) {
    NSMutableSet *active = NSActiveExportDirectories();
    @synchronized(active) {
        if (!NSExportCacheURL(container, NO, error)) {
            return nil;
        }
        NSString *root = NSExportRootKey(container);
        NSMutableDictionary *lifetime = NSExportLifetimeLocks()[root];
        __attribute__((objc_precise_lifetime)) NSStoreLock *lock = lifetime[@"lock"];
        if (!lock) {
            lock = [NSStoreLock tryLockRoot:container leaf:@"exports.lock" error:error];
        }
        if (!lock) {
            return nil;
        }
        NSURL *cache = NSExportCacheURL(container, YES, error);
        if (!cache) {
            return nil;
        }
#if TARGET_OS_IOS
        // Require backup exclusion in the iOS app-group cache. macOS tests stage
        // synthetic exports in a temporary directory and need no backup metadata.
        if (![cache setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:error]) {
            return nil;
        }
#endif
        NSPruneAbandonedExports(cache, active);
        NSURL *directory = [cache
            URLByAppendingPathComponent:[@"NetShield2-Export-" stringByAppendingString:NSUUID.UUID.UUIDString]
                            isDirectory:YES];
        NSFileManager *files = NSFileManager.defaultManager;
        if (![files createDirectoryAtURL:directory
                withIntermediateDirectories:NO
                                 attributes:nil
                                      error:error]) {
            return nil;
        }
        NSURL *url = [directory URLByAppendingPathComponent:@"NetShield2-Rules-and-Recent-Activity.json"];
        if (![data writeToURL:url options:NSDataWritingAtomic error:error]) {
            [files removeItemAtURL:directory error:NULL];
            return nil;
        }
        [active addObject:directory.lastPathComponent];
        if (!lifetime) {
            lifetime = [@{@"lock" : lock, @"names" : [NSMutableSet new]} mutableCopy];
            NSExportLifetimeLocks()[root] = lifetime;
        }
        [lifetime[@"names"] addObject:directory.lastPathComponent];
        return url;
    }
}

BOOL NSRemoveStagedExport(NSURL *container, NSURL *url, NSError **error) {
    NSMutableSet *active = NSActiveExportDirectories();
    @synchronized(active) {
        NSURL *directory = url.URLByDeletingLastPathComponent;
        NSURL *cache = NSExportCacheURL(container, NO, error);
        if (!cache) {
            if (directory.lastPathComponent) {
                [active removeObject:directory.lastPathComponent];
            }
            return NO;
        }
        if (!url.isFileURL || !NSIsExportDirectoryName(directory.lastPathComponent) ||
            ![directory.URLByDeletingLastPathComponent.path isEqual:cache.path]) {
            if (error) {
                *error = NSExportError(@"Refusing cleanup outside the export cache.");
            }
            return NO;
        }
        NSError *removeError = nil;
        BOOL removed = [NSFileManager.defaultManager removeItemAtURL:directory error:&removeError];
        [active removeObject:directory.lastPathComponent];
        NSString *root = NSExportRootKey(container);
        NSMutableDictionary *lifetime = NSExportLifetimeLocks()[root];
        [lifetime[@"names"] removeObject:directory.lastPathComponent];
        if (![lifetime[@"names"] count]) {
            [lifetime[@"lock"] unlock];
            [NSExportLifetimeLocks() removeObjectForKey:root];
        }
        if (!removed &&
            !([removeError.domain isEqual:NSCocoaErrorDomain] && removeError.code == NSFileNoSuchFileError)) {
            if (error) {
                *error = removeError;
            }
            return NO;
        }
        return YES;
    }
}

NSData *NSRulesAndActivityJSON(NSPolicy *policy, NSArray<NSDictionary *> *events, NSString *version,
                               NSError **error) {
    NSDictionary *document = policy.document;
    NSMutableArray *appRules = [NSMutableArray new], *systemRules = [NSMutableArray new],
                   *globalRules = [NSMutableArray new];
    for (NSString *identity in [[document[@"rules"] allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSMutableArray *rules = NSIsAppleSystemIdentity(identity) ? systemRules : appRules;
        [rules addObject:@{@"identity" : identity, @"rule" : document[@"rules"][identity]}];
    }
    for (NSString *key in [[document[@"globalRules"] allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        [globalRules addObject:@{
            @"condition" : NSGlobalRuleCondition(key),
            @"action" : document[@"globalRules"][key]
        }];
    }
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    NSMutableArray *activity = [NSMutableArray new];
    for (NSDictionary *event in events) {
        NSMutableDictionary *entry = [event mutableCopy];
        entry[@"time"] = [formatter stringFromDate:event[@"time"]];
        [activity addObject:entry];
    }
    NSDictionary *export = @{
        @"schemaVersion" : @(NSExportSchemaVersion),
        @"appVersion" : version,
        @"exportedAt" : [formatter stringFromDate:NSDate.date],
        @"defaultRule" : document[@"default"],
        @"unidentifiedRule" : document[@"unattributed"],
        @"allowAppleSystemProcesses" : @([document[@"allowAppleSystemProcesses"] boolValue]),
        @"appRules" : appRules,
        @"systemRules" : systemRules,
        @"globalRules" : globalRules,
        @"recentActivity" : activity
    };
    NSData *data =
        [NSJSONSerialization dataWithJSONObject:export
                                        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                          error:error];
    if (data.length > NSMaximumRuleTransferBytes) {
        if (error) {
            *error = NSExportError(@"Rules and activity exceed the 2 MiB JSON transfer limit. Clear activity "
                                   @"or reduce rules, then retry Export.");
        }
        return nil;
    }
    return data;
}
