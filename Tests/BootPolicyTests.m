#import "../App/NSFilterBootPolicy.h"
#import "../App/NSFilterRestart.h"
#import "../Shared/NSProviderHealth.h"

#ifndef NS_BOOT_POLICY_EXPERIMENT
#define NS_BOOT_POLICY_EXPERIMENT 0
#endif

#define CHECK(...)                                                                                           \
    do {                                                                                                     \
        if (!(__VA_ARGS__)) {                                                                                \
            NSLog(@"FAIL %s:%d: %s", __FILE__, __LINE__, #__VA_ARGS__);                                      \
            abort();                                                                                         \
        }                                                                                                    \
    } while (0)

// A real independent copy at each manager boundary is essential: sharing one
// dictionary between the caller and the mock would hide serialization failures.
@interface BootConfiguration : NSObject <NSCopying>
@property(nonatomic) BOOL filterBrowsers;
@property(nonatomic) BOOL filterSockets;
@property(nonatomic, copy) NSString *organization;
@property(nonatomic, copy) NSDictionary *vendorConfiguration;
@property(nonatomic) BOOL bootPolicy;
@property(nonatomic) BOOL missingGetter;
@property(nonatomic) BOOL missingSetter;
@property(nonatomic) BOOL wrongGetterType;
@property(nonatomic) BOOL wrongSetterType;
@property(nonatomic) BOOL rejectSetter;
@property(nonatomic) BOOL throwGetter;
@property(nonatomic) BOOL throwSetter;
@property(nonatomic) BOOL loseOnCopy;
@property(nonatomic) BOOL changeScopeOnCopy;
@property(nonatomic) NSUInteger reads;
@property(nonatomic) NSUInteger writes;
- (BOOL)disableDefaultDrop;
- (void)setDisableDefaultDrop:(BOOL)value;
@end
@implementation BootConfiguration
- (BOOL)respondsToSelector:(SEL)selector {
    if ((selector == @selector(disableDefaultDrop) && self.missingGetter) ||
        (selector == @selector(setDisableDefaultDrop:) && self.missingSetter)) {
        return NO;
    }
    return [super respondsToSelector:selector];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if (selector == @selector(disableDefaultDrop) && self.wrongGetterType) {
        return [NSMethodSignature signatureWithObjCTypes:"@@:"];
    }
    if (selector == @selector(setDisableDefaultDrop:) && self.wrongSetterType) {
        return [NSMethodSignature signatureWithObjCTypes:"v@:@"];
    }
    return [super methodSignatureForSelector:selector];
}
- (BOOL)disableDefaultDrop {
    self.reads++;
    if (self.throwGetter) {
        [NSException raise:@"read rejected" format:@"injected"];
    }
    return self.bootPolicy;
}
- (void)setDisableDefaultDrop:(BOOL)value {
    self.writes++;
    if (self.throwSetter) {
        [NSException raise:@"write rejected" format:@"injected"];
    }
    if (!self.rejectSetter) {
        self.bootPolicy = value;
    }
}
- (id)copyWithZone:(NSZone *)zone {
    BootConfiguration *copy = [BootConfiguration new];
    copy.filterBrowsers = self.filterBrowsers;
    copy.filterSockets = self.changeScopeOnCopy ? !self.filterSockets : self.filterSockets;
    copy.organization = self.organization;
    copy.vendorConfiguration = self.vendorConfiguration;
    copy.bootPolicy = self.loseOnCopy ? NO : self.bootPolicy;
    copy.missingGetter = self.missingGetter;
    copy.missingSetter = self.missingSetter;
    copy.wrongGetterType = self.wrongGetterType;
    copy.wrongSetterType = self.wrongSetterType;
    copy.rejectSetter = self.rejectSetter;
    copy.throwGetter = self.throwGetter;
    copy.throwSetter = self.throwSetter;
    copy.loseOnCopy = self.loseOnCopy;
    copy.changeScopeOnCopy = self.changeScopeOnCopy;
    return copy;
}
@end

static BootConfiguration *BootConfig(NSString *activation, BOOL sockets) {
    BootConfiguration *configuration = [BootConfiguration new];
    configuration.filterBrowsers = YES;
    configuration.filterSockets = sockets;
    configuration.organization = @"NetShield2";
    configuration.vendorConfiguration = @{
        @"activation" : activation,
        @"engine" : @(NSEngineVersion),
        @"schema" : @(NSSchemaVersion),
        @"unrelated" : @"retain on restoration"
    };
    return configuration;
}

@interface BootManager : NSObject <NSFilterRestartManager>
@property(nonatomic, strong) id providerConfiguration;
@property(nonatomic, getter=isEnabled) BOOL enabled;
@property(nonatomic, copy) NSString *localizedDescription;
@property(nonatomic, strong) BootConfiguration *saved;
@property(nonatomic) BOOL savedEnabled;
@property(nonatomic, copy) NSString *savedDescription;
@property(nonatomic) NSUInteger loads;
@property(nonatomic) NSUInteger saves;
@property(nonatomic, copy) NSSet *failingLoads;
@property(nonatomic, copy) NSSet *failingSaves;
@property(nonatomic, copy) NSSet *errorsAfterWrite;
@property(nonatomic, copy) NSSet *stripOnSaves;
@property(nonatomic) NSUInteger hangingLoad;
@property(nonatomic) NSUInteger hangingSave;
@property(nonatomic, copy) void (^afterLoad)(BootManager *manager);
@property(nonatomic, copy) void (^afterSave)(BootManager *manager);
@property(nonatomic, strong) NSMutableArray *callbacks;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *saveRecords;
@end
@implementation BootManager
- (instancetype)init {
    if ((self = [super init])) {
        _saved = BootConfig(@"old", YES);
        _savedEnabled = YES;
        _savedDescription = @"Old description";
        _callbacks = [NSMutableArray new];
        _saveRecords = [NSMutableArray new];
    }
    return self;
}
- (NSError *)failure {
    return [NSError errorWithDomain:@"injected"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : @"Injected preference failure"}];
}
- (void)loadFromPreferencesWithCompletionHandler:(void (^)(NSError *))completion {
    self.loads++;
    [self.callbacks addObject:[completion copy]];
    if (self.loads == self.hangingLoad) {
        return;
    }
    if ([self.failingLoads containsObject:@(self.loads)]) {
        completion(self.failure);
        return;
    }
    self.providerConfiguration = [self.saved copy];
    self.enabled = self.savedEnabled;
    self.localizedDescription = self.savedDescription;
    if (self.afterLoad) {
        self.afterLoad(self);
    }
    completion(nil);
}
- (void)saveToPreferencesWithCompletionHandler:(void (^)(NSError *))completion {
    self.saves++;
    [self.callbacks addObject:[completion copy]];
    if (self.saves == self.hangingSave) {
        return;
    }
    if ([self.failingSaves containsObject:@(self.saves)]) {
        completion(self.failure);
        return;
    }
    self.saved = [self.providerConfiguration copy];
    self.savedEnabled = self.enabled;
    self.savedDescription = self.localizedDescription;
    if ([self.stripOnSaves containsObject:@(self.saves)]) {
        self.saved.bootPolicy = NO;
    }
    if (self.afterSave) {
        self.afterSave(self);
    }
    [self.saveRecords addObject:@{
        @"enabled" : @(self.savedEnabled),
        @"bootPolicy" : @(self.saved.bootPolicy),
        @"fields" : NSFilterConfigurationFields(self.saved)
    }];
    completion([self.errorsAfterWrite containsObject:@(self.saves)] ? self.failure : nil);
}
@end

