#import "NSFilterBootPolicy.h"
#import "NSConfigurationCoordinator.h"
#include <string.h>
#import "../Shared/NSValidation.h"
#import "../Shared/NSConstants.h"

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
@property(nonatomic, copy) NSString *serverAddress;
@property(nonatomic, copy) NSString *username;
@property(nonatomic, copy) NSData *passwordReference;
@property(nonatomic, copy) NSData *identityReference;
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
    @try {
        if (![configuration respondsToSelector:@selector(filterBrowsers)] ||
            ![configuration respondsToSelector:@selector(filterSockets)] ||
            ![configuration respondsToSelector:@selector(organization)] ||
            ![configuration respondsToSelector:@selector(vendorConfiguration)]) {
            return nil;
        }
        id<NSFilterConfigurationFields> fields = configuration;
        NSDictionary *vendor = fields.vendorConfiguration ?: @{};
        if (![vendor isKindOfClass:NSDictionary.class]) {
            return nil;
        }
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:vendor
                                                                  format:NSPropertyListBinaryFormat_v1_0
                                                                 options:0
                                                                   error:NULL];
        if (!data || data.length > NSMaximumDocumentBytes) {
            return nil;
        }
        NSDictionary *immutableVendor =
            [NSPropertyListSerialization propertyListWithData:data
                                                      options:NSPropertyListImmutable
                                                       format:NULL
                                                        error:NULL];
        NSMutableDictionary *snapshot = [@{
            @"browsers" : @(fields.filterBrowsers),
            @"sockets" : @(fields.filterSockets),
            @"organization" : [fields.organization copy] ?: NSNull.null,
            @"vendor" : immutableVendor
        } mutableCopy];
        if ([configuration respondsToSelector:@selector(serverAddress)]) {
            snapshot[@"serverAddress"] = [fields.serverAddress copy] ?: NSNull.null;
        }
        if ([configuration respondsToSelector:@selector(username)]) {
            snapshot[@"username"] = [fields.username copy] ?: NSNull.null;
        }
        if ([configuration respondsToSelector:@selector(passwordReference)]) {
            snapshot[@"passwordReference"] = [fields.passwordReference copy] ?: NSNull.null;
        }
        if ([configuration respondsToSelector:@selector(identityReference)]) {
            snapshot[@"identityReference"] = [fields.identityReference copy] ?: NSNull.null;
        }
        return [snapshot copy];
    } @catch (NSException *exception) {
        return nil;
    }
}

NSDictionary *NSFilterConfigurationWithoutSaveReceipt(NSDictionary *fields) {
    NSDictionary *vendor = fields[@"vendor"];
    if (![vendor isKindOfClass:NSDictionary.class] || !vendor[NSPreferenceSaveReceiptKey]) {
        return fields;
    }
    NSMutableDictionary *metadata = [vendor mutableCopy];
    [metadata removeObjectForKey:NSPreferenceSaveReceiptKey];
    NSMutableDictionary *normalized = [fields mutableCopy];
    normalized[@"vendor"] = [metadata copy];
    return [normalized copy];
}

BOOL NSFilterConfigurationValidate(id configuration, NSDictionary *expectedFields, BOOL requireBootPolicy,
                                   NSError **error) {
    NSDictionary *actual =
        NSFilterConfigurationWithoutSaveReceipt(NSFilterConfigurationFields(configuration));
    if (!expectedFields || ![actual isEqual:NSFilterConfigurationWithoutSaveReceipt(expectedFields)]) {
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
        if (!copy || copy == configuration ||
            !NSFilterConfigurationValidate(copy, fields, requireBootPolicy, error)) {
            NSBootPolicyFail(error, NSFilterBootPolicyCopyFailed,
                             @"The candidate lost its boot policy or configuration fields on copy.");
            return nil;
        }
        // Replace a shallow copy's nested vendor aliases with our independently
        // decoded immutable snapshot after verifying the original copy contract.
        [(id<NSFilterConfigurationFields>)copy setVendorConfiguration:fields[@"vendor"]];
        if (!NSFilterConfigurationValidate(copy, fields, requireBootPolicy, error)) {
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
        @"scope" : @{
            @"browsers" : NSFilterConfigurationFields(configuration)[@"browsers"] ?: @NO,
            @"sockets" : NSFilterConfigurationFields(configuration)[@"sockets"] ?: @NO
        }
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
    id raw = [defaults objectForKey:key];
    NSArray *saved = [raw isKindOfClass:NSArray.class] ? raw : @[];
    BOOL valid =
        (!raw || [raw isKindOfClass:NSArray.class]) && saved.count <= 32 && NSBoundedString(target, 512, YES);
    NSMutableSet *unique = [NSMutableSet new];
    for (id claim in saved) {
        if (!NSBoundedString(claim, 512, YES) || [unique containsObject:claim]) {
            valid = NO;
        }
        [unique addObject:claim];
    }
    if (!valid) {
        return NSBootPolicyFail(error, NSFilterBootPolicyMigrationLatchFailed,
                                @"Migration claims are malformed; configuration unchanged. Export saved "
                                @"rules before an explicit settings reset.");
    }
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
