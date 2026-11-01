#import "NSFilterRestart.h"
#import "NSFilterBootPolicy.h"

NSString *const NSFilterLocalizedDescription = @"Firewall & Monitor";

@interface NSFilterRestart ()
@property(nonatomic, copy) void (^completion)(NSError *);
@property(nonatomic, strong) id previous;
@property(nonatomic, strong) id candidate;
@property(nonatomic, copy) NSDictionary *expectedFields;
@property(nonatomic, copy) NSString *previousDescription;
@property(nonatomic) BOOL wasEnabled;
@property(nonatomic) BOOL touchedPreferences;
@property(nonatomic) BOOL restoring;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, strong) NSError *originalError;
@property(nonatomic, readwrite) NSFilterRestartState state;
@end

@implementation NSFilterRestart
- (instancetype)init {
    if ((self = [super init])) {
        _schedule = ^(NSTimeInterval delay, void (^work)(void)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), work);
        };
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
    NSUInteger generation = ++self.generation;
    self.schedule(10, ^{
        if (generation == self.generation && self.completion) {
            self.state = NSFilterRestartUnknown;
            [self
                finish:
                    [self
                        error:save ? @"Saving filter preferences timed out. A pending write may still "
                                     @"complete; the saved state is unknown/unverified. Your rules are saved."
                                   : @"Loading filter preferences timed out. The saved state is "
                                     @"unknown/unverified. Your rules are saved."]];
        }
    });
    void (^callback)(NSError *) = ^(NSError *error) {
        void (^deliver)(void) = ^{
            if (generation != self.generation || !self.completion) {
                return;
            }
            self.generation++;
            completion(error);
        };
        if (NSThread.isMainThread) {
            deliver();
        } else {
            dispatch_async(dispatch_get_main_queue(), deliver);
        }
    };
    if (save) {
        [self.manager saveToPreferencesWithCompletionHandler:callback];
    } else {
        [self.manager loadFromPreferencesWithCompletionHandler:callback];
    }
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
    if (self.report) {
        self.report(restoring ? @"restore-copy-verified" : @"candidate-copy-verified", copy, NO);
    }
    return YES;
}
- (void)start:(void (^)(NSError *))completion {
    if (self.completion) {
        return;
    }
    self.completion = completion;
    self.restoring = NO;
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
    self.schedule(0.25, ^{
        if (self.completion && generation == self.generation) {
            [self waitForStop:attempt + 1];
        }
    });
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
    [self
        preferences:NO
         completion:^(NSError *loadError) {
             if (loadError || self.manager.enabled) {
                 [self recover:loadError
                                   ?: [self error:@"The filter changed to enabled before disabled staging."]];
                 return;
             }
             self.manager.providerConfiguration = self.candidate;
             self.manager.localizedDescription =
                 self.restoring ? self.previousDescription : NSFilterLocalizedDescription;
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
                                                                @"read back with the required beta fallback "
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
    self.schedule(0.25, ^{
        if (self.completion && generation == self.generation) {
            [self waitForStart:attempt + 1];
        }
    });
}
- (void)recover:(NSError *)error {
    if (!self.originalError) {
        self.originalError = error;
    }
    if (self.restoring || !self.wasEnabled || !self.touchedPreferences || !self.previous) {
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
               [self disableForStaging];
           }];
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
