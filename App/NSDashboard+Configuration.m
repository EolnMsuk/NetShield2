#import "NSDashboard+Internal.h"
#import "NSRespring.h"
#import "NSFilterRemoval.h"
#include <errno.h>
#import "../Shared/NSProviderHealth.h"
#import "../Shared/NSValidation.h"

static NSString *NSBootMigrationTarget(NSPolicy *policy) {
    return
        [NSString stringWithFormat:@"boot-policy-1/%@/%@/%ld/sockets=%d",
                                   NSProcessInfo.processInfo.operatingSystemVersionString, @NS_JAILBREAK_TYPE,
                                   (long)NSEngineVersion, [policy.document[@"filterSockets"] boolValue]];
}

static NSInteger NSConfiguredEngine(NEFilterProviderConfiguration *configuration) {
    id engine = configuration.vendorConfiguration[@"engine"];
    return NSUnsignedInteger(engine, NSIntegerMax) ? [engine integerValue] : (engine ? NSIntegerMax : 0);
}

@implementation NSDashboard (Configuration)
- (void)socketFilteringChanged:(UISwitch *)sender {
    if (self.busy || !self.preferencesLoaded || !self.configurationReady) {
        return;
    }
    BOOL enabled = sender.on;
    [self
        updatePolicy:^BOOL(NSMutableDictionary *document, NSError **error) {
            document[@"filterSockets"] = @(enabled);
            return YES;
        }
        completion:^(BOOL saved) {
            if (!saved) {
                return;
            }
            if (self.savedEnabled) {
                [self changeConfiguration:NSConfigurationApplyScope];
            } else {
                self.message = @"Socket filtering preference saved. It applies when Firewall is enabled.";
                [self refreshTableKeepingPosition];
            }
        }];
}
- (void)loadConfiguration {
    [self loadConfigurationWithCompletion:nil];
}
- (void)refreshSavedState {
    self.attemptedProviderUpgrade = YES;
    self.policyBootstrapPending = self.policy == nil;
    self.configurationOperationError = nil;
    self.message = nil;
    [self loadConfiguration];
}
- (void)recordConfigurationError:(NSError *)error operation:(NSString *)operation {
    self.configurationOperationError =
        [NSString stringWithFormat:@"%@: %@ (%@ %ld).", operation, error.localizedDescription, error.domain,
                                   (long)error.code];
}
- (void)loadConfigurationWithCompletion:(void (^)(void))completion {
    if (self.busy) {
        self.configurationRefreshPending = YES;
        if (completion) {
            completion(); // a refresh request is acknowledged, never discarded
        }
        return;
    }
    self.configurationRefreshPending = NO;
    self.busy = YES;
    [self refreshTableKeepingPosition];
    NSConfigurationCoordinator *owner = [NSConfigurationCoordinator new];
    self.configuration = owner;
    NSError *recoveryError = nil;
    NSConfigurationMarkerState marker = [owner beginReadOnly:&recoveryError];
    // A refresh that encountered recovery evidence only reads preferences.
    if (marker != NSConfigurationMarkerNone || owner.reconciledMarker) {
        self.attemptedProviderUpgrade = YES;
    }
    NSUInteger generation = self.storageGeneration;
    BOOL mayBootstrap = self.policyBootstrapPending;
    NEFilterManager *manager = NEFilterManager.sharedManager;
    [owner load:manager
        completion:^(NSError *error) {
            self.preferencesLoaded = !error;
            self.preferenceReadError = error.localizedDescription;
            self.configurationReady = marker == NSConfigurationMarkerNone;
            self.configurationRecoveryError = recoveryError.localizedDescription;
            NEFilterProviderConfiguration *configuration = error ? nil : manager.providerConfiguration;
            if (!error) {
                self.hasSavedPreferences = YES;
                self.savedEnabled = manager.enabled;
                self.savedSocketFiltering = configuration.filterSockets;
                self.savedBrowserFiltering = configuration.filterBrowsers;
                self.savedActivation = configuration.vendorConfiguration[@"activation"];
                NSLog(@"NetShield2 boot-policy loaded enabled=%d package=%@ %@", manager.enabled,
                      @NS_JAILBREAK_TYPE, NSFilterBootPolicyReport(configuration));
            }
            self.bootPolicyStatus = NSFilterBootPolicyStatus(configuration, self.preferencesLoaded);
            NSSharedDirectory *directory = owner.directory;
            BOOL absent = !error && !configuration && !self.savedEnabled;
            // A recorded removal cannot re-enable the absent filter. Keep the
            // NE fence intact while preparing rules for this fresh app launch.
            BOOL safeBootstrap = marker == NSConfigurationMarkerNone || (absent && owner.pendingRemoval);
            dispatch_async(NSAppStorageQueue(), ^{
                NSError *policyError = nil;
                NSPolicy *policy =
                    directory ? NSReadPolicyIn(directory, &policyError) : NSReadPolicy(&policyError);
                // Hold configuration ownership across bootstrap so a queued task
                // cannot repopulate policy after concurrent uninstall cleanup.
                if (mayBootstrap && directory && safeBootstrap && !policy && NSFileIsAbsent(policyError) &&
                    NSEnsurePolicyIn(directory, &policyError)) {
                    policy = NSReadPolicyIn(directory, &policyError);
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [owner finish];
                    self.configuration = nil;
                    self.busy = NO;
                    if (generation == self.storageGeneration) {
                        self.storageGeneration++;
                        self.policy = policy;
                        if (policy) {
                            self.policyBootstrapPending = NO;
                        }
                        self.policyMissing = !policy && NSFileIsAbsent(policyError);
                        self.policyReadError = policy ? nil : policyError.localizedDescription;
                    }
                    NSInteger engine = NSConfiguredEngine(configuration);
                    if (self.preferencesLoaded && self.configurationReady && self.savedEnabled &&
                        engine <= NSEngineVersion && !self.attemptedProviderUpgrade && self.policy) {
                        BOOL bootPolicy = NO;
                        BOOL readable = NSFilterBootPolicyRead(configuration, &bootPolicy, NULL);
                        if (!readable || !bootPolicy || engine < NSEngineVersion ||
                            self.savedSocketFiltering != [self.policy.document[@"filterSockets"] boolValue] ||
                            ![manager.localizedDescription isEqual:NSFilterLocalizedDescription]) {
                            self.attemptedProviderUpgrade = YES;
                            self.automaticMigrationRequested = YES;
                            [self changeConfiguration:NSConfigurationEnable completion:completion];
                            return;
                        }
                    }
                    [self refreshTableKeepingPosition];
                    [self reloadMonitor];
                    if (completion) {
                        completion();
                    }
                    if (self.configurationRefreshPending && !self.busy) {
                        [self loadConfiguration];
                    }
                });
            });
        }];
}
- (void)changeConfiguration:(NSConfigurationOperation)operation {
    [self changeConfiguration:operation completion:nil];
}
- (void)changeConfiguration:(NSConfigurationOperation)operation completion:(void (^)(void))completion {
    if (self.busy) {
        self.message = @"A configuration operation is already in progress.";
        if (completion) {
            completion();
        }
        return;
    }
    if (operation == NSConfigurationDisable) {
        [self cancelUpdateCheck];
    }
    self.configurationOperationError = nil;
    self.message = nil;
    self.busy = YES;
    [self refreshTableKeepingPosition];
    NEFilterManager *manager = NEFilterManager.sharedManager;
    if (operation != NSConfigurationDisable) {
        self.attemptedProviderUpgrade = YES;
        NSFilterRestart *restart = [NSFilterRestart new];
        self.restart = restart;
        restart.manager = (id<NSFilterRestartManager>)manager;
        BOOL automatic = self.automaticMigrationRequested;
        self.automaticMigrationRequested = NO;
        restart.configuration = ^id(id previous, BOOL restoring, NSError **error) {
            if (!restoring && operation == NSConfigurationApplyScope && !manager.enabled) {
                if (error) {
                    *error =
                        [NSError errorWithDomain:@"NetShield2.Configuration"
                                            code:1
                                        userInfo:@{
                                            NSLocalizedDescriptionKey : @"Socket scope saved. The filter was "
                                                                        @"disabled externally and stays off."
                                        }];
                }
                return nil;
            }
            if (NSConfiguredEngine(previous) > NSEngineVersion) {
                if (error) {
                    *error = [NSError
                        errorWithDomain:@"NetShield2.Configuration"
                                   code:1
                               userInfo:@{
                                   NSLocalizedDescriptionKey :
                                       @"A newer engine owns this configuration. Automatic downgrade "
                                       @"migration is unavailable; disable/remove remains available."
                               }];
                }
                return nil;
            }
            NSPolicy *policy = NSReadPolicy(error);
            if (!policy) {
                return nil;
            }
            if (!restoring) {
                NSError *claimError = nil;
                BOOL claimed = NSFilterBootPolicyClaimMigration(NSUserDefaults.standardUserDefaults,
                                                                NSBootMigrationTarget(policy), &claimError);
                if (claimError || (automatic && !claimed)) {
                    if (error) {
                        *error = claimError
                                     ?: [NSError errorWithDomain:@"NetShield2.Configuration"
                                                            code:1
                                                        userInfo:@{
                                                            NSLocalizedDescriptionKey :
                                                                @"Automatic migration already attempted for "
                                                                @"this target. Use an explicit Firewall "
                                                                @"restart while jailbroken to retry."
                                                        }];
                    }
                    return nil;
                }
            }
            NEFilterProviderConfiguration *configuration =
                previous ? NSFilterConfigurationCheckedCopy(previous, NO, error)
                         : [NEFilterProviderConfiguration new];
            if (!configuration) {
                return nil;
            }
            if (!restoring) {
                configuration.filterSockets = [policy.document[@"filterSockets"] boolValue];
                configuration.filterBrowsers = YES;
                if (!previous) {
                    configuration.organization = @"NetShield2";
                }
            }
            NSMutableDictionary *vendor =
                [configuration.vendorConfiguration mutableCopy] ?: [NSMutableDictionary new];
            vendor[@"schema"] = @(NSSchemaVersion);
            vendor[@"engine"] = @(NSEngineVersion);
            vendor[@"activation"] = NSUUID.UUID.UUIDString;
            configuration.vendorConfiguration = vendor;
            if (!NSFilterBootPolicyApply(configuration, error)) {
                return nil;
            }
            return configuration;
        };
        restart.report = ^(NSString *stage, id configuration, BOOL enabled) {
            NSLog(@"NetShield2 boot-policy %@ enabled=%d package=%@ %@", stage, enabled, @NS_JAILBREAK_TYPE,
                  NSFilterBootPolicyReport(configuration));
        };
        restart.isStopped = ^BOOL(BOOL previouslyEnabled) {
            NSStoreLock *lock = NSAcquireProviderLock(NULL);
            if (!lock) {
                return NO;
            }
            [lock unlock];
            NSDictionary *monitor = NSReadMonitor();
            NSInteger engine = NSConfiguredEngine(manager.providerConfiguration);
            if (engine < 20014 && manager.providerConfiguration &&
                (previouslyEnabled || [monitor[@"controlRunning"] boolValue])) {
                return monitor.count && ![monitor[@"controlRunning"] boolValue];
            }
            return YES;
        };
        restart.isRunning = ^BOOL(NEFilterProviderConfiguration *configuration) {
            NSDictionary *monitor = NSReadMonitor();
            return NSHasCurrentControlHeartbeat(monitor, configuration.vendorConfiguration[@"activation"],
                                                NSDate.date) &&
                   ![monitor[@"policyError"] length];
        };
        [restart start:^(NSError *error) {
            self.restart = nil;
            self.busy = NO;
            if (error && error != restart.coordinator.acknowledgementError) {
                [self recordConfigurationError:error operation:@"Enable/restart filter"];
            } else if (!error) {
                self.message = @"Filter configuration read back. Current control provider responding.";
            }
            [self loadConfigurationWithCompletion:completion];
        }];
        return;
    }
    NSConfigurationCoordinator *owner = [NSConfigurationCoordinator new];
    self.configuration = owner;
    NSError *lockError = nil;
    if (![owner begin:&lockError]) {
        self.busy = NO;
        self.configuration = nil;
        [self recordConfigurationError:lockError operation:@"Change configuration"];
        [self loadConfigurationWithCompletion:completion];
        return;
    }
    void (^finished)(NSError *) = ^(NSError *error) {
        [owner finish];
        self.configuration = nil;
        self.busy = NO;
        if (error && error != owner.acknowledgementError) {
            [self recordConfigurationError:error operation:@"Disable filter"];
        } else if (!error) {
            self.message = @"Firewall preference verified off. Your rules are saved.";
        }
        [self loadConfigurationWithCompletion:completion];
    };
    owner.abort = finished;
    [owner load:manager
        completion:^(NSError *loadError) {
            if (loadError) {
                finished(loadError);
                return;
            }
            if (!manager.enabled) {
                finished(nil);
                return;
            }
            void (^saved)(NSError *) = ^(NSError *error) {
                if (error && !owner.acknowledgementError) {
                    finished(error);
                    return;
                }
                [owner load:manager
                    completion:^(NSError *verifyError) {
                        if (!verifyError && manager.enabled) {
                            verifyError =
                                [NSError errorWithDomain:@"NetShield2.Configuration"
                                                    code:1
                                                userInfo:@{
                                                    NSLocalizedDescriptionKey :
                                                        @"Saved preferences did not match the requested "
                                                        @"disabled/absent state. No shared state was removed."
                                                }];
                        }
                        finished([owner writeErrorWithPreferenceError:error readbackError:verifyError]);
                    }];
            };
            manager.enabled = NO;
            [owner save:manager completion:saved];
        }];
}
- (void)refreshThenOfferRespring:(UIBarButtonItem *)sender {
    if (self.busy || self.respringPromptPending) {
        return;
    }
    self.respringPromptPending = YES;
    self.configurationOperationError = nil;
    [self loadConfigurationWithCompletion:^{
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Respring SpringBoard?"
                             message:@"Respringing reloads SpringBoard and can interrupt other apps."
                      preferredStyle:UIAlertControllerStyleAlert];
        __weak UIAlertController *weakAlert = alert;
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                  style:UIAlertActionStyleCancel
                                                handler:^(UIAlertAction *action) {
                                                    self.respringPromptPending = NO;
                                                }]];
        [alert addAction:[UIAlertAction
                             actionWithTitle:@"Respring"
                                       style:UIAlertActionStyleDestructive
                                     handler:^(UIAlertAction *action) {
                                         [weakAlert dismissViewControllerAnimated:YES
                                                                       completion:^{
                                                                           self.respringPromptPending = NO;
                                                                           NSError *error = nil;
                                                                           if (!NSRespring(&error)) {
                                                                               [self showError:error
                                                                                     operation:@"Respring"];
                                                                           }
                                                                       }];
                                     }]];
        [self presentViewController:alert animated:YES completion:nil];
    }];
}
- (void)finishResetWhenStopped:(NSUInteger)attempt {
    if (!self.busy || !self.configuration) {
        return;
    }
    NSConfigurationCoordinator *owner = self.configuration;
    NSError *error = nil;
    if (!NSResetSharedStateIn(owner.directory, self.resetRequiresLegacyStop, NO, &error)) {
        if (NSIsLockContention(error) && attempt < 60) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
                NEFilterManager *manager = NEFilterManager.sharedManager;
                if (self.configuration != owner) {
                    return;
                }
                [owner load:manager
                    completion:^(NSError *readError) {
                        if (!readError && (manager.enabled ||
                                           (self.removeFilterAfterReset && manager.providerConfiguration))) {
                            readError = [NSError
                                errorWithDomain:@"NetShield2.Configuration"
                                           code:EBUSY
                                       userInfo:@{
                                           NSLocalizedDescriptionKey : @"Saved preferences changed while "
                                                                       @"waiting. Shared state was preserved."
                                       }];
                        }
                        if (readError) {
                            if (owner.abort) {
                                owner.abort(readError);
                            }
                            return;
                        }
                        [self finishResetWhenStopped:attempt + 1];
                    }];
            });
            return;
        }
        [self.configuration finish];
        self.configuration = nil;
        self.busy = NO;
        self.message = nil;
        [self recordConfigurationError:error operation:@"Filter verified stopped; finish shared-state reset"];
        [self loadConfiguration];
        return;
    }
    [UNUserNotificationCenter.currentNotificationCenter removeAllPendingNotificationRequests];
    [UNUserNotificationCenter.currentNotificationCenter removeAllDeliveredNotifications];
    self.resetRequiresLegacyStop = NO;
    [self.deferredRequests removeAllObjects];
    self.storageGeneration++;
    self.policy = nil;
    self.monitor = @{};
    self.activityGroups = @[];
    self.activityEvents = @[];
    self.identities = @[];
    self.systemIdentities = @[];
    self.globalRuleKeys = @[];
    NSResetAppPreferences(NSUserDefaults.standardUserDefaults, NSBundle.mainBundle.bundleIdentifier);
    [self.configuration finish];
    self.configuration = nil;
    self.busy = NO;
    self.message = self.removeFilterAfterReset
                       ? @"Filter, settings, rules and history removed. Firewall is off. iOS notification "
                         @"authorization is managed in Settings."
                       : @"Settings, rules and history reset. Firewall is off.";
    [self clearActivitySearch];
    [self refreshTableKeepingPosition];
    [self loadConfiguration];
}
- (void)resetNetShield2 {
    if (self.exportPending) {
        self.message = @"Wait for export to finish, then retry reset.";
        [self refreshTableKeepingPosition];
        return;
    }
    if (self.busy) {
        return;
    }
    self.storageGeneration++;
    self.configurationOperationError = nil;
    [self cancelUpdateCheck];
    self.busy = YES;
    self.message = self.removeFilterAfterReset ? @"Removing the system filter before resetting settings..."
                                               : @"Disabling the firewall before resetting settings...";
    [self refreshTableKeepingPosition];
    NEFilterManager *manager = NEFilterManager.sharedManager;
    NSConfigurationCoordinator *owner = [NSConfigurationCoordinator new];
    self.configuration = owner;
    NSError *lockError = nil;
    if (![owner begin:&lockError]) {
        self.configuration = nil;
        self.busy = NO;
        self.message = nil;
        [self recordConfigurationError:lockError operation:@"Reset configuration"];
        [self loadConfiguration];
        return;
    }
    void (^failed)(NSError *) = ^(NSError *error) {
        [owner finish];
        self.configuration = nil;
        self.busy = NO;
        self.message = nil;
        if (error != owner.acknowledgementError) {
            [self recordConfigurationError:error operation:@"Verify filter stopped before reset"];
        }
        [self loadConfiguration];
    };
    owner.abort = failed;
    [owner load:manager
        completion:^(NSError *error) {
            if (error) {
                failed(error);
                return;
            }
            self.resetRequiresLegacyStop = manager.enabled && manager.providerConfiguration &&
                                           NSConfiguredEngine(manager.providerConfiguration) < 20014;
            if (self.removeFilterAfterReset) {
                NSRemoveLoadedFilter(owner, (id<NSFilterRemovalManager>)manager, ^(NSError *removeError) {
                    if (removeError) {
                        failed(removeError);
                    } else {
                        [self finishResetWhenStopped:0];
                    }
                });
                return;
            }
            void (^verify)(NSError *) = ^(NSError *saveError) {
                if (saveError && !owner.acknowledgementError) {
                    failed(saveError);
                    return;
                }
                [owner load:manager
                    completion:^(NSError *verifyError) {
                        if (!verifyError && manager.enabled) {
                            verifyError = [NSError errorWithDomain:@"NetShield2.Configuration"
                                                              code:1
                                                          userInfo:@{
                                                              NSLocalizedDescriptionKey :
                                                                  @"Saved filter is still enabled/present. "
                                                                  @"Rules and history were preserved."
                                                          }];
                        }
                        NSError *result = [owner writeErrorWithPreferenceError:saveError
                                                                 readbackError:verifyError];
                        if (result) {
                            failed(result);
                            return;
                        }
                        [self finishResetWhenStopped:0];
                    }];
            };
            if (manager.enabled) {
                manager.enabled = NO;
                [owner save:manager completion:verify];
            } else {
                verify(nil);
            }
        }];
}
@end
