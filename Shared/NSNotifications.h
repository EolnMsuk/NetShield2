#import <UserNotifications/UserNotifications.h>
#import "NSStore.h"
#import "NSRuleChoices.h"
#import "NSPermissionRequest.h"

#define NSPermissionCategory @"NETSHIELD_PERMISSION"
#define NSAllowAction @"NETSHIELD_ALLOW"
#define NSBlockIncomingAction @"NETSHIELD_BLOCK_INCOMING"
#define NSBlockAction @"NETSHIELD_BLOCK"
#define NSDeferPermissionAction @"defer"

static inline NSString *NSPermissionCategoryForDirection(NSString *direction) {
    if ([direction isEqual:@"inbound"]) {
        return @"NETSHIELD_PERMISSION_INCOMING";
    }
    if ([direction isEqual:@"outbound"]) {
        return @"NETSHIELD_PERMISSION_OUTGOING";
    }
    return @"NETSHIELD_PERMISSION_REVIEW";
}
static inline NSString *NSPermissionCategoryForRequest(NSDictionary *request) {
    if (!NSUnidentifiedRequest(request)) {
        return NSPermissionCategoryForDirection(request[@"direction"]);
    }
    NSFlowDirection direction = NSPermissionDirection(request[@"direction"]);
    return direction == NSFlowDirectionInbound    ? @"NETSHIELD_UNIDENTIFIED_INCOMING"
           : direction == NSFlowDirectionOutbound ? @"NETSHIELD_UNIDENTIFIED_OUTGOING"
                                                  : @"NETSHIELD_UNIDENTIFIED";
}
static inline BOOL NSIsPermissionCategory(NSString *category) {
    return [@[
        @"NETSHIELD_PERMISSION", @"NETSHIELD_PERMISSION_INCOMING", @"NETSHIELD_PERMISSION_OUTGOING",
        @"NETSHIELD_PERMISSION_REVIEW", @"NETSHIELD_UNIDENTIFIED_INCOMING",
        @"NETSHIELD_UNIDENTIFIED_OUTGOING", @"NETSHIELD_UNIDENTIFIED"
    ] containsObject:category];
}

static inline BOOL NSIsPermissionNotificationAction(NSString *category, NSDictionary *request,
                                                    NSString *action) {
    if (NSUnidentifiedRequest(request)) {
        return [category isEqual:NSPermissionCategoryForRequest(request)] &&
               ([action isEqual:NSDeferPermissionAction] ||
                [NSPermissionRuleValues(request) containsObject:action]);
    }
    if ([category isEqual:NSPermissionCategory]) {
        return [@[ NSAllowAction, NSBlockAction, NSBlockIncomingAction ] containsObject:action] ||
               [NSPermissionRuleValues(request) containsObject:action];
    }
    return [category isEqual:NSPermissionCategoryForRequest(request)] &&
           [NSPermissionRuleValues(request) containsObject:action];
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
    for (NSString *kind in @[ @"app", @"unidentified" ]) {
        for (NSString *direction in @[ @"inbound", @"outbound", @"unknown" ]) {
            NSDictionary *request = @{@"kind" : kind, @"direction" : direction};
            NSMutableArray *actions = [NSMutableArray new];
            for (NSString *rule in NSPermissionRuleValues(request)) {
                [actions
                    addObject:[UNNotificationAction
                                  actionWithIdentifier:rule
                                                 title:NSDirectionRuleTitle(rule)
                                               options:UNNotificationActionOptionAuthenticationRequired]];
            }
            if (NSUnidentifiedRequest(request)) {
                [actions
                    addObject:[UNNotificationAction actionWithIdentifier:NSDeferPermissionAction
                                                                   title:@"Not Now"
                                                                 options:UNNotificationActionOptionNone]];
            }
            [categories addObject:[UNNotificationCategory
                                      categoryWithIdentifier:NSPermissionCategoryForRequest(request)
                                                     actions:actions
                                           intentIdentifiers:@[]
                                                     options:UNNotificationCategoryOptionNone]];
        }
    }
    [UNUserNotificationCenter.currentNotificationCenter setNotificationCategories:categories];
}
