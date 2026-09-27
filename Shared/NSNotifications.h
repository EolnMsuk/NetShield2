#import <UserNotifications/UserNotifications.h>

#define NSPermissionCategory @"NETSHIELD_PERMISSION"
#define NSAllowAction @"NETSHIELD_ALLOW"
#define NSBlockAction @"NETSHIELD_BLOCK"

static inline void NSRegisterPermissionActions(void) {
    UNNotificationActionOptions options = UNNotificationActionOptionAuthenticationRequired;
    UNNotificationAction *allow = [UNNotificationAction actionWithIdentifier:NSAllowAction title:@"Allow app" options:options];
    UNNotificationAction *block = [UNNotificationAction actionWithIdentifier:NSBlockAction title:@"Keep blocking" options:options];
    UNNotificationCategory *category = [UNNotificationCategory categoryWithIdentifier:NSPermissionCategory
        actions:@[allow, block] intentIdentifiers:@[] options:UNNotificationCategoryOptionNone];
    [UNUserNotificationCenter.currentNotificationCenter setNotificationCategories:[NSSet setWithObject:category]];
}
