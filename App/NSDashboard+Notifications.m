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
- (void)checkSubmittedPermissionDecisions {
    for (NSString *token in self.submittedOnce.allKeys) {
        NSDictionary *request = self.submittedOnce[token];
        BOOL sessionMatches = [request[@"session"] isEqual:self.monitor[@"session"]] &&
                              [request[@"activation"] isEqual:self.monitor[@"activation"]];
        NSString *message = nil;
        if (sessionMatches) {
            for (NSDictionary *result in self.monitor[@"permissionResults"]) {
                if ([token isEqual:result[@"token"]]) {
                    if (![result[@"action"] isEqual:request[@"submittedAction"]]) {
                        message = @"The filter already issued a different decision for this connection.";
                    } else {
                        message = [result[@"action"] isEqual:@"allow"] ? @"The filter issued Allow Once."
                                                                       : @"The filter issued Block Once.";
                    }
                    break;
                }
            }
        }
        if (!message && self.preferencesLoaded && (!sessionMatches || ![self hasFreshMonitor])) {
            message = @"The filter became unavailable. The one-time decision could not be confirmed.";
        }
        if (!message && sessionMatches) {
            NSDictionary *current = nil;
            for (NSDictionary *candidate in self.monitor[@"requests"]) {
                if ([token isEqual:candidate[@"token"]]) {
                    current = candidate;
                    break;
                }
            }
            if ([current[@"expired"] boolValue]) {
                message = @"This connection timed out and was blocked. Retry for a new request.";
            } else if (!current) {
                message =
                    @"The connection is no longer waiting. The one-time decision could not be confirmed.";
            }
        }
        if (message) {
            self.message = message;
            [self.submittedOnce removeObjectForKey:token];
        }
    }
}
- (void)answerRequest:(NSDictionary *)request rule:(NSString *)rule {
    if (self.busy) {
        return;
    }
    NSUInteger generation = self.storageGeneration;
    BOOL defer = [rule isEqual:NSDeferPermissionAction];
    BOOL unidentified = NSUnidentifiedRequest(request);
    BOOL once = [request[@"mode"] isEqual:@"once"];
    dispatch_async(NSAppStorageQueue(), ^{
        NSError *error = nil;
        BOOL automatic = [NSReadPolicy(NULL) automaticallyAllowsIdentity:request[@"identity"]];
        BOOL saved = !automatic && NSAnswerPermissionRequestWithRule(request, rule, &error);
        NSDictionary *destination =
            saved && !unidentified ? NSReadPolicy(NULL).document[@"ruleDestinations"][request[@"identity"]]
                                   : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.storageGeneration != generation) {
                return;
            }
            if (!automatic && !saved) {
                [self showError:error];
            } else if (saved && defer) {
                self.message = @"Request deferred. Open Waiting for Your Decision to review it.";
            } else if (saved && once) {
                [self trackOneTimePermissionRequest:request action:rule];
            } else if (saved) {
                self.storageGeneration++;
                self.message =
                    unidentified
                        ? @"Global rule saved for all apps matching this connection's conditions. "
                          @"If the connection timed out, retry to use the rule."
                        : [NSString
                              stringWithFormat:@"Rule saved for %@. First requested peer: %@. Applies to new "
                                               @"connections in the selected direction. Retry the app if its "
                                               @"connection timed out.",
                                               NSIdentityDisplayName(request[@"identity"]),
                                               NSDestinationSummary(destination)];
            }
            [self reloadMonitor];
        });
    });
}
- (void)presentRequest:(NSDictionary *)request {
    NSPolicy *current = NSReadPolicy(NULL);
    if (self.presentedViewController || ![self hasFreshMonitor] ||
        !NSPermissionGenerationMatches(current, request) || ![current requiresPermissionForRequest:request]) {
        return;
    }
    [self.deferredRequests addObject:request[@"token"]];
    BOOL unidentified = NSUnidentifiedRequest(request);
    BOOL expired = [request[@"expired"] boolValue];
    BOOL once = [request[@"mode"] isEqual:@"once"];
    NSString *message = expired
                            ? @"This connection timed out and was blocked. Retry to create a new connection."
                            : @"Unanswered connections are blocked after 30 seconds.";
    if (unidentified && !(once && expired)) {
        message = [NSString stringWithFormat:@"%@\n\n%@", NSUnidentifiedPermissionScope(request), message];
    }
    NSString *identity = request[@"identity"];
    NSString *fullName = NSIdentityFullDisplayName(identity);
    NSRuleActionController *alert =
        [NSRuleActionController controllerWithTitle:unidentified      ? @"Unidentified connection"
                                                    : fullName.length ? fullName
                                                                      : @"Unidentified app"
                                            message:message];
    alert.detailRows = NSActivityDetailRows(request);
    alert.processNameUnavailable = !fullName.length;
    alert.clipboardText = NSActivityClipboardLine(request);
    alert.connectionLayout = YES;
    alert.opensExpanded = YES;
    alert.centersTitle = YES;
    alert.centersActions = YES;
    NSArray *rules = once && expired ? @[] : NSPermissionRuleValues(request);
    for (NSString *rule in rules) {
        [alert addActionWithTitle:[self ruleTitle:rule]
                             rule:rule
                          handler:^{
                              [self answerRequest:request rule:rule];
                          }];
    }
    if (identity.length && !rules.count) {
        [alert addActionWithTitle:@"Review App Rule"
                             rule:nil
                          handler:^{
                              [self chooseActionForIdentity:identity defaultKey:nil];
                          }];
    }
    if (!unidentified) {
        [alert addActionWithTitle:@"Add Custom Rule"
                             rule:nil
                          handler:^{
                              [self addCustomRuleForIdentity:identity connection:request];
                          }];
    }
    dispatch_block_t defer = nil;
    if (unidentified) {
        defer = ^{
            [self answerRequest:request rule:NSDeferPermissionAction];
        };
    }
    [alert addActionWithTitle:@"Not Now" rule:nil handler:defer];
    self.permissionAlert = alert;
    self.presentedRequest = request;
    [self presentViewController:alert animated:YES completion:nil];
}
@end
