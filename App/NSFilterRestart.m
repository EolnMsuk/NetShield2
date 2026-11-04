#import "NSFilterRestart.h"
#import "NSFilterBootPolicy.h"

NSString *const NSFilterLocalizedDescription = @"Firewall & Monitor";

@interface NSFilterRestart ()
@property(nonatomic, copy) void (^completion)(NSError *);
@property(nonatomic, strong) id previous;
@property(nonatomic, strong) id candidate;
@property(nonatomic, copy) NSDictionary *expectedFields;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *ownedFingerprints;
@property(nonatomic, copy) NSString *previousDescription;
@property(nonatomic) BOOL wasEnabled;
@property(nonatomic) BOOL touchedPreferences;
@property(nonatomic) BOOL restoring;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, strong) NSError *originalError;
@property(nonatomic, copy) void (^defaultSchedule)(NSTimeInterval, void (^)(void));
@property(nonatomic, strong) dispatch_source_t waitTimer;
@property(nonatomic, readwrite) NSFilterRestartState state;
@end

@implementation NSFilterRestart
- (instancetype)init {
    if ((self = [super init])) {
        _defaultSchedule = ^(NSTimeInterval delay, void (^work)(void)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), work);
        };
        _schedule = _defaultSchedule;
    }
    return self;
}
- (NSError *)error:(NSString *)message {
    return [NSError errorWithDomain:@"NetShield2.Configuration"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}
- (void)finish:(NSError *)error {
    void (^completion)(NSError *) = self.completion;
    self.completion = nil;
    [self.coordinator finish];
    if (self.waitTimer) {
        dispatch_source_cancel(self.waitTimer);
    }
    self.waitTimer = nil;
    self.previous = nil;
    self.candidate = nil;
    self.expectedFields = nil;
    self.ownedFingerprints = nil;
    self.generation++;
    if (completion) {
        completion(error);
    }
}
- (void)record:(NSString *)stage {
    if (self.report) {
        self.report(stage, self.manager.providerConfiguration, self.manager.enabled);
    }
}
// Every preference operation owns a generation and a deadline. Duplicate and
// late callbacks cannot start a later phase. A timed-out write may still reach
// the OS: do not race it with a cleanup write or claim a verified final state.
- (void)preferences:(BOOL)save completion:(void (^)(NSError *))completion {
    [self preferences:save authorization:NO completion:completion];
}
- (void)preferences:(BOOL)save authorization:(BOOL)authorization completion:(void (^)(NSError *))completion {
    void (^callback)(NSError *) = ^(NSError *error) {
        self.generation++;
        if (!self.completion) {
            return;
        }
        if (self.coordinator.uncertain) {
            self.state = NSFilterRestartUnknown;
            [self finish:error];
            return;
        }
        if (save && self.coordinator.acknowledgementError) {
            // Stop this transaction after a fresh read. The OS result and local
            // cleanup failure must not start staging or rollback writes.
            [self.coordinator load:self.manager
                        completion:^(NSError *readError) {
                            self.state = NSFilterRestartUnknown;
                            [self finish:[self.coordinator writeErrorWithPreferenceError:error
                                                                           readbackError:readError]];
                        }];
            return;
        }
        completion(error);
    };
    if (save && authorization) {
        [self.coordinator saveWithAuthorization:self.manager completion:callback];
    } else if (save) {
        [self.coordinator save:self.manager completion:callback];
    } else {
        [self.coordinator load:self.manager completion:callback];
    }
}

- (void)rememberFields:(NSDictionary *)fields description:(NSString *)description {
    [self.ownedFingerprints addObject:@{
        @"fields" : NSFilterConfigurationWithoutSaveReceipt(fields) ?: (id)NSNull.null,
        @"description" : description ?: (id)NSNull.null
    }];
}
- (BOOL)ownsLoadedConfiguration {
    NSDictionary *fields = NSFilterConfigurationFields(self.manager.providerConfiguration);
    if (self.manager.providerConfiguration && !fields) {
        return NO;
    }
    return [self.ownedFingerprints containsObject:@{
        @"fields" : NSFilterConfigurationWithoutSaveReceipt(fields) ?: (id)NSNull.null,
        @"description" : self.manager.localizedDescription ?: (id)NSNull.null
    }];
}
- (void)finishExternalChange {
    self.state = NSFilterRestartUnknown;
    [self finish:[self error:@"Saved configuration no longer matches this transaction. No automatic write "
                             @"was made after the mismatch; state is unknown/unverified."]];
}
- (BOOL)constructCandidate:(BOOL)restoring error:(NSError **)error {
    id candidate = self.configuration(self.previous, restoring, error);
    if (!candidate) {
        return NO;
    }
    // Capture fields before copying; a defective copy must not redefine what
    // we expect to read back. Do this before touching the enabled preference.
    NSDictionary *fields = NSFilterConfigurationFields(candidate);
    id copy = NSFilterConfigurationCheckedCopy(candidate, YES, error);
    if (!copy || !NSFilterConfigurationValidate(copy, fields, YES, error)) {
        return NO;
    }
    self.candidate = copy;
    self.expectedFields = fields;
    [self rememberFields:fields
             description:restoring ? self.previousDescription : NSFilterLocalizedDescription];
    if (self.report) {
        self.report(restoring ? @"restore-copy-verified" : @"candidate-copy-verified", copy, NO);
    }
    return YES;
}
- (void)start:(void (^)(NSError *))completion {
    if (self.completion) {
        completion([self error:@"A filter restart is already in progress."]);
        return;
    }
    self.completion = completion;
    if (!self.coordinator) {
        self.coordinator = [NSConfigurationCoordinator new];
    }
    self.coordinator.schedule = self.schedule == self.defaultSchedule ? nil : self.schedule;
    __weak typeof(self) weakSelf = self;
    self.coordinator.abort = ^(NSError *error) {
        NSFilterRestart *owner = weakSelf;
        owner.state = NSFilterRestartUnknown;
        [owner finish:error];
    };
    NSError *lockError = nil;
    if (![self.coordinator beginWithAuthorizationBudget:&lockError]) {
        [self finish:lockError];
        return;
    }
    self.restoring = NO;
    self.ownedFingerprints = [NSMutableArray new];
    self.touchedPreferences = NO;
    self.originalError = nil;
    self.state = NSFilterRestartUnchanged;
    if (!self.manager || !self.configuration || !self.isStopped || !self.isRunning) {
        [self finish:[self error:@"Filter restart dependencies are incomplete; configuration unchanged."]];
        return;
    }
    [self
        preferences:NO
         completion:^(NSError *error) {
             if (error) {
                 [self finish:error];
                 return;
             }
             self.previousDescription = self.manager.localizedDescription;
             [self rememberFields:NSFilterConfigurationFields(self.manager.providerConfiguration)
                      description:self.previousDescription];
             self.wasEnabled = self.manager.enabled;
             // Snapshot old false/missing policy for migration, but never lose an
             // already readable true policy while retaining that snapshot.
             BOOL hadBootPolicy = NO;
             NSFilterBootPolicyRead(self.manager.providerConfiguration, &hadBootPolicy, NULL);
             if (self.manager.providerConfiguration) {
                 NSError *copyError = nil;
                 self.previous = NSFilterConfigurationCheckedCopy(self.manager.providerConfiguration,
                                                                  hadBootPolicy, &copyError);
                 if (!self.previous) {
                     [self finish:[self error:[NSString
                                                  stringWithFormat:@"%@ Previous configuration could not be "
                                                                   @"retained; configuration unchanged.",
                                                                   copyError.localizedDescription]]];
                     return;
                 }
             } else {
                 self.previous = nil;
             }
             NSError *buildError = nil;
             if (![self constructCandidate:NO error:&buildError]) {
                 [self
                     finish:[self error:[NSString
                                            stringWithFormat:
                                                @"%@ Migration did not occur; configuration "
                                                @"unchanged. The saved filter's fallback is unverified.",
                                                buildError.localizedDescription ?: @"Policy unavailable."]]];
                 return;
             }
             [self disableForStaging];
         }];
}
- (void)disableForStaging {
    if (!self.manager.enabled) {
        [self waitForStop:0];
        return;
    }
    self.manager.enabled = NO;
    self.touchedPreferences = YES;
    self.state = NSFilterRestartUnknown;
    [self preferences:YES
           completion:^(NSError *saveError) {
               if (saveError) {
                   [self recover:saveError];
                   return;
               }
               [self preferences:NO
                      completion:^(NSError *loadError) {
                          if (loadError || self.manager.enabled) {
                              [self recover:loadError ?: [self error:@"The old filter did not persist OFF."]];
                              return;
                          }
                          self.state = NSFilterRestartOffVerified;
                          [self record:@"old-off-reloaded"];
                          [self waitForStop:0];
                      }];
           }];
}
- (void)wait:(NSTimeInterval)delay work:(void (^)(void))work {
    if (self.schedule != self.defaultSchedule) {
        self.schedule(delay, work);
        return;
    }
    if (self.waitTimer) {
        dispatch_source_cancel(self.waitTimer);
    }
    self.waitTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!self.waitTimer) {
        self.state = NSFilterRestartUnknown;
        [self finish:[self error:@"Could not allocate the transaction wait timer."]];
        return;
    }
    dispatch_source_set_timer(self.waitTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, NSEC_PER_MSEC * 10);
    dispatch_source_set_event_handler(self.waitTimer, work);
    dispatch_resume(self.waitTimer);
}
- (void)waitForStop:(NSUInteger)attempt {
    if (self.isStopped(self.wasEnabled)) {
        [self stageConfiguration];
        return;
    }
    if (attempt >= 60) {
        [self recover:[self error:@"The previous filter did not finish stopping within 15 seconds."]];
        return;
    }
    NSUInteger generation = self.generation;
    [self wait:0.25
          work:^{
              if (self.completion && generation == self.generation) {
                  [self waitForStop:attempt + 1];
              }
          }];
}
- (BOOL)validateReloadEnabled:(BOOL)enabled error:(NSError **)error {
    NSString *description = self.restoring ? self.previousDescription : NSFilterLocalizedDescription;
    BOOL sameDescription = self.manager.localizedDescription == description ||
                           [self.manager.localizedDescription isEqual:description];
    if (self.manager.enabled != enabled || !sameDescription) {
        if (error) {
            *error =
                [self error:@"The saved filter enabled state or description did not match the transaction."];
        }
        return NO;
    }
    return NSFilterConfigurationValidate(self.manager.providerConfiguration, self.expectedFields, YES, error);
}
- (void)stageConfiguration {
    [self preferences:NO
           completion:^(NSError *loadError) {
               if (loadError) {
                   [self recover:loadError];
                   return;
               }
               if (self.manager.enabled || ![self ownsLoadedConfiguration]) {
                   [self finishExternalChange];
                   return;
               }
               BOOL firstSave = !self.manager.providerConfiguration;
               self.manager.providerConfiguration = self.candidate;
               self.manager.localizedDescription =
                   self.restoring ? self.previousDescription : NSFilterLocalizedDescription;
               self.manager.enabled = NO;
               self.touchedPreferences = YES;
               self.state = NSFilterRestartUnknown;
               [self preferences:YES
                   authorization:firstSave
                      completion:^(NSError *saveError) {
                          if (saveError) {
                              [self recover:saveError];
                              return;
                          }
                          [self preferences:NO
                                 completion:^(NSError *reloadError) {
                                     NSError *validationError = nil;
                                     if (reloadError || ![self validateReloadEnabled:NO
                                                                               error:&validationError]) {
                                         [self recover:reloadError ?: validationError];
                                         return;
                                     }
                                     self.state = NSFilterRestartOffVerified;
                                     [self record:@"staged-off-reloaded-verified"];
                                     [self enableStagedConfiguration];
                                 }];
                      }];
           }];
}
- (void)enableStagedConfiguration {
    self.manager.enabled = YES;
    self.state = NSFilterRestartUnknown;
    [self preferences:YES
        authorization:!self.previous && !self.restoring
           completion:^(NSError *saveError) {
               if (saveError) {
                   [self recover:saveError];
                   return;
               }
               [self preferences:NO
                      completion:^(NSError *loadError) {
                          NSError *validationError = nil;
                          if (loadError || ![self validateReloadEnabled:YES error:&validationError]) {
                              [self recover:loadError ?: validationError];
                              return;
                          }
                          [self record:@"enabled-reloaded-verified"];
                          [self waitForStart:0];
                      }];
           }];
}
- (void)waitForStart:(NSUInteger)attempt {
    if (self.isRunning(self.candidate)) {
        self.state = NSFilterRestartEnabledVerified;
        [self record:@"current-control-heartbeat"];
        [self
            finish:self.restoring
                       ? [self error:[NSString stringWithFormat:@"%@ Previous configuration restored and "
                                                                @"read back with the required fallback "
                                                                @"policy; its current control provider "
                                                                @"responded. Control health does not verify "
                                                                @"every connection.",
                                                                self.originalError.localizedDescription]]
                       : nil];
        return;
    }
    if (attempt >= 60) {
        [self
            recover:[self error:@"The enabled filter did not report its current activation's healthy control "
                                @"provider within 15 seconds."]];
        return;
    }
    NSUInteger generation = self.generation;
    [self wait:0.25
          work:^{
              if (self.completion && generation == self.generation) {
                  [self waitForStart:attempt + 1];
              }
          }];
}
- (void)recover:(NSError *)error {
    if (!self.originalError) {
        self.originalError = error;
    }
    if (!self.previous && self.touchedPreferences) {
        [self removeFailedFirstConfiguration:error];
        return;
    }
    if (self.restoring || !self.wasEnabled || !self.touchedPreferences) {
        [self disableFailedConfiguration:error];
        return;
    }
    self.restoring = YES;
    NSError *buildError = nil;
    if (![self constructCandidate:YES error:&buildError]) {
        [self disableFailedConfiguration:buildError
                                             ?: [self error:@"No safe restoration could be constructed."]];
        return;
    }
    [self preferences:NO
           completion:^(NSError *loadError) {
               if (loadError) {
                   [self disableFailedConfiguration:loadError];
                   return;
               }
               if (![self ownsLoadedConfiguration]) {
                   [self finishExternalChange];
                   return;
               }
               [self disableForStaging];
           }];
}
- (void)removeFailedFirstConfiguration:(NSError *)startupError {
    [self preferences:NO
           completion:^(NSError *loadError) {
               if (loadError) {
                   [self finishFirstConfigurationRecovery:startupError error:loadError];
                   return;
               }
               if ((self.manager.providerConfiguration || self.manager.enabled) &&
                   ![self ownsLoadedConfiguration]) {
                   [self finishExternalChange];
                   return;
               }
               // A failed first installation should return to absence. Leaving
               // a disabled staged profile behind can strand an invalid entry.
               NSRemoveLoadedFilter(self.coordinator, self.manager, ^(NSError *removeError) {
                   [self finishFirstConfigurationRecovery:startupError error:removeError];
               });
           }];
}
- (void)finishFirstConfigurationRecovery:(NSError *)startupError error:(NSError *)recoveryError {
    self.state = recoveryError ? NSFilterRestartUnknown : NSFilterRestartOffVerified;
    if (!recoveryError) {
        [self record:@"first-install-absence-reloaded"];
    }
    NSString *detail =
        recoveryError
            ? [NSString stringWithFormat:@"Could not verify removal of the new profile. %@ (%@ %ld).",
                                         recoveryError.localizedDescription, recoveryError.domain,
                                         (long)recoveryError.code]
            : @"The new profile is absent from saved preferences. Your rules are saved.";
    [self
        finish:[NSError errorWithDomain:startupError.domain
                                   code:startupError.code
                               userInfo:@{
                                   NSLocalizedDescriptionKey : [NSString
                                       stringWithFormat:@"%@ %@", startupError.localizedDescription, detail],
                                   NSUnderlyingErrorKey : startupError
                               }]];
}
- (void)finishDisabledConfiguration:(NSError *)startupError {
    self.state = NSFilterRestartOffVerified;
    [self record:@"recovery-off-reloaded-verified"];
    [self finish:[self error:[NSString
                                 stringWithFormat:@"%@ %@ Firewall preference is verified off. Your rules "
                                                  @"are saved. NetShield2 protection is off; this does not "
                                                  @"verify connectivity.",
                                                  self.originalError.localizedDescription ?: @"",
                                                  startupError.localizedDescription]]];
}
- (void)disableFailedConfiguration:(NSError *)startupError {
    // A fresh load must establish OFF, including after denied initial permission.
    void (^failed)(NSError *) = ^(NSError *cleanupError) {
        self.state = NSFilterRestartUnknown;
        [self finish:[self error:[NSString
                                     stringWithFormat:@"%@ %@ Automatic OFF recovery failed: %@. The saved "
                                                      @"state is unknown/unverified. Your rules are saved. "
                                                      @"Check Settings > General > VPN & Device Management "
                                                      @" > Content Filter before relying on its state.",
                                                      self.originalError.localizedDescription ?: @"",
                                                      startupError.localizedDescription,
                                                      cleanupError.localizedDescription]]];
    };
    [self preferences:NO
           completion:^(NSError *loadError) {
               if (loadError) {
                   failed(loadError);
                   return;
               }
               if (![self ownsLoadedConfiguration]) {
                   [self finishExternalChange];
                   return;
               }
               if (!self.manager.enabled) {
                   [self finishDisabledConfiguration:startupError];
                   return;
               }
               self.manager.enabled = NO;
               [self preferences:YES
                      completion:^(NSError *saveError) {
                          if (saveError) {
                              failed(saveError);
                              return;
                          }
                          [self preferences:NO
                                 completion:^(NSError *verifyError) {
                                     if (verifyError || self.manager.enabled) {
                                         failed(verifyError
                                                    ?: [self error:@"The saved filter is still enabled."]);
                                         return;
                                     }
                                     [self finishDisabledConfiguration:startupError];
                                 }];
                      }];
           }];
}
@end
