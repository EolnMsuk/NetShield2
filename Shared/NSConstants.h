#import <Foundation/Foundation.h>

enum {
    NSEngineVersion = 20051,
    NSSchemaVersion = 5,
    NSMonitorSchemaVersion = 3,
    NSExportSchemaVersion = 3,
    NSMaximumRuleTransferBytes = 2 * 1024 * 1024,
    NSMaximumPermissionGenerationLength = 257,
    NSMaximumPermissionResponseBytes = 128 * 1024,
    NSMaximumRules = 4096,
    NSMaximumIdentityLength = 1024,
    NSMaximumEvents = 300,
    NSMaximumActiveRequests = 64,
    NSMaximumRequestHistory = 64,
    NSMaximumWaiters = 256,
    NSMaximumWaitersPerIdentity = 16,
    NSMaximumDocumentBytes = 2 * 1024 * 1024,
};

static const NSTimeInterval NSPermissionTimeout = 30;
static const NSTimeInterval NSMonitorFreshness = 8;
static NSString *const NSPolicyFile = @"policy.plist";
static NSString *const NSActivityClearFile = @"activity-clear.plist";
static NSString *const NSMonitorFile = @"monitor.plist";
static NSString *const NSPermissionResponsesFile = @"permission-responses.plist";
static NSString *const NSNotificationRetryFile = @"notification-retry.plist";
static NSString *const NSConfigurationLockFile = @"configuration.lock";
static NSString *const NSPendingConfigurationFile = @"configuration-pending.plist";
static NSString *const NSConfigurationRecoveryFile = @"configuration-recovery.plist";
static NSString *const NSExportCacheDirectory = @"Library/Caches/NetShield2/Exports";
