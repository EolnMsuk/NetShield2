#import <UserNotifications/UserNotifications.h>
#import "NSStore.h"

#define NSPermissionCategory @"NETSHIELD_PERMISSION"
#define NSAllowAction @"NETSHIELD_ALLOW"
#define NSBlockAction @"NETSHIELD_BLOCK"

// Include notifications left by a previous provider session, which are no
// longer represented in the current permission queue. Re-read the policy in
// each asynchronous callback so disabling the allowance keeps new requests.
static inline void NSRemoveAutomaticallyAllowedNotifications(void) {
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [center getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> *requests) {
        NSPolicy *policy = NSReadPolicy(NULL);
        NSMutableArray *identifiers = [NSMutableArray new];
        for (UNNotificationRequest *request in requests) {
            if ([request.content.categoryIdentifier isEqual:NSPermissionCategory] &&
                [policy automaticallyAllowsIdentity:request.content.userInfo[@"identity"]]) [identifiers addObject:request.identifier];
        }
        if (identifiers.count) [center removePendingNotificationRequestsWithIdentifiers:identifiers];
    }];
    [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
        NSPolicy *policy = NSReadPolicy(NULL);
        NSMutableArray *identifiers = [NSMutableArray new];
        for (UNNotification *notification in notifications) {
            UNNotificationRequest *request = notification.request;
            if ([request.content.categoryIdentifier isEqual:NSPermissionCategory] &&
                [policy automaticallyAllowsIdentity:request.content.userInfo[@"identity"]]) [identifiers addObject:request.identifier];
        }
        if (identifiers.count) [center removeDeliveredNotificationsWithIdentifiers:identifiers];
    }];
}

static inline void NSRegisterPermissionActions(void) {
    UNNotificationActionOptions options = UNNotificationActionOptionAuthenticationRequired;
    UNNotificationAction *allow = [UNNotificationAction actionWithIdentifier:NSAllowAction title:@"Allow app" options:options];
    UNNotificationAction *block = [UNNotificationAction actionWithIdentifier:NSBlockAction title:@"Keep blocking" options:options];
    UNNotificationCategory *category = [UNNotificationCategory categoryWithIdentifier:NSPermissionCategory
        actions:@[allow, block] intentIdentifiers:@[] options:UNNotificationCategoryOptionNone];
    [UNUserNotificationCenter.currentNotificationCenter setNotificationCategories:[NSSet setWithObject:category]];
}
