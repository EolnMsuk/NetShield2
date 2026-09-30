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
    self.busy = YES;
    [self refreshTableKeepingPosition];
    NEFilterManager *manager = NEFilterManager.sharedManager;
    if (operation == NSConfigurationEnable) {
        self.attemptedProviderUpgrade = YES;
        NSFilterRestart *restart = [NSFilterRestart new];
        self.restart = restart;
        restart.manager = (id<NSFilterRestartManager>)manager;
        restart.configuration = ^id(id previous, BOOL restoring, NSError **error) {
            NSPolicy *policy = NSReadPolicy(error);
            if (!policy) {
                return nil;
            }
            NEFilterProviderConfiguration *configuration =
                restoring ? [previous copy] : [NEFilterProviderConfiguration new];
            if (!restoring) {
                configuration.filterSockets = [policy.document[@"filterSockets"] boolValue];
                configuration.filterBrowsers = YES;
                configuration.organization = @"NetShield2";
            }
            NSMutableDictionary *vendor =
                [configuration.vendorConfiguration mutableCopy] ?: [NSMutableDictionary new];
            vendor[@"schema"] = @(NSSchemaVersion);
            vendor[@"engine"] = @(NSEngineVersion);
            vendor[@"activation"] = NSUUID.UUID.UUIDString;
            configuration.vendorConfiguration = vendor;
            return configuration;
        };
        restart.isStopped = ^BOOL(BOOL previouslyEnabled) {
            NSStoreLock *lock = NSAcquireProviderLock(NULL);
            if (!lock) {
                return NO;
            }
            [lock unlock];
            NSDictionary *monitor = NSReadMonitor();
            NSInteger engine = [manager.providerConfiguration.vendorConfiguration[@"engine"] integerValue];
            if (engine < 20014 && manager.providerConfiguration &&
                (previouslyEnabled || [monitor[@"controlRunning"] boolValue])) {
                return monitor.count && ![monitor[@"controlRunning"] boolValue];
            }
            return YES;
        };
        restart.isRunning = ^BOOL(NEFilterProviderConfiguration *configuration) {
            NSDictionary *monitor = NSReadMonitor();
            NSDate *updated = monitor[@"updated"];
            NSTimeInterval age = updated ? -updated.timeIntervalSinceNow : NSMonitorFreshness;
            return [monitor[@"activation"] isEqual:configuration.vendorConfiguration[@"activation"]] &&
                   [monitor[@"controlRunning"] boolValue] && age >= 0 && age < NSMonitorFreshness &&
                   ![monitor[@"policyError"] length];
        };
        [restart start:^(NSError *error) {
            self.restart = nil;
            self.busy = NO;
            if (error) {
                [self showError:error operation:@"Enable/restart filter"];
            } else {
                self.message = @"Filter configuration saved and control provider verified.";
            }
            [self loadConfiguration];
        }];
        return;
    }
    [manager loadFromPreferencesWithCompletionHandler:^(NSError *loadError) {
        if (loadError) {
            self.busy = NO;
            self.loaded = NO;
            [self showError:loadError operation:@"Load before configuration change"];
            return;
        }
        void (^finished)(NSError *) = ^(NSError *error) {
            self.busy = NO;
            if (error) {
                [self showError:error operation:@"Disable/remove filter"];
            } else {
                self.message = operation == NSConfigurationRemove
                                   ? @"System filter removed. You can now uninstall NetShield2."
                                   : @"Firewall is off. Your rules are saved.";
            }
            [self loadConfiguration];
        };
        if (operation == NSConfigurationRemove) {
            [manager removeFromPreferencesWithCompletionHandler:finished];
        } else {
            manager.enabled = NO;
            [manager saveToPreferencesWithCompletionHandler:finished];
        }
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
