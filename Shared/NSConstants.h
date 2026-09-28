#import <Foundation/Foundation.h>

enum {
    NSEngineVersion = 20016,
    NSSchemaVersion = 2,
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
static NSString *const NSMonitorFile = @"monitor.plist";
static NSString *const NSNotificationRetryFile = @"notification-retry.plist";
