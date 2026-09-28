#import "NSDashboard+Internal.h"

@implementation NSDashboard (Notifications)
- (void)refreshNotificationSettings {
    [UNUserNotificationCenter.currentNotificationCenter
        getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.notificationStatus =
                    settings.authorizationStatus == UNAuthorizationStatusAuthorized &&
                            settings.alertSetting == UNNotificationSettingEnabled
                        ? @"Banners enabled. Tap to change notification settings."
                        : @"Enable notifications and banners to answer requests in other apps.";
                [self refreshTableKeepingPosition];
            });
        }];
}
- (void)authorizeNotificationsThen:(void (^)(void))completion {
    NSRegisterPermissionActions();
    [UNUserNotificationCenter.currentNotificationCenter
        requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                      completionHandler:^(BOOL granted, NSError *error) {
                          dispatch_async(dispatch_get_main_queue(), ^{
                              [self refreshNotificationSettings];
                              if (error) {
                                  [self showError:error operation:@"Notification authorization"];
                              } else if (!granted) {
                                  self.message = @"Notifications are off. Enable Allow Notifications and "
                                                 @"Banners in notification settings.";
                              }
                              NSWriteDocument(@{@"revision" : NSUUID.UUID.UUIDString},
                                              NSNotificationRetryFile, NULL);
                              if (completion) {
                                  completion();
                              }
                          });
                      }];
}
- (void)requestNotifications {
    [UNUserNotificationCenter.currentNotificationCenter
        getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
                    [self authorizeNotificationsThen:nil];
                } else {
                    NSString *settingsURL = UIApplicationOpenSettingsURLString;
                    if (@available(iOS 15.4, *)) {
                        settingsURL = UIApplicationOpenNotificationSettingsURLString;
                    }
                    [UIApplication.sharedApplication openURL:[NSURL URLWithString:settingsURL]
                                                     options:@{}
                                           completionHandler:nil];
                }
            });
        }];
}
- (void)answerRequest:(NSDictionary *)request allow:(BOOL)allow {
    if ([NSReadPolicy(NULL) automaticallyAllowsIdentity:request[@"identity"]]) {
        [self reloadMonitor];
        return;
    }
    NSError *error = nil;
    if (!NSAnswerPermissionRequest(request, allow, &error)) {
        [self showError:error];
    } else {
        self.message = @"Rule saved. Retry the requesting app if its connection timed out.";
    }
    [self reloadMonitor];
}
- (void)presentRequest:(NSDictionary *)request {
    NSPolicy *current = NSReadPolicy(NULL);
    if (self.presentedViewController || ![current requiresPermissionForIdentity:request[@"identity"]]) {
        return;
    }
    [self.deferredRequests addObject:request[@"token"]];
    NSString *message =
        [NSString stringWithFormat:
                      @"%@\n\nSave a rule for this app's incoming and outgoing connections. Unanswered "
                      @"connections are blocked after 30 seconds; retry the app if it has already timed out.",
                      request[@"identity"]];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Allow network access?"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Allow app"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                                [self answerRequest:request allow:YES];
                                            }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Block app"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
                                                [self answerRequest:request allow:NO];
                                            }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Not now" style:UIAlertActionStyleCancel handler:nil]];
    self.permissionAlert = alert;
    self.presentedRequest = request;
    [self presentViewController:alert animated:YES completion:nil];
}
@end
