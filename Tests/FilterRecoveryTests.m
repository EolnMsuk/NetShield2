#import <Foundation/Foundation.h>
#import "../App/NSFilterRecovery.h"

#define REQUIRE(value) NSCAssert((value), @"Recovery assertion failed: %s", #value)

@interface RecoveryFake : NSObject <NSFilterRecoveryManager>
@property(nonatomic, strong) id providerConfiguration;
@property(nonatomic, getter=isEnabled) BOOL enabled;
@property(nonatomic, strong) id persistedConfiguration;
@property(nonatomic) BOOL persistedEnabled;
@property(nonatomic) NSUInteger loads;
@property(nonatomic) NSUInteger saves;
@property(nonatomic) NSUInteger removes;
@property(nonatomic) BOOL retainEnabled;
@property(nonatomic) BOOL residual;
@property(nonatomic) BOOL replaceOnReload;
@property(nonatomic) BOOL disappearOnReload;
@property(nonatomic) BOOL duplicate;
@property(nonatomic) BOOL hold;
@property(nonatomic) BOOL holdSave;
@property(nonatomic, copy) void (^pending)(NSError *);
@property(nonatomic, strong) NSError *loadError;
@property(nonatomic, strong) NSError *saveError;
@property(nonatomic, strong) NSError *removeError;
@property(nonatomic, strong) NSError *reloadError;
@end

@implementation RecoveryFake
- (void)loadFromPreferencesWithCompletionHandler:(void (^)(NSError *))completion {
    self.loads++;
    if (self.hold) {
        self.pending = completion;
        return;
    }
    self.providerConfiguration = self.persistedConfiguration;
    self.enabled = self.persistedEnabled;
    if (self.loads > 1 && self.replaceOnReload) {
        self.providerConfiguration = @{@"activation" : @"replacement"};
    }
    if (self.loads > 1 && self.disappearOnReload) {
        self.providerConfiguration = nil;
        self.enabled = NO;
    }
    NSError *error = self.loads > 1 ? self.reloadError : self.loadError;
    completion(error);
    if (self.duplicate) {
        completion(error);
    }
}
- (void)saveToPreferencesWithCompletionHandler:(void (^)(NSError *))completion {
    self.saves++;
    if (!self.saveError && !self.retainEnabled) {
        self.persistedEnabled = self.enabled;
    }
    if (self.holdSave) {
        self.pending = completion;
        return;
    }
    completion(self.saveError);
    if (self.duplicate) {
        completion(self.saveError);
    }
}
- (void)removeFromPreferencesWithCompletionHandler:(void (^)(NSError *))completion {
    self.removes++;
    if (!self.removeError && !self.residual) {
        self.persistedConfiguration = nil;
        self.persistedEnabled = NO;
    }
    completion(self.removeError);
}
@end

static NSDictionary *RecoveryFingerprint(void) {
    return @{@"activation" : @"original", @"engine" : @20042};
}

static NSFilterRecovery *RecoveryService(RecoveryFake *manager) {
    NSFilterRecovery *service = [NSFilterRecovery new];
    service.manager = manager;
    service.snapshot = ^{
        return @{
            @"present" : @(manager.providerConfiguration != nil),
            @"enabled" : @(manager.enabled),
            @"fingerprint" : manager.providerConfiguration ?: @{}
        };
    };
    // Each test owns its deadline; no real delayed tasks survive the fixture.
    service.schedule = ^(NSTimeInterval unused, void (^work)(void)) {
    };
    return service;
}

static void RecoveryDrain(BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!done() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    }
    REQUIRE(done());
}

