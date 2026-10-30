#import "NSRecoveryDiagnostics.h"
#import <NetworkExtension/NetworkExtension.h>
#include <mach-o/dyld.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <unistd.h>
#import "../Shared/NSConstants.h"

static NSString *const NSRecoveryAppID = @"com.eolnmsuk.netshield";

BOOL NSRecoveryIsPlainPoC(void) {
#if NS_RECOVERY_POC
    return YES;
#else
    return NO;
#endif
}

static NSURL *NSRecoveryURL(NSString *name) {
    // Never resolve or create the shared rule container here.
    NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                       inDomains:NSUserDomainMask]
                      .firstObject;
    return [[base URLByAppendingPathComponent:@"NetShield2Recovery"
                                  isDirectory:YES] URLByAppendingPathComponent:name];
}

static BOOL NSRecoveryWrite(NSDictionary *value, NSString *name, NSError **error) {
    NSURL *url = NSRecoveryURL(name);
    if (!url) {
        if (error) {
            *error = [NSError
                errorWithDomain:@"NetShield2.Recovery"
                           code:1
                       userInfo:@{
                           NSLocalizedDescriptionKey : @"The app's local diagnostic directory is unavailable."
                       }];
        }
        return NO;
    }
    if (![NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:error]) {
        return NO;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:error];
    return data && [data writeToURL:url options:NSDataWritingAtomic error:error];
}

static NSDictionary *NSRecoveryRead(NSString *name) {
    NSURL *url = NSRecoveryURL(name);
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    id value =
        data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

NSDictionary *NSRecoverySnapshot(void) {
    NEFilterManager *manager = NEFilterManager.sharedManager;
    NEFilterProviderConfiguration *configuration = manager.providerConfiguration;
    NSMutableDictionary *snapshot = [@{
        @"present" : @(configuration != nil),
        @"enabled" : @(manager.enabled),
        @"description" : manager.localizedDescription ?: @""
    } mutableCopy];
    if (configuration) {
        NSDictionary *vendor = configuration.vendorConfiguration;
        // Only the exact configuration shape written by this project qualifies
        // for an original-owner observation. Labels/IDs alone are insufficient.
        BOOL valid =
            [vendor isKindOfClass:NSDictionary.class] && [vendor[@"schema"] isKindOfClass:NSNumber.class] &&
            [vendor[@"engine"] isKindOfClass:NSNumber.class] &&
            [vendor[@"schema"] integerValue] == NSSchemaVersion && [vendor[@"engine"] integerValue] > 0 &&
            [vendor[@"activation"] isKindOfClass:NSString.class] &&
            [[NSUUID alloc] initWithUUIDString:vendor[@"activation"]] != nil &&
            [configuration.organization isEqual:@"NetShield2"] && !configuration.serverAddress &&
            !configuration.username && !configuration.passwordReference && !configuration.identityReference;
        snapshot[@"observableConfiguration"] = @{
            @"vendor" : vendor ?: @{},
            @"organization" : configuration.organization ?: @"",
            @"filterBrowsers" : @(configuration.filterBrowsers),
            @"filterSockets" : @(configuration.filterSockets)
        };
        if (valid) {
            snapshot[@"fingerprint"] = snapshot[@"observableConfiguration"];
        }
    }
    return snapshot;
}

NSDictionary *NSRecoveryEvidence(void) {
    NSDictionary *evidence = NSRecoveryRead(@"original-owner.plist");
    return [evidence[@"format"] isEqual:@1] &&
                   [evidence[@"source"] isEqual:@"confirmed-original-legacy-owner"] &&
                   [evidence[@"bundleID"] isEqual:NSRecoveryAppID] &&
                   [evidence[@"fingerprint"] isKindOfClass:NSDictionary.class]
               ? evidence
               : @{};
}

NSFilterRecovery *NSRecoveryService(void) {
    static NSFilterRecovery *service;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        service = [NSFilterRecovery new];
        service.manager = (id<NSFilterRecoveryManager>)NEFilterManager.sharedManager;
        service.snapshot = ^{
            return NSRecoverySnapshot();
        };
    });
    return service;
}

