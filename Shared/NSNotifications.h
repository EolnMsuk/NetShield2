#import <UserNotifications/UserNotifications.h>
#import "NSStore.h"

#define NSPermissionCategory @"NETSHIELD_PERMISSION"
#define NSAllowAction @"NETSHIELD_ALLOW"
#define NSBlockIncomingAction @"NETSHIELD_BLOCK_INCOMING"
#define NSBlockAction @"NETSHIELD_BLOCK"

static inline void NSRemoveAutomaticallyAllowedNotifications(void) {
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [center
        getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> *requests) {
            NSPolicy *policy = NSReadPolicy(NULL);
            NSMutableArray *identifiers = [NSMutableArray new];
            for (UNNotificationRequest *request in requests) {
                if ([request.content.categoryIdentifier isEqual:NSPermissionCategory] &&
                    [policy automaticallyAllowsIdentity:request.content.userInfo[@"identity"]]) {
                    [identifiers addObject:request.identifier];
                }
            }
            if (identifiers.count) {
                [center removePendingNotificationRequestsWithIdentifiers:identifiers];
            }
        }];
    [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
        NSPolicy *policy = NSReadPolicy(NULL);
        NSMutableArray *identifiers = [NSMutableArray new];
        for (UNNotification *notification in notifications) {
            UNNotificationRequest *request = notification.request;
            if ([request.content.categoryIdentifier isEqual:NSPermissionCategory] &&
                [policy automaticallyAllowsIdentity:request.content.userInfo[@"identity"]]) {
                [identifiers addObject:request.identifier];
            }
        }
        if (identifiers.count) {
            [center removeDeliveredNotificationsWithIdentifiers:identifiers];
        }
    }];
}

static inline void NSRegisterPermissionActions(void) {
    UNNotificationActionOptions options = UNNotificationActionOptionAuthenticationRequired;
    UNNotificationAction *allow = [UNNotificationAction actionWithIdentifier:NSAllowAction
                                                                       title:@"Allow app"
                                                                     options:options];
    UNNotificationAction *blockIncoming = [UNNotificationAction actionWithIdentifier:NSBlockIncomingAction
                                                                               title:@"Block incoming"
                                                                             options:options];
    UNNotificationAction *block = [UNNotificationAction actionWithIdentifier:NSBlockAction
                                                                       title:@"Keep blocking"
                                                                     options:options];
    UNNotificationCategory *category =
        [UNNotificationCategory categoryWithIdentifier:NSPermissionCategory
                                               actions:@[ allow, blockIncoming, block ]
                                     intentIdentifiers:@[]
                                               options:UNNotificationCategoryOptionNone];
    [UNUserNotificationCenter.currentNotificationCenter
        setNotificationCategories:[NSSet setWithObject:category]];
}