@interface BootFixture : NSObject
@property(nonatomic, strong) BootManager *manager;
@property(nonatomic, strong) NSFilterRestart *restart;
@property(nonatomic, strong) NSMutableArray *scheduled;
@property(nonatomic, strong) NSMutableArray<NSString *> *stages;
@property(nonatomic) NSTimeInterval clock;
@property(nonatomic) NSUInteger completions;
@property(nonatomic, strong) NSError *result;
@property(nonatomic) BOOL sockets;
@property(nonatomic) BOOL neverStops;
@property(nonatomic) BOOL neverStarts;
@property(nonatomic) BOOL failNewHeartbeat;
@property(nonatomic) BOOL staleHeartbeat;
@property(nonatomic) BOOL staleTime;
@property(nonatomic) BOOL failRestoration;
@property(nonatomic, copy) void (^configureCandidate)(BootConfiguration *, BOOL restoring);
- (void)run;
- (void)drain;
- (void)checkStaleCallbacks;
@end
@implementation BootFixture
- (instancetype)init {
    if ((self = [super init])) {
        _manager = [BootManager new];
        _restart = [NSFilterRestart new];
        _scheduled = [NSMutableArray new];
        _stages = [NSMutableArray new];
        _clock = 100;
        _sockets = YES;
        _restart.manager = _manager;
        _restart.requiresBootPolicy = YES;
        __weak BootFixture *weakSelf = self;
        _restart.configuration = ^id(BootConfiguration *previous, BOOL restoring, NSError **error) {
            BootFixture *test = weakSelf;
            if (restoring && test.failRestoration) {
                return nil;
            }
            BootConfiguration *configuration = restoring ? [previous copy] : BootConfig(@"new", test.sockets);
            NSMutableDictionary *vendor = [configuration.vendorConfiguration mutableCopy];
            vendor[@"activation"] = restoring ? @"restore" : @"new";
            configuration.vendorConfiguration = vendor;
            if (test.configureCandidate) {
                test.configureCandidate(configuration, restoring);
            }
            if (test.restart.requiresBootPolicy && !NSFilterBootPolicyApply(configuration, error)) {
                return nil;
            }
            return configuration;
        };
        _restart.isStopped = ^BOOL(BOOL previouslyEnabled) {
            return !weakSelf.neverStops && !weakSelf.manager.savedEnabled;
        };
        _restart.isRunning = ^BOOL(BootConfiguration *configuration) {
            BootFixture *test = weakSelf;
            NSString *activation = configuration.vendorConfiguration[@"activation"];
            BOOL running = !test.neverStarts && !(test.failNewHeartbeat && [activation isEqual:@"new"]);
            NSDate *now = [NSDate dateWithTimeIntervalSince1970:test.clock];
            NSDictionary *monitor = @{
                @"activation" : test.staleHeartbeat ? @"old" : activation,
                @"updated" : test.staleTime ? [now dateByAddingTimeInterval:-NSMonitorFreshness] : now,
                @"controlRunning" : @(running)
            };
            return test.manager.savedEnabled && NSHasCurrentControlHeartbeat(monitor, activation, now);
        };
        _restart.schedule = ^(NSTimeInterval delay, void (^work)(void)) {
            BootFixture *test = weakSelf;
            [test.scheduled addObject:@{@"at" : @(test.clock + delay), @"work" : [work copy]}];
        };
        _restart.report = ^(NSString *stage, id configuration, BOOL enabled) {
            [weakSelf.stages addObject:stage];
        };
    }
    return self;
}
- (void)run {
    [self.restart start:^(NSError *error) {
        self.completions++;
        self.result = error;
    }];
    [self drain];
    CHECK(self.completions == 1);
}
- (void)drain {
    NSUInteger steps = 0;
    while (self.scheduled.count) {
        CHECK(steps++ < 600);
        [self.scheduled sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"at"] compare:b[@"at"]];
        }];
        NSDictionary *next = self.scheduled.firstObject;
        [self.scheduled removeObjectAtIndex:0];
        self.clock = [next[@"at"] doubleValue];
        void (^work)(void) = next[@"work"];
        work();
    }
}
- (void)checkStaleCallbacks {
    NSUInteger saves = self.manager.saves;
    for (void (^callback)(NSError *) in [self.manager.callbacks copy]) {
        callback(nil);
        callback([NSError errorWithDomain:@"late" code:1 userInfo:nil]);
    }
    [self drain];
    CHECK(self.completions == 1 && self.manager.saves == saves);
}
@end

