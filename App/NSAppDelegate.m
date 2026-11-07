#import "NSAppDelegate.h"
#import "NSDashboard.h"
#import "NSAppStorage.h"
#import "../Shared/NSNotifications.h"

@implementation NSAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    NSRegisterConfigurationExecution();
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
    NSResumeConfigurationExecution();
    [self createInterface];
}
- (UIInterfaceOrientationMask)application:(UIApplication *)application
    supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    return UIInterfaceOrientationMaskPortrait;
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
    NSDictionary *request = response.notification.request.content.userInfo;
    NSString *rule = response.actionIdentifier;
    BOOL decision = NSIsPermissionCategory(response.notification.request.content.categoryIdentifier) &&
                    [request[@"token"] isKindOfClass:NSString.class] &&
                    [request[@"identity"] isKindOfClass:NSString.class] &&
                    ([NSDirectionRuleValues() containsObject:rule] ||
                     [@[ NSAllowAction, NSBlockAction, NSBlockIncomingAction ] containsObject:rule]);
    if (!decision) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.dashboard reloadMonitor];
            completionHandler();
        });
        return;
    }
    __block BOOL delivered = NO; // main queue only
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 5;
    dispatch_block_t expiry = dispatch_block_create(0, ^{
        if (!delivered) {
            delivered = YES;
            completionHandler();
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), expiry);
    dispatch_async(NSAppStorageQueue(), ^{
        // A queued action which outlived its background budget cannot replay.
        if (NSProcessInfo.processInfo.systemUptime >= deadline) {
            return;
        }
        NSError *error = nil;
        BOOL saved = NSAnswerPermissionRequestWithRule(request, rule, &error);
        BOOL automatic = !saved && [NSReadPolicy(NULL) automaticallyAllowsIdentity:request[@"identity"]];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (delivered) {
                return;
            }
            delivered = YES;
            dispatch_block_cancel(expiry);
            if (!saved && !automatic) {
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
            completionHandler();
        });
    });
}
@end
