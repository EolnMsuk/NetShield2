#import "NSAppDelegate.h"
#import "NSDashboard.h"
#import "../Shared/NSNotifications.h"

@implementation NSAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    NSRegisterPermissionActions();
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    if (application.applicationState != UIApplicationStateBackground) {
        [self createInterface];
    }
    return YES;
}
- (void)createInterface {
    if (self.window) {
        return;
    }
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.dashboard = [[NSDashboard alloc] initWithStyle:UITableViewStyleInsetGrouped];
    self.window.rootViewController =
        [[UINavigationController alloc] initWithRootViewController:self.dashboard];
    [self.window makeKeyAndVisible];
}
- (void)applicationDidBecomeActive:(UIApplication *)application {
    [self createInterface];
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.dashboard reloadMonitor];
        completionHandler(UNNotificationPresentationOptionNone);
    });
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))completionHandler {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *request = response.notification.request.content.userInfo;
        if ([response.notification.request.content.categoryIdentifier isEqual:NSPermissionCategory] &&
            [request[@"token"] isKindOfClass:NSString.class] &&
            [request[@"identity"] isKindOfClass:NSString.class]) {
            if ([response.actionIdentifier isEqual:NSAllowAction] ||
                [response.actionIdentifier isEqual:NSBlockAction] ||
                [response.actionIdentifier isEqual:NSBlockIncomingAction]) {
                NSError *error = nil;
                NSString *rule = [response.actionIdentifier isEqual:NSAllowAction] ? @"allow"
                                 : [response.actionIdentifier isEqual:NSBlockIncomingAction]
                                     ? @"block-inbound"
                                     : @"block";
                BOOL saved = NSAnswerPermissionRequestWithRule(request, rule, &error);
                if (!saved && ![NSReadPolicy(NULL) automaticallyAllowsIdentity:request[@"identity"]]) {
                    UNMutableNotificationContent *failure = [UNMutableNotificationContent new];
                    failure.title = @"NetShield2 decision not saved";
                    failure.body = error.localizedDescription ?: @"Open NetShield2 to review the request.";
                    [center addNotificationRequest:[UNNotificationRequest
                                                       requestWithIdentifier:@"netshield-action-error"
                                                                     content:failure
                                                                     trigger:nil]
                             withCompletionHandler:nil];
                }
                if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                    [self.dashboard reloadMonitor];
                }
            } else {
                [self.dashboard reloadMonitor];
            }
        }
        completionHandler();
    });
}
@end
