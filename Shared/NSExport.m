#import "NSExport.h"
#import "NSConstants.h"
#import "NSStoreLock.h"

NSError *NSExportError(NSString *message) {
    return [NSError errorWithDomain:@"NetShield2.Export"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

// Validate each cache component without following a symlink. A missing cache is
// fine for cleanup, but the app-group container itself must already exist.
NSURL *NSExportCacheURL(NSURL *container, BOOL create, NSError **error) {
    NSFileManager *files = NSFileManager.defaultManager;
    if (!container.isFileURL || !container.path.isAbsolutePath) {
        if (error) {
            *error = NSExportError(@"The shared app-group container is unavailable or invalid. Check the "
                                   @"NetShield2 installation and retry Export.");
        }
        return nil;
    }
    NSURL *directory = container;
    NSArray *components = [@[ @"" ] arrayByAddingObjectsFromArray:NSExportCacheDirectory.pathComponents];
    BOOL missing = NO;
    for (NSString *component in components) {
        if (component.length) {
            directory = [directory URLByAppendingPathComponent:component isDirectory:YES];
        }
        if (missing) {
            continue;
        }
        NSError *readError = nil;
        NSDictionary *attributes = [files attributesOfItemAtPath:directory.path error:&readError];
        if (!attributes && component.length && [readError.domain isEqual:NSCocoaErrorDomain] &&
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
                *error = readError
                             ?: NSExportError(@"The export cache path contains a non-directory or "
                                              @"symbolic link. Check the NetShield2 installation.");
            }
            return nil;
        }
    }
    return directory;
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
            lock = [NSStoreLock tryLockURL:[container URLByAppendingPathComponent:@"exports.lock"]
                                     error:error];
        }
        if (!lock) {
            return nil;
        }
        NSURL *cache = NSExportCacheURL(container, YES, error);
        if (!cache || ![cache setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:error]) {
            return nil;
        }
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
