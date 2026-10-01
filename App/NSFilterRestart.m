#import "NSFilterRestart.h"

@interface NSFilterRestart ()
@property(nonatomic, copy) void (^completion)(NSError *);
@property(nonatomic, strong) id previous;
@property(nonatomic, copy) NSString *previousDescription;
@property(nonatomic) BOOL wasEnabled;
@property(nonatomic) BOOL touchedPreferences;
@property(nonatomic) BOOL restoring;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, strong) NSError *originalError;
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
- (void)start:(void (^)(NSError *))completion {
    if (self.completion) {
        return;
    }
    self.completion = completion;
    self.restoring = NO;
    self.touchedPreferences = NO;
    NSUInteger generation = ++self.generation;
    [self.manager loadFromPreferencesWithCompletionHandler:^(NSError *error) {
        if (generation != self.generation || !self.completion) {
            return;
        }
        self.generation++;
        if (error) {
            [self finish:error];
            return;
        }
        self.previous = [self.manager.providerConfiguration copy];
        self.previousDescription = self.manager.localizedDescription;
        self.wasEnabled = self.manager.enabled;
        NSError *validationError = nil;
        if (!self.configuration(nil, NO, &validationError)) {
            [self finish:validationError ?: [self error:@"Policy unavailable; configuration unchanged."]];
            return;
        }
        if (self.wasEnabled) {
            self.manager.enabled = NO;
            self.touchedPreferences = YES;
            NSUInteger saveGeneration = self.generation;
            [self.manager saveToPreferencesWithCompletionHandler:^(NSError *saveError) {
                if (saveGeneration != self.generation || !self.completion) {
                    return;
                }
                self.generation++;
                if (saveError) {
                    [self recover:saveError];
                } else {
                    [self waitForStop:0];
                }
            }];
        } else {
            [self waitForStop:0];
        }
    }];
}
- (void)waitForStop:(NSUInteger)attempt {
    if (self.isStopped(self.wasEnabled)) {
        [self saveConfiguration];
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
- (void)saveConfiguration {
    NSUInteger generation = ++self.generation;
    [self.manager loadFromPreferencesWithCompletionHandler:^(NSError *error) {
        if (generation != self.generation || !self.completion) {
            return;
        }
        self.generation++;
        if (error) {
            [self recover:error];
            return;
        }
        NSError *buildError = nil;
        id configuration = self.configuration(self.previous, self.restoring, &buildError);
        if (!configuration) {
            [self recover:buildError ?: [self error:@"Unable to construct filter configuration."]];
            return;
        }
        self.manager.providerConfiguration = configuration;
        self.manager.localizedDescription =
            self.restoring ? self.previousDescription : @"NetShield2 network access control";
        self.manager.enabled = YES;
        self.touchedPreferences = YES;
        NSUInteger saveGeneration = self.generation;
        [self.manager saveToPreferencesWithCompletionHandler:^(NSError *saveError) {
            if (saveGeneration != self.generation || !self.completion) {
                return;
            }
            self.generation++;
            if (saveError) {
                [self recover:saveError];
            } else {
                [self waitForStart:configuration attempt:0];
            }
        }];
    }];
}
- (void)waitForStart:(id)configuration attempt:(NSUInteger)attempt {
    if (self.isRunning(configuration)) {
        [self
            finish:self.restoring
                       ? [self error:[NSString stringWithFormat:@"%@ Previous filter configuration restored "
                                                                @"and its control provider verified.",
                                                                self.originalError.localizedDescription]]
                       : nil];
        return;
    }
    if (attempt >= 60) {
        [self recover:[self error:@"The enabled filter did not report a healthy control provider within 15 "
                                  @"seconds."]];
        return;
    }
    NSUInteger generation = self.generation;
    self.schedule(0.25, ^{
        if (self.completion && generation == self.generation) {
            [self waitForStart:configuration attempt:attempt + 1];
        }
    });
}
- (void)recover:(NSError *)error {
    if (self.restoring || !self.wasEnabled || !self.touchedPreferences || !self.previous) {
        if (self.touchedPreferences) {
            [self disableFailedConfiguration:error];
            return;
        }
        [self finish:[self error:[NSString stringWithFormat:@"%@ Filtering is not verified; check Firewall "
                                                            @"status before relying on protection.",
                                                            error.localizedDescription]]];
        return;
    }
    self.originalError = error;
    self.restoring = YES;
    NSUInteger generation = ++self.generation;
    [self.manager loadFromPreferencesWithCompletionHandler:^(NSError *loadError) {
        if (generation != self.generation || !self.completion) {
            return;
        }
        self.generation++;
        if (loadError) {
            [self recover:loadError];
            return;
        }
        self.manager.enabled = NO;
        NSUInteger saveGeneration = self.generation;
        [self.manager saveToPreferencesWithCompletionHandler:^(NSError *saveError) {
            if (saveGeneration != self.generation || !self.completion) {
                return;
            }
            self.generation++;
            if (saveError) {
                [self recover:saveError];
            } else {
                [self waitForStop:0];
            }
        }];
    }];
}
- (void)finishDisabledConfiguration:(NSError *)startupError {
    [self finish:[self error:[NSString stringWithFormat:@"%@ Firewall is off because startup could not be "
                                                        @"verified. Traffic is no longer protected by "
                                                        @"NetShield2. Your rules are saved.",
                                                        startupError.localizedDescription]]];
}
- (void)disableFailedConfiguration:(NSError *)startupError {
    // An enabled configuration whose providers never start can hold all traffic.
    // After a failed first activation or failed rollback, persist OFF and verify it.
    // Never claim that a failed preference write restored connectivity.
    NSUInteger generation = ++self.generation;
    void (^failed)(NSError *) = ^(NSError *cleanupError) {
        [self finish:[self error:[NSString
                                     stringWithFormat:@"%@ Automatic disable failed: %@. Turn Firewall off "
                                                      @"in Settings > General > VPN & Device Management > "
                                                      @"Content Filter. Filtering is not verified.",
                                                      startupError.localizedDescription,
                                                      cleanupError.localizedDescription]]];
    };
    [self.manager loadFromPreferencesWithCompletionHandler:^(NSError *loadError) {
        if (generation != self.generation || !self.completion) {
            return;
        }
        self.generation++;
        if (loadError) {
            failed(loadError);
            return;
        }
        if (!self.manager.enabled) {
            // Do not create/save a configuration after the user denies the
            // initial content-filter permission prompt.
            [self finishDisabledConfiguration:startupError];
            return;
        }
        self.manager.enabled = NO;
        NSUInteger saveGeneration = self.generation;
        [self.manager saveToPreferencesWithCompletionHandler:^(NSError *saveError) {
            if (saveGeneration != self.generation || !self.completion) {
                return;
            }
            self.generation++;
            if (saveError) {
                failed(saveError);
                return;
            }
            NSUInteger verifyGeneration = self.generation;
            [self.manager loadFromPreferencesWithCompletionHandler:^(NSError *verifyError) {
                if (verifyGeneration != self.generation || !self.completion) {
                    return;
                }
                self.generation++;
                if (verifyError || self.manager.enabled) {
                    failed(verifyError ?: [self error:@"The saved filter is still enabled."]);
                    return;
                }
                [self finishDisabledConfiguration:startupError];
            }];
        }];
    }];
}
@end
