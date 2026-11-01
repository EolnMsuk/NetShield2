#import "NSFilterBootPolicy.h"
#include <string.h>

// Private API stays in the app. Never use KVC, guessed keys, or ivar offsets.
@protocol NSPrivateFilterBootPolicy <NSObject>
- (BOOL)disableDefaultDrop;
- (void)setDisableDefaultDrop:(BOOL)value;
@end

@protocol NSFilterConfigurationFields <NSObject, NSCopying>
@property(nonatomic) BOOL filterBrowsers;
@property(nonatomic) BOOL filterSockets;
@property(nonatomic, copy) NSString *organization;
@property(nonatomic, copy) NSDictionary *vendorConfiguration;
@end

static BOOL NSBootPolicyFail(NSError **error, NSFilterBootPolicyError code, NSString *message) {
    if (error) {
        *error = [NSError errorWithDomain:@"NetShield2.BootPolicy"
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey : message}];
    }
    return NO;
}

static BOOL NSBootPolicyCapability(id configuration, NSError **error) {
    SEL getter = @selector(disableDefaultDrop);
    SEL setter = @selector(setDisableDefaultDrop:);
    if (![configuration respondsToSelector:getter] || ![configuration respondsToSelector:setter]) {
        return NSBootPolicyFail(error, NSFilterBootPolicyUnsupported,
                                @"The boot-policy getter or setter is absent; its value is unavailable.");
    }
    NSMethodSignature *read = [configuration methodSignatureForSelector:getter];
    NSMethodSignature *write = [configuration methodSignatureForSelector:setter];
    if (!read || !write || read.numberOfArguments != 2 || write.numberOfArguments != 3 ||
        strcmp(read.methodReturnType, @encode(BOOL)) || strcmp(write.methodReturnType, @encode(void)) ||
        strcmp([write getArgumentTypeAtIndex:2], @encode(BOOL))) {
        return NSBootPolicyFail(error, NSFilterBootPolicyUnsupported,
                                @"The boot-policy methods have incompatible Boolean signatures.");
    }
    return YES;
}

BOOL NSFilterBootPolicyRead(id configuration, BOOL *value, NSError **error) {
    @try {
        if (!NSBootPolicyCapability(configuration, error)) {
            return NO;
        }
        BOOL readback = [(id<NSPrivateFilterBootPolicy>)configuration disableDefaultDrop];
        if (value) {
            *value = readback;
        }
        return YES;
    } @catch (NSException *exception) {
        return NSBootPolicyFail(error, NSFilterBootPolicyReadbackFailed,
                                @"The boot-policy getter could not be read; its value is unknown.");
    }
}

BOOL NSFilterBootPolicyApply(id configuration, NSError **error) {
    @try {
        if (!NSBootPolicyCapability(configuration, error)) {
            return NO;
        }
        [(id<NSPrivateFilterBootPolicy>)configuration setDisableDefaultDrop:YES];
        BOOL value = NO;
        if (!NSFilterBootPolicyRead(configuration, &value, error)) {
            return NO;
        }
        return value || NSBootPolicyFail(error, NSFilterBootPolicyReadbackFailed,
                                         @"The boot-policy setter did not retain YES on readback.");
    } @catch (NSException *exception) {
        return NSBootPolicyFail(error, NSFilterBootPolicyReadbackFailed,
                                @"The boot-policy setter was rejected; the candidate cannot be enabled.");
    }
}

NSDictionary *NSFilterConfigurationFields(id configuration) {
    if (![configuration respondsToSelector:@selector(filterBrowsers)] ||
        ![configuration respondsToSelector:@selector(filterSockets)] ||
        ![configuration respondsToSelector:@selector(organization)] ||
        ![configuration respondsToSelector:@selector(vendorConfiguration)]) {
        return nil;
    }
    id<NSFilterConfigurationFields> fields = configuration;
    return @{
        @"browsers" : @(fields.filterBrowsers),
        @"sockets" : @(fields.filterSockets),
        @"organization" : [fields.organization copy] ?: NSNull.null,
        @"vendor" : [fields.vendorConfiguration copy] ?: @{}
    };
}