void NSRunFilterRecoveryTests(void) {
    // Reload reads independent persisted state, never the NO just assigned in memory.
    for (NSUInteger scenario = 0; scenario < 20; scenario++) {
        RecoveryFake *manager = [RecoveryFake new];
        manager.persistedConfiguration = RecoveryFingerprint();
        manager.persistedEnabled = YES;
        NSError *failure = [NSError errorWithDomain:@"fixture" code:42 userInfo:nil];
        NSString *operation = @"disable";
        NSString *expected = @"disabledVerified";
        NSDictionary *evidence = RecoveryFingerprint();
        switch (scenario) {
        case 1:
            manager.persistedEnabled = NO;
            expected = @"alreadyDisabledVerified";
            break;
        case 2:
            manager.persistedConfiguration = nil;
            manager.persistedEnabled = NO;
            expected = @"noVisibleConfiguration";
            break;
        case 3:
            evidence = nil;
            expected = @"ownershipUnverified";
            break;
        case 4:
            manager.loadError = failure;
            expected = @"inaccessible";
            break;
        case 5:
            manager.saveError = failure;
            expected = @"saveFailed";
            break;
        case 6:
            manager.retainEnabled = YES;
            expected = @"verificationFailed";
            break;
        case 7:
            manager.replaceOnReload = YES;
            expected = @"verificationFailed";
            break;
        case 8:
            manager.disappearOnReload = YES;
            expected = @"verificationFailed";
            break;
        case 9:
            manager.reloadError = failure;
            expected = @"verificationFailed";
            break;
        case 10:
            operation = @"remove";
            expected = @"removedVerified";
            break;
        case 11:
            operation = @"remove";
            manager.removeError = failure;
            expected = @"cannotRemove";
            break;
        case 12:
            operation = @"remove";
            manager.residual = YES;
            expected = @"verificationFailed";
            break;
        case 13:
            manager.duplicate = YES;
            break;
        case 14:
            manager.saveError = [NSError errorWithDomain:@"NEFilterErrorDomain" code:5 userInfo:nil];
            expected = @"permissionDenied";
            break;
        case 15:
            manager.persistedConfiguration = @{@"activation" : @"other"};
            expected = @"ownershipUnverified";
            break;
        case 16:
            operation = @"remove";
            manager.persistedConfiguration = nil;
            manager.persistedEnabled = NO;
            expected = @"noVisibleConfiguration";
            break;
        case 17:
            operation = @"remove";
            manager.persistedEnabled = NO;
            expected = @"removedVerified";
            break;
        case 18:
            manager.saveError = [NSError errorWithDomain:@"NEFilterErrorDomain" code:1 userInfo:nil];
            expected = @"saveFailed";
            break;
        case 19:
            manager.saveError = [NSError errorWithDomain:@"NEFilterErrorDomain" code:3 userInfo:nil];
            expected = @"saveFailed";
            break;
        }
        NSFilterRecovery *service = RecoveryService(manager);
        __block NSUInteger calls = 0;
        __block NSDictionary *result = nil;
        [service perform:operation
                evidence:evidence
              completion:^(NSDictionary *value) {
                  calls++;
                  result = value;
              }];
        RecoveryDrain(^BOOL {
            return result != nil;
        });
        REQUIRE([result[@"status"] isEqual:expected]);
        REQUIRE(calls == 1 && !service.busy);
        BOOL verified = [@[ @"disabledVerified", @"alreadyDisabledVerified", @"removedVerified" ]
            containsObject:expected];
        REQUIRE([result[@"persistedResultVerified"] boolValue] == verified);
        if ((scenario >= 2 && scenario <= 4) || scenario == 15) {
            REQUIRE(manager.saves == 0 && manager.removes == 0);
        }
        if (scenario == 1) {
            REQUIRE(manager.saves == 0 && manager.loads == 2);
        }
        if (scenario == 5 || scenario == 14 || scenario == 18 || scenario == 19) {
            REQUIRE([result[@"lastSuccessfulLoad"][@"enabled"] boolValue]);
            REQUIRE(![result[@"managerMemoryOnly"][@"enabled"] boolValue]);
            // An independently requested removal can succeed after save fails.
            result = nil;
            [service perform:@"remove"
                    evidence:RecoveryFingerprint()
                  completion:^(NSDictionary *value) {
                      result = value;
                  }];
            RecoveryDrain(^BOOL {
                return result != nil;
            });
            REQUIRE([result[@"status"] isEqual:@"removedVerified"]);
        }
    }
    // Timeout, concurrent request, late callback and exactly-once completion.
    RecoveryFake *manager = [RecoveryFake new];
    manager.hold = YES;
    NSFilterRecovery *service = RecoveryService(manager);
    __block void (^deadline)(void);
    service.schedule = ^(NSTimeInterval delay, void (^work)(void)) {
        deadline = work;
    };
    __block NSUInteger calls = 0;
    [service perform:@"disable"
            evidence:RecoveryFingerprint()
          completion:^(NSDictionary *result) {
              REQUIRE([result[@"status"] isEqual:@"timedOut"]);
              calls++;
          }];
    [service perform:@"remove"
            evidence:RecoveryFingerprint()
          completion:^(NSDictionary *result) {
              REQUIRE([result[@"status"] isEqual:@"busy"]);
          }];
    deadline();
    REQUIRE(calls == 1 && service.busy);
    manager.pending(nil);
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    REQUIRE(calls == 1 && manager.saves == 0 && manager.removes == 0);
    [service perform:@"remove"
            evidence:RecoveryFingerprint()
          completion:^(NSDictionary *result) {
              REQUIRE([result[@"status"] isEqual:@"busyUncertain"]);
          }];
    // Save may have persisted even when its callback never arrived. This still
    // cannot produce verified success or a competing removal in this process.
    manager = [RecoveryFake new];
    manager.persistedConfiguration = RecoveryFingerprint();
    manager.persistedEnabled = YES;
    manager.holdSave = YES;
    service = RecoveryService(manager);
    service.schedule = ^(NSTimeInterval delay, void (^work)(void)) {
        deadline = work;
    };
    calls = 0;
    [service perform:@"disable"
            evidence:RecoveryFingerprint()
          completion:^(NSDictionary *result) {
              REQUIRE([result[@"status"] isEqual:@"timedOut"]);
              REQUIRE(![result[@"persistedResultVerified"] boolValue]);
              calls++;
          }];
    RecoveryDrain(^BOOL {
        return manager.pending != nil;
    });
    REQUIRE(!manager.persistedEnabled && manager.saves == 1);
    deadline();
    manager.pending(nil);
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    REQUIRE(calls == 1 && manager.loads == 1 && service.busy);
    NSLog(@"Passed strict filter recovery state-machine fixtures (not NE/device authority tests)");
}
