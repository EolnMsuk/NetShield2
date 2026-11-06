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

static NSDictionary *NSSavedFilterFingerprint(NEFilterManager *manager) {
    NEFilterProviderConfiguration *configuration = manager.providerConfiguration;
    BOOL fallback = NO;
    BOOL fallbackReadable = NSFilterBootPolicyRead(configuration, &fallback, NULL);
    return @{
        @"enabled" : @(manager.enabled),
        @"description" : manager.localizedDescription ?: (id)NSNull.null,
        @"present" : @(configuration != nil),
        @"fields" : NSFilterConfigurationFields(configuration) ?: (id)NSNull.null,
        @"fallback" : fallbackReadable ? @(fallback) : (id)NSNull.null
    };
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
    self.policyBootstrapPending = YES;
    [NSConfigurationCoordinator checkPendingSave];
    [self loadConfiguration];
}
- (void)recordConfigurationError:(NSError *)error operation:(NSString *)operation {
    self.configurationOperationError =
        [NSString stringWithFormat:@"%@: %@ (%@ %ld).", operation, error.localizedDescription, error.domain,
                                   (long)error.code];
}
- (void)loadConfigurationWithCompletion:(void (^)(void))completion {
    [self loadConfigurationWithRetry:YES completion:completion];
}
- (void)loadConfigurationWithRetry:(BOOL)allowRetry completion:(void (^)(void))completion {
    if (self.busy) {
        self.configurationRefreshPending = YES;
        if (completion) {
            completion(); // a refresh request is acknowledged, never discarded
        }
        return;
    }
    self.configurationRefreshPending = NO;
    NEFilterManager *manager = NEFilterManager.sharedManager;
    NSConfigurationRecoveryAction lane = [NSConfigurationCoordinator recoveryForManager:manager];
    if (lane != NSConfigurationRecoveryNone) {
        self.preferencesLoaded = NO;
        self.bootPolicyStatus = NSFilterBootPolicyStatus(nil, NO);
        self.bootPolicyNeedsAttention = YES;
        self.configurationReady = NO;
        self.attemptedProviderUpgrade = YES;
        self.configurationRecoveryAction = lane;
        self.configurationRecoveryError = nil;
        [self refreshTableKeepingPosition];
        if (completion) {
            completion();
        }
        return;
    }
    self.busy = YES;
    [self refreshTableKeepingPosition];
    NSConfigurationCoordinator *owner = [NSConfigurationCoordinator new];
    self.configuration = owner;
    NSConfigurationMarkerState marker = [owner beginReadOnly:NULL];
    // A refresh that encountered recovery evidence only reads preferences.
    if (marker != NSConfigurationMarkerNone || owner.reconciledMarker) {
        self.attemptedProviderUpgrade = YES;
    }
    NSUInteger generation = self.storageGeneration;
    [owner load:manager
        completion:^(NSError *error) {
            self.preferencesLoaded = !error;
            self.preferenceReadError = error.localizedDescription;
            self.configurationRecoveryAction = owner.recoveryAction;
            self.configurationReady = (owner.markerState == NSConfigurationMarkerNone ||
                                       owner.markerState == NSConfigurationMarkerReserved) &&
                                      self.configurationRecoveryAction != NSConfigurationRecoveryReopenApp;
            self.configurationRecoveryError = owner.markerError.localizedDescription;
            NEFilterProviderConfiguration *configuration = error ? nil : manager.providerConfiguration;
            if (!error) {
                self.hasSavedPreferences = YES;
                self.savedEnabled = manager.enabled;
                self.savedSocketFiltering = configuration.filterSockets;
                self.savedBrowserFiltering = configuration.filterBrowsers;
                self.savedActivation = configuration.vendorConfiguration[@"activation"];
                self.savedConfigurationFingerprint = NSSavedFilterFingerprint(manager);
                NSLog(@"NetShield2 boot-policy loaded enabled=%d package=%@ %@", manager.enabled,
                      @NS_JAILBREAK_TYPE, NSFilterBootPolicyReport(configuration));
            }
            self.bootPolicyStatus = NSFilterBootPolicyStatus(configuration, self.preferencesLoaded);
            BOOL fallback = NO;
            BOOL fallbackReadable = configuration && NSFilterBootPolicyRead(configuration, &fallback, NULL);
            self.bootPolicyNeedsAttention =
                !self.preferencesLoaded ||
                (configuration ? !fallbackReadable || !fallback : self.savedEnabled);
            NSSharedDirectory *directory = owner.directory;
            NSConfigurationAccess *access = owner.localAccess;
            BOOL safeBootstrap = !error && access != nil;
            // An automatic refresh of an already initialized app must not
            // recreate rules after the uninstall helper removes the profile.
            BOOL mayBootstrap = self.policyBootstrapPending || (configuration && !self.savedEnabled);
            dispatch_async(NSAppStorageQueue(), ^{
                NSError *policyError = nil;
                NSPolicy *policy =
                    directory ? NSReadPolicyIn(directory, &policyError) : NSReadPolicy(&policyError);
                // The queued capability must still match under the short lock;
                // removal can replace the idle reservation before this runs.
                BOOL bootstrap =
                    mayBootstrap && directory && safeBootstrap && !policy && NSFileIsAbsent(policyError);
                if (bootstrap && [access
                                     perform:^BOOL(NSSharedDirectory *ownedDirectory, NSError **localError) {
                                         return NSEnsurePolicyIn(ownedDirectory, localError);
                                     }
                                       error:&policyError]) {
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
                        } else if (bootstrap) {
                            self.policyBootstrapPending = YES;
                        }
                        self.policyMissing = !policy && NSFileIsAbsent(policyError);
                        self.policyReadError = policy ? nil : policyError.localizedDescription;
                    }
                    BOOL retry = self.configurationRecoveryAction == NSConfigurationRecoveryRetryRead ||
                                 (self.configurationRecoveryAction == NSConfigurationRecoveryNone &&
                                  (error || (bootstrap && !policy)));
                    if (allowRetry && retry) {
                        self.attemptedProviderUpgrade = YES;
                        [self loadConfigurationWithRetry:NO completion:completion];
                        return;
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
    self.configurationOperationAction = NSConfigurationRecoveryNone;
    BOOL explicitEnable = operation == NSConfigurationEnable && self.configurationProgress != nil;
    if (!explicitEnable) {
        self.message = nil;
    }
    if (operation != NSConfigurationDisable) {
        self.configurationProgress = @"Setting up Firewall. Approve any iOS prompts.";
    }
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
        if (automatic) {
            restart.coordinator = [NSConfigurationCoordinator new];
            restart.coordinator.replaceIdleReservation = NO;
        }
        NSUInteger intent = self.enableIntentGeneration;
        if (explicitEnable || automatic) {
            NSDictionary *baseline = self.savedConfigurationFingerprint;
            restart.acceptInitialState = ^BOOL {
                return (!explicitEnable || self.enableIntentGeneration == intent) &&
                       [baseline isEqual:NSSavedFilterFingerprint(manager)];
            };
        }
        restart.isExternalPreferenceError = ^BOOL(NSError *error) {
            return [error.domain isEqual:NEFilterErrorDomain] &&
                   error.code == NEFilterManagerErrorConfigurationStale;
        };
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
            if ([stage isEqual:@"enabled-reloaded-verified"]) {
                self.savedEnabled = YES;
                self.savedActivation = [configuration vendorConfiguration][@"activation"];
                self.configurationProgress = @"Waiting for the current control provider…";
                [self refreshTableKeepingPosition];
            }
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
            NSString *verifiedActivation = self.savedActivation;
            self.restart = nil;
            self.busy = NO;
            self.configurationProgress = nil;
            if (explicitEnable && self.enableIntentGeneration == intent) {
                self.enableIntentGeneration++;
            }
            if (error) {
                // Current marker inspection reports unresolved local cleanup.
                // Retain errors from the OS or verification independently.
                if (![error.userInfo[@"acknowledgementOnly"] boolValue]) {
                    [self recordConfigurationError:error operation:@"Enable/restart filter"];
                }
                NSConfigurationRecoveryAction action = restart.recoveryAction;
                if ([error.domain isEqual:NEFilterErrorDomain]) {
                    if (error.code == NEFilterManagerErrorConfigurationPermissionDenied) {
                        action = NSConfigurationRecoveryConsent;
                    } else if (error.code == NEFilterManagerErrorConfigurationStale) {
                        action = NSConfigurationRecoveryExternalChange;
                    } else if (error.code == NEFilterManagerErrorConfigurationInvalid ||
                               error.code == NEFilterManagerErrorConfigurationInternalError) {
                        action = NSConfigurationRecoveryProvider;
                    }
                }
                self.configurationOperationAction =
                    action == NSConfigurationRecoveryNone ? NSConfigurationRecoveryRetryEnable : action;
            }
            [self loadConfigurationWithCompletion:^{
                if (!error && self.preferencesLoaded) {
                    if (!self.savedEnabled || ![self.savedActivation isEqual:verifiedActivation]) {
                        self.configurationOperationAction = NSConfigurationRecoveryExternalChange;
                        self.configurationOperationError = @"Saved configuration changed after setup.";
                    }
                    [self refreshTableKeepingPosition];
                }
                if (completion) {
                    completion();
                }
            }];
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
    [owner
        performLocalMutation:^BOOL(NSSharedDirectory *directory, NSError **localError) {
            return NSResetSharedStateIn(directory, self.resetRequiresLegacyStop, NO, localError);
        }
        completion:^(NSError *error) {
            if (self.configuration != owner) {
                return;
            }
            if (error) {
                if ((NSIsLockContention(error) && attempt < 60) || NSConfigurationExecutionDeferred(error)) {
                    void (^retry)(void) = ^{
                        NEFilterManager *manager = NEFilterManager.sharedManager;
                        if (self.configuration != owner) {
                            return;
                        }
                        [owner load:manager
                            completion:^(NSError *readError) {
                                if (!readError && (manager.enabled || (self.removeFilterAfterReset &&
                                                                       manager.providerConfiguration))) {
                                    readError =
                                        [NSError errorWithDomain:@"NetShield2.Configuration"
                                                            code:EBUSY
                                                        userInfo:@{
                                                            NSLocalizedDescriptionKey :
                                                                @"Saved preferences changed while "
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
                    };
                    if (NSConfigurationExecutionDeferred(error)) {
                        [owner whenLocalExecutionAvailable:retry];
                    } else {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4),
                                       dispatch_get_main_queue(), retry);
                    }
                    return;
                }
                [self.configuration finish];
                self.configuration = nil;
                self.busy = NO;
                self.message = nil;
                [self recordConfigurationError:error
                                     operation:@"Filter verified stopped; finish shared-state reset"];
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
            self.message =
                self.removeFilterAfterReset
                    ? @"Filter, settings, rules and history removed. Firewall is off. iOS notification "
                      @"authorization is managed in Settings."
                    : @"Settings, rules and history reset. Firewall is off.";
            [self clearActivitySearch];
            [self refreshTableKeepingPosition];
            [self loadConfiguration];
        }];
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
    self.enableIntentGeneration++;
    self.storageGeneration++;
    self.configurationOperationError = nil;
    self.configurationOperationAction = NSConfigurationRecoveryNone;
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