static void TestBootAdapter(void) {
    CHECK(!NSFilterBootPolicyQualified());
    CHECK(NSFilterBootPolicyExperimentEnabled() == (NS_BOOT_POLICY_EXPERIMENT == 1));
    CHECK(NSFilterBootPolicyRequired() == NSFilterBootPolicyExperimentEnabled());
    for (NSUInteger mode = 0; mode < 9; mode++) {
        BootConfiguration *configuration = BootConfig(@"test", YES);
        configuration.missingGetter = mode == 0;
        configuration.missingSetter = mode == 1;
        configuration.wrongGetterType = mode == 2;
        configuration.wrongSetterType = mode == 3;
        configuration.rejectSetter = mode == 4;
        configuration.throwGetter = mode == 5;
        configuration.throwSetter = mode == 6;
        configuration.loseOnCopy = mode == 7;
        NSError *error = nil;
        BOOL applied = NSFilterBootPolicyApply(configuration, &error);
        CHECK(applied == (mode >= 7));
        CHECK(applied == (error == nil));
        if (mode < 4) {
            CHECK(configuration.writes == 0 && configuration.reads == 0);
            BOOL unknown = YES;
            CHECK(!NSFilterBootPolicyRead(configuration, &unknown, NULL) && unknown);
            CHECK([NSFilterBootPolicyReport(configuration)[@"disableDefaultDrop"] isEqual:@"unknown"]);
        }
        if (applied) {
            error = nil;
            CHECK((NSFilterConfigurationCheckedCopy(configuration, YES, &error) != nil) == (mode == 8));
            CHECK((error == nil) == (mode == 8));
        }
        CHECK(!configuration.vendorConfiguration[@"disableDefaultDrop"]);
    }
    BootConfiguration *configuration = BootConfig(@"original", YES);
    CHECK(NSFilterBootPolicyApply(configuration, NULL));
    NSDictionary *fields = NSFilterConfigurationFields(configuration);
    configuration.vendorConfiguration = BootConfig(@"other-activation", YES).vendorConfiguration;
    CHECK(!NSFilterConfigurationValidate(configuration, fields, YES, NULL));
}

