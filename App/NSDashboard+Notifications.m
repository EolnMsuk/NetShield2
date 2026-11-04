#import "NSDashboard+Internal.h"
#import "../Shared/NSRuleChoices.h"
#import "../Shared/NSActivity.h"

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
    NSUInteger intent = self.enableIntentGeneration;
    NSUInteger storage = self.storageGeneration;
    __block BOOL delivered = NO;
    [UNUserNotificationCenter.currentNotificationCenter
        requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                      completionHandler:^(BOOL granted, NSError *error) {
                          dispatch_async(dispatch_get_main_queue(), ^{
                              if (delivered || (completion ? intent != self.enableIntentGeneration
                                                           : storage != self.storageGeneration)) {
                                  return;
                              }
                              delivered = YES;
                              NSLog(@"NetShield2 notification-authorization granted=%d error=%@/%ld", granted,
                                    error.domain ?: @"ok", (long)error.code);
                              [self refreshNotificationSettings];
                              if (error) {
                                  [self showError:error operation:@"Notification authorization"];
                              } else if (!granted) {
                                  self.message = @"Notifications are off. Enable Allow Notifications and "
                                                 @"Banners in notification settings.";
                              }
                              if (!self.busy) {
                                  NSWriteNotificationRetryRevision(NULL);
                              }
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
    if (self.busy) {
        return;
    }
    NSUInteger generation = self.storageGeneration;
    dispatch_async(NSAppStorageQueue(), ^{
        NSError *error = nil;
        BOOL automatic = [NSReadPolicy(NULL) automaticallyAllowsIdentity:request[@"identity"]];
        BOOL saved = !automatic && NSAnswerPermissionRequestWithRule(request, rule, &error);
        NSDictionary *destination =
            saved ? NSReadPolicy(NULL).document[@"ruleDestinations"][request[@"identity"]] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.storageGeneration != generation) {
                return;
            }
            if (!automatic && !saved) {
                [self showError:error];
            }
            if (saved) {
                self.storageGeneration++;
                self.message = [NSString
                    stringWithFormat:
                        @"Rule saved for %@. First requested peer: %@. Applies to new connections in the "
                        @"selected direction. Retry the app if its connection timed out.",
                        NSIdentityDisplayName(request[@"identity"]), NSDestinationSummary(destination)];
            }
            [self reloadMonitor];
        });
    });
}
- (void)presentRequest:(NSDictionary *)request {
    NSPolicy *current = NSReadPolicy(NULL);
    if (self.presentedViewController || ![current requiresPermissionForRequest:request]) {
        return;
    }
    [self.deferredRequests addObject:request[@"token"]];
    NSString *message =
        @"Unanswered connections are blocked after 30 seconds; retry the app if it has already timed out.";
    NSString *identity = request[@"identity"];
    NSRuleActionController *alert =
        [NSRuleActionController controllerWithTitle:identity.length ? identity : @"Unidentified app"
                                            message:message];
    alert.detailRows = NSActivityDetailRows(request);
    alert.clipboardText = NSActivityClipboardLine(request);
    alert.connectionLayout = YES;
    alert.opensExpanded = YES;
    alert.centersTitle = YES;
    alert.centersActions = YES;
    for (NSString *rule in NSConnectionRuleValues(request[@"direction"])) {
        [alert addActionWithTitle:[self ruleTitle:rule]
                             rule:rule
                          handler:^{
                              [self answerRequest:request rule:rule];
                          }];
    }
    if (identity.length && !NSConnectionRuleValues(request[@"direction"]).count) {
        [alert addActionWithTitle:@"Review App Rule"
                             rule:nil
                          handler:^{
                              [self chooseActionForIdentity:identity defaultKey:nil];
                          }];
    }
    [alert addActionWithTitle:@"Add Custom Rule"
                         rule:nil
                      handler:^{
                          [self addCustomRuleForIdentity:request[@"identity"] connection:request];
                      }];
    [alert addActionWithTitle:@"Not Now" rule:nil handler:nil];
    self.permissionAlert = alert;
    self.presentedRequest = request;
    [self presentViewController:alert animated:YES completion:nil];
}
@end