BOOL NSFilterConfigurationValidate(id configuration, NSDictionary *expectedFields, BOOL requireBootPolicy,
                                   NSError **error) {
    if (!expectedFields || ![NSFilterConfigurationFields(configuration) isEqual:expectedFields]) {
        return NSBootPolicyFail(error, NSFilterBootPolicyPersistenceFailed,
                                @"Filter scope, organization, or activation/engine metadata changed.");
    }
    if (requireBootPolicy) {
        BOOL value = NO;
        if (!NSFilterBootPolicyRead(configuration, &value, error)) {
            return NO;
        }
        if (!value) {
            return NSBootPolicyFail(error, NSFilterBootPolicyPersistenceFailed,
                                    @"The actual boot policy was lost or false after copy/save/reload.");
        }
    }
    return YES;
}

id NSFilterConfigurationCheckedCopy(id configuration, BOOL requireBootPolicy, NSError **error) {
    NSDictionary *fields = NSFilterConfigurationFields(configuration);
    if (!NSFilterConfigurationValidate(configuration, fields, requireBootPolicy, error)) {
        return nil;
    }
    @try {
        id copy = [configuration copy];
        if (!copy || !NSFilterConfigurationValidate(copy, fields, requireBootPolicy, error)) {
            NSBootPolicyFail(error, NSFilterBootPolicyCopyFailed,
                             @"The candidate lost its boot policy or configuration fields on copy.");
            return nil;
        }
        return copy;
    } @catch (NSException *exception) {
        NSBootPolicyFail(error, NSFilterBootPolicyCopyFailed,
                         @"The filter configuration could not be copied.");
        return nil;
    }
}

NSDictionary *NSFilterBootPolicyReport(id configuration) {
    BOOL value = NO;
    NSError *error = nil;
    BOOL readable = NSFilterBootPolicyRead(configuration, &value, &error);
    return @{
        @"os" : NSProcessInfo.processInfo.operatingSystemVersionString,
        @"channel" : @"stable",
        @"capability" : readable ? @"typed-access-supported" : error.localizedDescription,
        @"disableDefaultDrop" : readable ? (id) @(value) : @"unknown",
        @"fields" : NSFilterConfigurationFields(configuration) ?: @{}
    };
}

NSString *NSFilterBootPolicyStatus(id configuration, BOOL loaded) {
    if (!loaded) {
        return @"Fallback policy unverified; the saved filter state could not be read.";
    }
    if (!configuration) {
        return @"Fallback policy will be configured when Firewall is enabled.";
    }
    BOOL value = NO;
    if (!NSFilterBootPolicyRead(configuration, &value, NULL)) {
        return @"Fallback policy unavailable or unreadable on this runtime. Leaving Firewall on may "
               @"prevent networking after a stock reboot.";
    }
    if (!value) {
        return @"The saved filter has not migrated to the fallback policy. "
               @"Leaving Firewall on may prevent networking after a stock reboot.";
    }
    return @"Fallback policy read back from preferences. When providers cannot run, the intended "
           @"fallback permits traffic without NetShield2 blocking or monitoring. Compatibility varies.";
}

BOOL NSFilterBootPolicyClaimMigration(NSUserDefaults *defaults, NSString *target, NSError **error) {
    NSString *key = @"NSBootPolicyAutomaticAttempts";
    NSArray *saved = [defaults arrayForKey:key] ?: @[];
    if ([saved containsObject:target]) {
        return NO;
    }
    // Bound storage without evicting claims and creating a retry cycle.
    if (saved.count >= 32) {
        return NSBootPolicyFail(error, NSFilterBootPolicyMigrationLatchFailed,
                                @"Migration attempt storage is full. This new target cannot be recorded; "
                                @"configuration unchanged.");
    }
    @try {
        [defaults setObject:[saved arrayByAddingObject:target] forKey:key];
        if ([defaults synchronize] && [[defaults arrayForKey:key] containsObject:target]) {
            return YES;
        }
    } @catch (NSException *exception) {
        // A failed attempt record must never authorize automatic mutation.
    }
    return NSBootPolicyFail(error, NSFilterBootPolicyMigrationLatchFailed,
                            @"The migration attempt could not be recorded. Configuration unchanged.");
}