static void TestBootPreflight(void) {
    for (NSUInteger mode = 0; mode < 8; mode++) {
        BootFixture *test = [BootFixture new];
        test.configureCandidate = ^(BootConfiguration *configuration, BOOL restoring) {
            configuration.missingGetter = mode == 0;
            configuration.missingSetter = mode == 1;
            configuration.wrongGetterType = mode == 2;
            configuration.wrongSetterType = mode == 3;
            configuration.rejectSetter = mode == 4;
            configuration.throwGetter = mode == 5;
            configuration.loseOnCopy = mode == 6;
            configuration.changeScopeOnCopy = mode == 7;
        };
        [test run];
        CHECK(test.result && test.manager.saves == 0 && test.manager.savedEnabled);
        CHECK(test.restart.state == NSFilterRestartUnchanged);
        CHECK([test.manager.saved.vendorConfiguration[@"activation"] isEqual:@"old"]);
        [test checkStaleCallbacks];
    }
}

static void TestBootTransactions(void) {
    // Enabled upgrade, fresh enable, disabled installed filter, scope change,
    // and a current-engine configuration missing the actual property.
    for (NSUInteger mode = 0; mode < 5; mode++) {
        BootFixture *test = [BootFixture new];
        if (mode == 1 || mode == 2) {
            test.manager.savedEnabled = NO;
        }
        if (mode == 1) {
            test.manager.saved = nil;
        }
        test.sockets = mode != 3;
        [test run];
        CHECK(!test.result && test.manager.savedEnabled && test.manager.saved.bootPolicy);
        CHECK(test.restart.state == NSFilterRestartEnabledVerified);
        CHECK(test.manager.saved.filterBrowsers && test.manager.saved.filterSockets == test.sockets);
        CHECK([test.stages isEqual:mode == 1 || mode == 2
                                       ? @[ @"candidate-copy-verified", @"staged-off-reloaded-verified",
                                            @"enabled-reloaded-verified", @"current-control-heartbeat" ]
                                       : @[ @"candidate-copy-verified", @"old-off-reloaded",
                                            @"staged-off-reloaded-verified", @"enabled-reloaded-verified",
                                            @"current-control-heartbeat" ]]);
        NSArray *records = test.manager.saveRecords;
        CHECK(records.count == (mode == 1 || mode == 2 ? 2 : 3));
        CHECK(![records[records.count - 2][@"enabled"] boolValue]);
        CHECK([records.lastObject[@"enabled"] boolValue]);
        for (NSDictionary *record in records) {
            CHECK(![record[@"enabled"] boolValue] || [record[@"bootPolicy"] boolValue]);
        }
        [test checkStaleCallbacks];
    }
    // A normal build must preserve a previously saved true property too.
    BootFixture *test = [BootFixture new];
    test.restart.requiresBootPolicy = NO;
    test.manager.saved.bootPolicy = YES;
    [test run];
    CHECK(!test.result && test.restart.requiresBootPolicy && test.manager.saved.bootPolicy);
    // Unqualified normal builds retain legacy operation and an accurate warning.
    BootFixture *legacy = [BootFixture new];
    legacy.restart.requiresBootPolicy = NO;
    [legacy run];
    CHECK(!legacy.result && !legacy.manager.saved.bootPolicy);
    CHECK([NSFilterBootPolicyStatus(legacy.manager.saved, YES) containsString:@"unverified"]);
}

