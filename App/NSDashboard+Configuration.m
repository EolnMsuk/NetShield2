#import "NSDashboard+Internal.h"
#include <errno.h>

@implementation NSDashboard (Configuration)
- (void)socketFilteringChanged:(UISwitch *)sender {
    if (self.busy || !self.loaded) {
        return;
    }
    BOOL enabled = sender.on;
    NSError *error = nil;
    if (!NSUpdatePolicy(
            ^BOOL(NSMutableDictionary *document, NSError **mutationError) {
                document[@"filterSockets"] = @(enabled);
                return YES;
            },
            &error)) {
        [self showError:error];
        [self reloadMonitor];
        return;
    }
    [self reloadMonitor];
    if (NEFilterManager.sharedManager.enabled) {
        [self changeConfiguration:NSConfigurationEnable];
    } else {
        self.message = @"Socket filtering preference saved. It applies when Firewall is enabled.";
        [self refreshTableKeepingPosition];
    }
}
- (void)loadConfiguration {
    if (self.busy) {
        return;
    }
    self.busy = YES;
    [[NEFilterManager sharedManager] loadFromPreferencesWithCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.loaded = error == nil;
            if (error) {
                [self showError:error operation:@"Load filter configuration"];
            }
            NEFilterManager *manager = NEFilterManager.sharedManager;
            NSInteger configuredEngine =
                [manager.providerConfiguration.vendorConfiguration[@"engine"] integerValue];
            if (!error && manager.enabled && !self.attemptedProviderUpgrade &&
                (configuredEngine < NSEngineVersion ||
                 manager.providerConfiguration.filterSockets !=
                     [NSReadPolicy(NULL).document[@"filterSockets"] boolValue]) &&
                NSReadPolicy(NULL)) {
                self.attemptedProviderUpgrade = YES;
                [self changeConfiguration:NSConfigurationEnable];
                return;
            }
            [self reloadMonitor];
        });
    }];
}
- (void)changeConfiguration:(NSConfigurationOperation)operation {
    if (self.busy) {
        return;
    }
    NSError *policyError = nil;
    if (operation == NSConfigurationEnable && !NSReadPolicy(&policyError)) {
        [self showError:policyError];
        return;
    }
    self.busy = YES;
    NEFilterManager *manager = [NEFilterManager sharedManager];
    [manager loadFromPreferencesWithCompletionHandler:^(NSError *loadError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (loadError) {
                self.busy = NO;
                self.loaded = NO;
                [self showError:loadError operation:@"Load before configuration change"];
                return;
            }
            void (^finished)(NSError *) = ^(NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.busy = NO;
                    NSString *operationName = @"Save disabled filter";
                    NSString *successMessage = @"Firewall is off. Your rules are saved.";
                    if (operation == NSConfigurationEnable) {
                        operationName = @"Save enabled filter";
                        successMessage = @"";
                    } else if (operation == NSConfigurationRemove) {
                        operationName = @"Remove filter configuration";
                        successMessage = @"System filter removed. You can now uninstall NetShield2.";
                    }
                    if (error) {
                        [self showError:error operation:operationName];
                    } else {
                        self.message = successMessage;
                    }
                    [self loadConfiguration];
                });
            };
            if (operation == NSConfigurationRemove) {
                [manager removeFromPreferencesWithCompletionHandler:finished];
                return;
            }
            void (^saveRequestedState)(void) = ^{
                if (operation == NSConfigurationEnable) {
                    NEFilterProviderConfiguration *configuration = [NEFilterProviderConfiguration new];
                    configuration.filterSockets = [NSReadPolicy(NULL).document[@"filterSockets"] boolValue];
                    configuration.filterBrowsers = YES;
                    configuration.organization = @"NetShield2";
                    configuration.vendorConfiguration =
                        @{@"schema" : @(NSSchemaVersion),
                          @"engine" : @(NSEngineVersion)};
                    manager.providerConfiguration = configuration;
                    manager.localizedDescription = @"NetShield2 network access control";
                }
                manager.enabled = operation == NSConfigurationEnable;
                [manager saveToPreferencesWithCompletionHandler:finished];
            };
            if (operation == NSConfigurationEnable && manager.enabled) {
                manager.enabled = NO;
                [manager saveToPreferencesWithCompletionHandler:^(NSError *disableError) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (disableError) {
                            self.busy = NO;
                            [self showError:disableError operation:@"Stop filter before restart"];
                            [self loadConfiguration];
                            return;
                        }
                        [manager loadFromPreferencesWithCompletionHandler:^(NSError *reloadError) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (reloadError) {
                                    self.busy = NO;
                                    self.loaded = NO;
                                    [self showError:reloadError operation:@"Reload filter before restart"];
                                    return;
                                }
                                saveRequestedState();
                            });
                        }];
                    });
                }];
            } else {
                saveRequestedState();
            }
        });
    }];
}
- (void)finishResetWhenStopped:(NSUInteger)attempt {
    NSError *error = nil;
    if (!NSResetSharedStateWithOptions(self.resetRequiresLegacyStop, !self.resetAllSettings, &error)) {
        BOOL busy = [error.domain isEqual:NSPOSIXErrorDomain] &&
                    (error.code == EWOULDBLOCK || error.code == EAGAIN || error.code == EBUSY);
        if (busy && attempt < 60) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
                [self finishResetWhenStopped:attempt + 1];
            });
            return;
        }
        self.busy = NO;
        [self showError:error operation:@"Reset shared state"];
        [self loadConfiguration];
        return;
    }
    [UNUserNotificationCenter.currentNotificationCenter removeAllPendingNotificationRequests];
    [UNUserNotificationCenter.currentNotificationCenter removeAllDeliveredNotifications];
    self.resetRequiresLegacyStop = NO;
    [self.deferredRequests removeAllObjects];
    self.policy = NSReadPolicy(NULL);
    self.monitor = @{};
    self.identities = @[];
    self.loaded = YES;
    self.busy = NO;
    self.message = self.resetAllSettings ? @"All NetShield2 settings, rules and history reset. System filter "
                                           @"removed. iOS notification authorization is managed in Settings."
                                         : @"Rules and history reset. Other settings kept.";
    if (self.resetAllSettings) {
        [NSUserDefaults.standardUserDefaults
            removePersistentDomainForName:NSBundle.mainBundle.bundleIdentifier];
    }
    if (self.restoreFirewallAfterReset) {
        self.restoreFirewallAfterReset = NO;
        [self changeConfiguration:NSConfigurationEnable];
        return;
    }
    [self refreshTableKeepingPosition];
    [self loadConfiguration];
}
- (void)resetNetShield2 {
    if (self.busy) {
        return;
    }
    self.busy = YES;
    self.message = self.resetAllSettings ? @"Removing system filter before resetting all settings..."
                                         : @"Stopping filtering before resetting rules and history...";
    [self refreshTableKeepingPosition];
    NEFilterManager *manager = NEFilterManager.sharedManager;
    [manager loadFromPreferencesWithCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                self.busy = NO;
                [self showError:error operation:@"Load before reset"];
                return;
            }
            self.restoreFirewallAfterReset = !self.resetAllSettings && manager.enabled;
            if (!manager.providerConfiguration) {
                [self finishResetWhenStopped:0];
                return;
            }
            // Build 20014 introduced the provider lifetime lock.
            self.resetRequiresLegacyStop =
                manager.enabled &&
                [manager.providerConfiguration.vendorConfiguration[@"engine"] integerValue] < 20014;
            void (^stopped)(NSError *) = ^(NSError *removeError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (removeError) {
                        self.busy = NO;
                        [self showError:removeError operation:@"Stop filter before reset"];
                        return;
                    }
                    [self finishResetWhenStopped:0];
                });
            };
            if (self.resetAllSettings) {
                [manager removeFromPreferencesWithCompletionHandler:stopped];
            } else if (manager.enabled) {
                manager.enabled = NO;
                [manager saveToPreferencesWithCompletionHandler:stopped];
            } else {
                [self finishResetWhenStopped:0];
            }
        });
    }];
}
@end
