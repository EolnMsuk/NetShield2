#import "NSAppDelegate.h"
#import "NSDashboard.h"
#import "../Shared/NSNotifications.h"
#import "NSRecoveryViewController.h"
#import "NSRecoveryDiagnostics.h"
#import "NSDashboard+Internal.h"

@implementation NSAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    if (!NSRecoveryIsPlainPoC()) {
        NSRegisterPermissionActions();
        UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    }
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
    NSRecoveryViewController *recovery =
        [[NSRecoveryViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    __weak typeof(self) weakSelf = self;
    recovery.openDashboard = ^{
        [weakSelf openDashboard];
    };
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:recovery];
    [self.window makeKeyAndVisible];
}
- (void)openDashboard {
    if (NSRecoveryIsPlainPoC() || NSRecoveryService().busy || self.dashboard) {
        return;
    }
    NSRegisterPermissionActions();
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    self.dashboard = [[NSDashboard alloc] initWithStyle:UITableViewStyleInsetGrouped];
    self.dashboard.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Recovery"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(closeDashboard)];
    UINavigationController *navigation =
        [[UINavigationController alloc] initWithRootViewController:self.dashboard];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [self.window.rootViewController presentViewController:navigation animated:YES completion:nil];
}
- (void)closeDashboard {
    if (self.dashboard.busy) {
        return;
    }
    self.dashboard.recoverySuspended = YES;
    [self.window.rootViewController dismissViewControllerAnimated:YES
                                                       completion:^{
                                                           self.dashboard = nil;
                                                       }];
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
        if (NSRecoveryIsPlainPoC()) {
            completionHandler();
            return;
        }
        NSDictionary *request = response.notification.request.content.userInfo;
        if (NSIsPermissionCategory(response.notification.request.content.categoryIdentifier) &&
            [request[@"token"] isKindOfClass:NSString.class] &&
            [request[@"identity"] isKindOfClass:NSString.class]) {
            if ([NSDirectionRuleValues() containsObject:response.actionIdentifier] ||
                [@[ NSAllowAction, NSBlockAction, NSBlockIncomingAction ]
                    containsObject:response.actionIdentifier]) {
                NSError *error = nil;
                NSString *rule = response.actionIdentifier;
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