static void TestBootFailureRecovery(void) {
    // Every preference boundary of the enabled migration fails independently.
    for (NSUInteger variant = 0; variant < 2; variant++) {
        BOOL save = variant == 1;
        NSUInteger count = save ? 3 : 5;
        for (NSUInteger operation = 1; operation <= count; operation++) {
            BootFixture *test = [BootFixture new];
            if (save) {
                test.manager.failingSaves = [NSSet setWithObject:@(operation)];
            } else {
                test.manager.failingLoads = [NSSet setWithObject:@(operation)];
            }
            [test run];
            CHECK(test.result);
            if (!save && operation == 1) {
                CHECK(test.manager.saves == 0 && test.restart.state == NSFilterRestartUnchanged);
            } else {
                CHECK(test.restart.state == NSFilterRestartEnabledVerified);
                CHECK(test.manager.savedEnabled && test.manager.saved.bootPolicy);
                CHECK([test.manager.saved.vendorConfiguration[@"activation"] isEqual:@"restore"]);
                CHECK(
                    [test.manager.saved.vendorConfiguration[@"unrelated"] isEqual:@"retain on restoration"]);
                CHECK([test.manager.savedDescription isEqual:@"Old description"]);
            }
            [test checkStaleCallbacks];
        }
    }
    // An error need not mean nothing reached preferences. Recovery must reload
    // rather than trust the in-memory enabled value or assume the write vanished.
    for (NSUInteger save = 1; save <= 3; save++) {
        BootFixture *test = [BootFixture new];
        test.manager.errorsAfterWrite = [NSSet setWithObject:@(save)];
        [test run];
        CHECK(test.result && test.manager.savedEnabled && test.manager.saved.bootPolicy);
        CHECK(test.restart.state == NSFilterRestartEnabledVerified);
        CHECK([test.manager.saved.vendorConfiguration[@"activation"] isEqual:@"restore"]);
    }
    // Failure while starting the new provider can restore only a safely migrated
    // previous configuration; unsafe restoration leaves a freshly verified OFF.
    for (NSUInteger mode = 0; mode < 6; mode++) {
        BootFixture *test = [BootFixture new];
        test.failNewHeartbeat = mode < 3;
        test.neverStops = mode == 3;
        test.staleHeartbeat = mode == 4;
        test.staleTime = mode == 5;
        test.failRestoration = mode == 1;
        if (mode == 2) {
            test.configureCandidate = ^(BootConfiguration *configuration, BOOL restoring) {
                configuration.rejectSetter = restoring;
            };
        }
        [test run];
        CHECK(test.result);
        if (mode == 0) {
            CHECK(test.restart.state == NSFilterRestartEnabledVerified);
            CHECK(test.manager.savedEnabled && test.manager.saved.bootPolicy);
        } else {
            CHECK(test.restart.state == NSFilterRestartOffVerified && !test.manager.savedEnabled);
        }
        [test checkStaleCallbacks];
    }
}