static NSString *NSRecoverySysctl(const char *key) {
    char buffer[256] = {0};
    size_t length = sizeof(buffer);
    return sysctlbyname(key, buffer, &length, NULL, 0) == 0 ? ([NSString stringWithUTF8String:buffer] ?: @"")
                                                            : @"unavailable";
}

NSDictionary *NSRecoveryReport(void) {
    struct timeval boot = {0};
    size_t length = sizeof(boot);
    BOOL bootKnown = sysctlbyname("kern.boottime", &boot, &length, NULL, 0) == 0;
    NSMutableArray *images = [NSMutableArray new];
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *name = _dyld_get_image_name(index);
        if (name) {
            [images addObject:[NSString stringWithUTF8String:name] ?: @"unknown"];
        }
    }
    NSBundle *bundle = NSBundle.mainBundle;
    NSMutableArray *providers = [NSMutableArray new];
    for (NSString *name in @[ @"NetShield2Data", @"NetShield2Control" ]) {
        NSURL *url = [bundle.builtInPlugInsURL
            URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"appex"]];
        NSBundle *provider = [NSBundle bundleWithURL:url];
        [providers addObject:@{@"path" : url.path ?: @"", @"info" : provider.infoDictionary ?: @{}}];
    }
    return @{
        @"format" : @1,
        @"time" : NSDate.date,
        @"buildFlavor" : NSRecoveryIsPlainPoC() ? @"plain-trollstore-poc" : @"legacy",
        @"bundleID" : bundle.bundleIdentifier ?: @"",
        @"appInfo" : bundle.infoDictionary ?: @{},
        @"bundlePath" : bundle.bundlePath,
        @"home" : NSHomeDirectory(),
        @"uid" : @(getuid()),
        @"euid" : @(geteuid()),
        @"gid" : @(getgid()),
        @"machine" : NSRecoverySysctl("hw.machine"),
        @"osBuild" : NSRecoverySysctl("kern.osversion"),
        @"osVersion" : NSProcessInfo.processInfo.operatingSystemVersionString,
        @"bootUnixTime" : bootKnown ? @(boot.tv_sec) : @0,
        @"uptime" : @(NSProcessInfo.processInfo.systemUptime),
        @"loadedImages" : images,
        @"providers" : providers,
        @"evidence" : NSRecoveryEvidence(),
        @"journal" : NSRecoveryRead(@"journal.plist"),
        @"qualification" : @"UNVERIFIED: versions, active jailbreak state, effective signatures, "
                           @"registrations, shared-group URL and traffic require owner observations. "
                           @"An imported fingerprint is corroboration, not OS authorization."
    };
}

BOOL NSRecoveryCaptureEvidence(NSDictionary *snapshot, NSError **error) {
    NSDictionary *fingerprint = snapshot[@"fingerprint"];
    if (NSRecoveryIsPlainPoC() || ![snapshot[@"present"] boolValue] || !fingerprint.count ||
        ![NSBundle.mainBundle.bundleIdentifier isEqual:NSRecoveryAppID]) {
        if (error) {
            *error =
                [NSError errorWithDomain:@"NetShield2.Recovery"
                                    code:2
                                userInfo:@{
                                    NSLocalizedDescriptionKey :
                                        @"Capture requires a visible NetShield2 configuration in "
                                        @"the confirmed original legacy owner. No configuration was changed."
                                }];
        }
        return NO;
    }
    return NSRecoveryWrite(
        @{
            @"format" : @1,
            @"source" : @"confirmed-original-legacy-owner",
            @"bundleID" : NSRecoveryAppID,
            @"time" : NSDate.date,
            @"fingerprint" : fingerprint,
            @"observedEnabled" : snapshot[@"enabled"],
            @"originalBundlePath" : NSBundle.mainBundle.bundlePath,
            // Baseline-only observation. Disable/remove never resolve this URL.
            @"originalGroupURL" : [NSFileManager.defaultManager
                containerURLForSecurityApplicationGroupIdentifier:@"group.com.eolnmsuk.netshield"]
                    .path
                ?: @"unavailable",
            @"originalAppInfo" : NSBundle.mainBundle.infoDictionary ?: @{}
        },
        @"original-owner.plist", error);
}

