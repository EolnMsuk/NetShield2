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
- (void)answerRequest:(NSDictionary *)request rule:(NSString *)rule {
    if ([NSReadPolicy(NULL) automaticallyAllowsIdentity:request[@"identity"]]) {
        [self reloadMonitor];
        return;
    }
    NSError *error = nil;
    if (!NSAnswerPermissionRequestWithRule(request, rule, &error)) {
        [self showError:error];
    } else {
        NSDictionary *destination = NSReadPolicy(NULL).document[@"ruleDestinations"][request[@"identity"]];
        self.message = [NSString
            stringWithFormat:@"Rule saved for %@. First requested peer: %@. Applies to all connections from "
                             @"this app. Retry the app if its connection timed out.",
                             request[@"identity"], NSDestinationSummary(destination)];
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
                      @"%@\nFirst requested peer: %@\nCountry: unavailable\n\nUnanswered "
                      @"connections are blocked after 30 seconds; retry the app if it has already timed out.",
                      request[@"identity"], NSDestinationSummary(request[@"destination"])];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Allow network access?"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    for (NSString *rule in @[ @"allow", @"block-inbound", @"block-outbound", @"block" ]) {
        [alert addAction:[UIAlertAction actionWithTitle:[self ruleTitle:rule]
                                                  style:[self ruleActionStyle:rule]
                                                handler:^(UIAlertAction *action) {
                                                    [self answerRequest:request rule:rule];
                                                }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Not Now" style:UIAlertActionStyleCancel handler:nil]];
    self.permissionAlert = alert;
    self.presentedRequest = request;
    [self presentViewController:alert animated:YES completion:nil];
}
@end