static void TestBootSerializationFailures(void) {
    for (NSUInteger save = 2; save <= 3; save++) {
        BootFixture *test = [BootFixture new];
        test.manager.stripOnSaves = [NSSet setWithObject:@(save)];
        [test run];
        CHECK(test.result && test.manager.savedEnabled && test.manager.saved.bootPolicy);
        CHECK([test.manager.saved.vendorConfiguration[@"activation"] isEqual:@"restore"]);
        // A value stripped during disabled staging must never be enabled.
        if (save == 2) {
            for (NSDictionary *record in test.manager.saveRecords) {
                CHECK(![record[@"enabled"] boolValue] || [record[@"bootPolicy"] boolValue]);
            }
        }
    }
    // Both staging attempts lose the property. There is no enabled rollback.
    BootFixture *test = [BootFixture new];
    test.manager.stripOnSaves = [NSSet setWithArray:@[ @2, @3 ]];
    [test run];
    CHECK(test.result && test.restart.state == NSFilterRestartOffVerified && !test.manager.savedEnabled);
    CHECK(test.manager.saveRecords.count == 3);
    for (NSDictionary *record in test.manager.saveRecords) {
        CHECK(![record[@"enabled"] boolValue]);
    }
    // Successful callbacks with wrong reload contents also fail validation.
    for (NSUInteger mode = 0; mode < 6; mode++) {
        BootFixture *corrupt = [BootFixture new];
        corrupt.manager.afterLoad = ^(BootManager *manager) {
            if (manager.loads != 4) {
                return;
            }
            BootConfiguration *configuration = manager.providerConfiguration;
            if (mode == 0) {
                configuration.bootPolicy = NO;
            } else if (mode == 1) {
                configuration.filterBrowsers = NO;
            } else if (mode == 2) {
                configuration.filterSockets = NO;
            } else if (mode == 3) {
                configuration.vendorConfiguration = BootConfig(@"stale", YES).vendorConfiguration;
            } else if (mode == 4) {
                manager.enabled = YES;
            } else {
                manager.localizedDescription = @"Wrong description";
            }
        };
        [corrupt run];
        CHECK(corrupt.result && corrupt.manager.saved.bootPolicy);
        CHECK([corrupt.manager.saved.vendorConfiguration[@"activation"] isEqual:@"restore"]);
    }
}

static void TestBootCleanupFailures(void) {
    BootFixture *denied = [BootFixture new];
    denied.manager.saved = nil;
    denied.manager.savedEnabled = NO;
    denied.manager.failingSaves = [NSSet setWithObject:@1];
    [denied run];
    CHECK(denied.result && denied.restart.state == NSFilterRestartOffVerified);
    CHECK(!denied.manager.saved && denied.manager.saves == 1);
    // New activation (old state OFF): stage save/load, enable save/load,
    // cleanup load/save/verify failures, plus a lying cleanup save.
    for (NSUInteger mode = 0; mode < 8; mode++) {
        BootFixture *test = [BootFixture new];
        test.manager.savedEnabled = NO;
        test.neverStarts = YES;
        if (mode == 0) {
            test.manager.failingSaves = [NSSet setWithObject:@1];
        } else if (mode == 1) {
            test.manager.failingLoads = [NSSet setWithObject:@3];
        } else if (mode == 2) {
            test.manager.failingSaves = [NSSet setWithObject:@2];
        } else if (mode == 3) {
            test.manager.failingLoads = [NSSet setWithObject:@4];
        } else if (mode == 4) {
            test.manager.failingLoads = [NSSet setWithObject:@5];
        } else if (mode == 5) {
            test.manager.failingSaves = [NSSet setWithObject:@3];
        } else if (mode == 6) {
            test.manager.failingLoads = [NSSet setWithObject:@6];
        } else {
            test.manager.afterSave = ^(BootManager *manager) {
                if (manager.saves == 3) {
                    manager.savedEnabled = YES;
                }
            };
        }
        [test run];
        CHECK(test.result);
        CHECK(test.restart.state == (mode < 4 ? NSFilterRestartOffVerified : NSFilterRestartUnknown));
        if (mode < 4) {
            CHECK(!test.manager.savedEnabled);
        } else {
            CHECK([test.result.localizedDescription containsString:@"unknown/unverified"]);
        }
        [test checkStaleCallbacks];
    }
    // Every restore boundary (load, disable, OFF reload, stage load/save/reload,
    // enable save/reload) also fails to a freshly verified OFF.
    for (NSUInteger mode = 0; mode < 8; mode++) {
        BootFixture *test = [BootFixture new];
        test.failNewHeartbeat = YES;
        if (mode < 3) {
            test.manager.failingSaves = [NSSet setWithObject:@(4 + mode)];
        } else {
            test.manager.failingLoads = [NSSet setWithObject:@(6 + mode - 3)];
        }
        [test run];
        CHECK(test.result && test.restart.state == NSFilterRestartOffVerified && !test.manager.savedEnabled);
    }
}