BOOL NSRecoveryImportEvidence(NSURL *url, NSError **error) {
    BOOL access = [url startAccessingSecurityScopedResource];
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:error];
    NSData *data = size && size.unsignedLongLongValue <= 256 * 1024
                       ? [NSData dataWithContentsOfURL:url options:0 error:error]
                       : nil;
    if (access) {
        [url stopAccessingSecurityScopedResource];
    }
    id report = data ? [NSPropertyListSerialization propertyListWithData:data
                                                                 options:0
                                                                  format:NULL
                                                                   error:error]
                     : nil;
    id evidence = [report isKindOfClass:NSDictionary.class] ? report[@"evidence"] : nil;
    BOOL valid = [evidence isKindOfClass:NSDictionary.class] && [evidence[@"format"] isEqual:@1] &&
                 [evidence[@"bundleID"] isEqual:NSRecoveryAppID] &&
                 [evidence[@"source"] isEqual:@"confirmed-original-legacy-owner"] &&
                 [evidence[@"fingerprint"] isKindOfClass:NSDictionary.class] &&
                 [evidence[@"fingerprint"] count] > 0;
    if (!valid) {
        if (error) {
            *error = [NSError
                errorWithDomain:@"NetShield2.Recovery"
                           code:3
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"Select an unmodified Phase 0 original-owner report "
                               @"exported from this phone. Evidence import never grants system permission."
                       }];
        }
        return NO;
    }
    return NSRecoveryWrite(evidence, @"original-owner.plist", error);
}

void NSRecoveryPerform(NSString *operation, void (^completion)(NSDictionary *)) {
    [NSRecoveryService()
           perform:operation
          evidence:NSRecoveryEvidence()[@"fingerprint"]
        completion:^(NSDictionary *result) {
            NSMutableDictionary *journal = [NSRecoveryRead(@"journal.plist") mutableCopy];
            NSMutableArray *entries = [journal[@"entries"] isKindOfClass:NSArray.class]
                                          ? [journal[@"entries"] mutableCopy]
                                          : [NSMutableArray new];
            NSMutableDictionary *entry = [result mutableCopy];
            entry[@"time"] = NSDate.date;
            [entries addObject:entry];
            while (entries.count > 40) {
                [entries removeObjectAtIndex:0];
            }
            journal[@"entries"] = entries;
            if ([@[ @"disabledVerified", @"alreadyDisabledVerified" ] containsObject:result[@"status"]]) {
                journal[@"lastVerifiedDisable"] = entry;
            }
            NSError *error = nil;
            BOOL saved = NSRecoveryWrite(journal, @"journal.plist", &error);
            NSMutableDictionary *reported = [result mutableCopy];
            reported[@"diagnosticWrite"] = saved ? @"saved" : error.localizedDescription ?: @"failed";
            completion(reported);
        }];
}

NSString *NSRecoveryMessage(NSDictionary *result) {
    NSString *status = result[@"status"];
    if ([@[ @"disabledVerified", @"alreadyDisabledVerified" ] containsObject:status]) {
        return @"NetShield2 firewall turned off and verified. The configuration remains installed; "
               @"rules and settings are unchanged. A retained Invalid entry may remain. "
               @"Check fresh traffic separately.";
    }
    if ([status isEqual:@"removedVerified"]) {
        return @"NetShield2 filter removed and verified for the configuration observed by this app. "
               @"Rules and settings are unchanged. Check fresh traffic separately.";
    }
    if ([status isEqual:@"noVisibleConfiguration"]) {
        return @"No configuration is visible to this app; recovery could not be verified. "
               @"This does not prove the old filter is absent.";
    }
    if ([status isEqual:@"foundRecordedConfiguration"]) {
        return @"The visible configuration matches the original-owner observation. "
               @"This does not yet prove permission to disable or remove it.";
    }
    if ([status isEqual:@"ownershipUnverified"]) {
        return @"A configuration is visible, but original-owner evidence is missing or differs. "
               @"No changes made. Review/export diagnostics; do not replace the configuration.";
    }
    if ([status isEqual:@"timedOut"] || [status isEqual:@"busyUncertain"]) {
        return @"The request timed out and may still complete. Result unverified; further operations "
               @"in this process are blocked. Export diagnostics, relaunch and inspect again.";
    }
    return [NSString stringWithFormat:@"Recovery result: %@. Disablement/removal is unverified for "
                                      @"this request. Export diagnostics and review the API errors.",
                                      status];
}
