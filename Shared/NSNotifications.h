#import <UserNotifications/UserNotifications.h>
#import "NSStore.h"
#import "NSRuleChoices.h"

#define NSPermissionCategory @"NETSHIELD_PERMISSION"
#define NSAllowAction @"NETSHIELD_ALLOW"
#define NSBlockIncomingAction @"NETSHIELD_BLOCK_INCOMING"
#define NSBlockAction @"NETSHIELD_BLOCK"

static inline NSString *NSPermissionCategoryForDirection(NSString *direction) {
    if ([direction isEqual:@"inbound"]) {
        return @"NETSHIELD_PERMISSION_INCOMING";
    }
    if ([direction isEqual:@"outbound"]) {
        return @"NETSHIELD_PERMISSION_OUTGOING";
    }
    return @"NETSHIELD_PERMISSION_REVIEW";
}
static inline BOOL NSIsPermissionCategory(NSString *category) {
    return [@[
        @"NETSHIELD_PERMISSION", @"NETSHIELD_PERMISSION_INCOMING", @"NETSHIELD_PERMISSION_OUTGOING",
        @"NETSHIELD_PERMISSION_REVIEW"
    ] containsObject:category];
}

static inline void NSRemoveAutomaticallyAllowedNotifications(void) {
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [center
        getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> *requests) {
            NSPolicy *policy = NSReadPolicy(NULL);
            NSMutableArray *identifiers = [NSMutableArray new];
            for (UNNotificationRequest *request in requests) {
                if (NSIsPermissionCategory(request.content.categoryIdentifier) &&
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
            if (NSIsPermissionCategory(request.content.categoryIdentifier) &&
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
    NSMutableSet *categories = [NSMutableSet new];
    for (NSString *direction in @[ @"inbound", @"outbound", @"unknown" ]) {
        NSMutableArray *actions = [NSMutableArray new];
        for (NSString *rule in NSConnectionRuleValues(direction)) {
            [actions addObject:[UNNotificationAction
                                   actionWithIdentifier:rule
                                                  title:NSDirectionRuleTitle(rule)
                                                options:UNNotificationActionOptionAuthenticationRequired]];
        }
        [categories addObject:[UNNotificationCategory
                                  categoryWithIdentifier:NSPermissionCategoryForDirection(direction)
                                                 actions:actions
                                       intentIdentifiers:@[]
                                                 options:UNNotificationCategoryOptionNone]];
    }
    [UNUserNotificationCenter.currentNotificationCenter setNotificationCategories:categories];
}