static void TestBootTimeouts(void) {
    for (NSUInteger variant = 0; variant < 2; variant++) {
        BOOL save = variant == 1;
        BootFixture *test = [BootFixture new];
        if (save) {
            test.manager.hangingSave = 1;
        } else {
            test.manager.hangingLoad = 1;
        }
        [test run];
        CHECK(test.result && test.restart.state == NSFilterRestartUnknown);
        CHECK([test.result.localizedDescription containsString:@"timed out"]);
        CHECK(test.clock <= 110);
        [test checkStaleCallbacks];
    }
    // An old callback while the current enable-reload is still pending must not
    // stage or re-enable anything; its deadline still completes exactly once.
    BootFixture *test = [BootFixture new];
    test.manager.hangingLoad = 5;
    [test.restart start:^(NSError *error) {
        test.completions++;
        test.result = error;
    }];
    CHECK(test.completions == 0);
    NSUInteger saves = test.manager.saves;
    void (^oldCallback)(NSError *) = test.manager.callbacks.firstObject;
    oldCallback(nil);
    CHECK(test.completions == 0 && test.manager.saves == saves);
    [test drain];
    CHECK(test.completions == 1 && test.restart.state == NSFilterRestartUnknown);
    [test checkStaleCallbacks];
}

@interface BootDefaults : NSUserDefaults
@property(nonatomic, strong) id record;
@property(nonatomic) BOOL failWrite;
@end
@implementation BootDefaults
- (NSArray *)arrayForKey:(NSString *)key {
    return self.record;
}
- (void)setObject:(id)value forKey:(NSString *)key {
    if (!self.failWrite) {
        self.record = value;
    }
}
- (BOOL)synchronize {
    return !self.failWrite;
}
@end

static void TestBootMigrationRetries(void) {
    BootDefaults *defaults = [BootDefaults new];
    CHECK(NSFilterBootPolicyClaimMigration(defaults, @"build/sockets-on", NULL));
    // New dashboard/app instance, same persisted target, no retry after failure.
    for (NSUInteger load = 0; load < 5; load++) {
        NSError *error = nil;
        CHECK(!NSFilterBootPolicyClaimMigration(defaults, @"build/sockets-on", &error) && !error);
    }
    CHECK(NSFilterBootPolicyClaimMigration(defaults, @"build/sockets-off", NULL));
    CHECK(!NSFilterBootPolicyClaimMigration(defaults, @"build/sockets-on", NULL));
    BootDefaults *failed = [BootDefaults new];
    failed.failWrite = YES;
    NSError *error = nil;
    CHECK(!NSFilterBootPolicyClaimMigration(failed, @"build", &error) && error);
    CHECK(!failed.record);
    BootDefaults *full = [BootDefaults new];
    for (NSUInteger target = 0; target < 32; target++) {
        CHECK(NSFilterBootPolicyClaimMigration(full, [@(target) stringValue], NULL));
    }
    error = nil;
    CHECK(!NSFilterBootPolicyClaimMigration(full, @"another", &error) && error);
    CHECK(!NSFilterBootPolicyClaimMigration(full, @"0", NULL));
    CHECK([full.record count] == 32);
}

void NSRunBootPolicyTests(void) {
    TestBootAdapter();
    TestBootPreflight();
    TestBootTransactions();
    TestBootFailureRecovery();
    TestBootSerializationFailures();
    TestBootCleanupFailures();
    TestBootTimeouts();
    TestBootMigrationRetries();
    NSLog(
        @"Passed injected boot-policy adapter, transaction, recovery and migration checks (no device proof)");
}
