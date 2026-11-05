#import "../App/NSConfigurationCoordinator.h"
#import "../Shared/NSStore.h"
#include <errno.h>
#define REQUIRE(value)                                                                                       \
    do {                                                                                                     \
        if (!(value)) {                                                                                      \
            NSLog(@"Configuration regression failed: %s:%d %s", __FILE__, __LINE__, #value);                 \
            abort();                                                                                         \
        }                                                                                                    \
    } while (0)
static void RequirePhysicalConfigurationLockAvailable(void) {
    NSError *error = nil;
    NSStoreLock *lock = [NSStoreLock tryLockRoot:NSSharedURL(@"") leaf:NSConfigurationLockFile error:&error];
    REQUIRE(lock && !error);
    [lock unlock];
}
static BOOL ConfigurationIsReserved(void) {
    NSDictionary *record = NSReadDocument(NSPendingConfigurationFile, NULL);
    return [record[@"version"] isEqual:@3] && [record[@"state"] isEqual:@"reserved"];
}
@interface ReceiptConfiguration : NSObject
@property(nonatomic, copy) NSDictionary *vendorConfiguration;
@end
@implementation ReceiptConfiguration
@end

@interface ControlledPreferences : NSObject
@property(nonatomic, strong) NSMutableArray *callbacks;
@property(nonatomic) NSUInteger writes;
@property(nonatomic, strong) ReceiptConfiguration *providerConfiguration;
@end
@implementation ControlledPreferences
- (instancetype)init {
    if ((self = [super init])) {
        _callbacks = [NSMutableArray new];
    }
    return self;
}
- (void)loadFromPreferencesWithCompletionHandler:(void (^)(NSError *))completion {
    RequirePhysicalConfigurationLockAvailable();
    [self.callbacks addObject:[completion copy]];
}
- (void)saveToPreferencesWithCompletionHandler:(void (^)(NSError *))completion {
    self.writes++;
    RequirePhysicalConfigurationLockAvailable();
    [self.callbacks addObject:[completion copy]];
}
- (void)removeFromPreferencesWithCompletionHandler:(void (^)(NSError *))completion {
    self.writes++;
    RequirePhysicalConfigurationLockAvailable();
    [self.callbacks addObject:[completion copy]];
}
@end
static void TestCommittedSaveReceipt(void) {
    NSConfigurationCoordinator *owner = [NSConfigurationCoordinator new];
    ControlledPreferences *manager = [ControlledPreferences new];
    manager.providerConfiguration = [ReceiptConfiguration new];
    NSDictionary *original = @{@"activation" : @"initial"};
    manager.providerConfiguration.vendorConfiguration = original;
    REQUIRE([owner begin:NULL]);
    __block NSUInteger deliveries = 0;
    void (^complete)(NSError *) = ^(NSError *error) {
        REQUIRE(!error);
        deliveries++;
    };
    [owner save:manager completion:complete];
    void (^firstSaveCallback)(NSError *) = manager.callbacks.lastObject;
    NSDictionary *record = NSReadDocument(NSPendingConfigurationFile, NULL);
    NSDictionary *committed = manager.providerConfiguration.vendorConfiguration;
    REQUIRE([record[@"version"] isEqual:@3] &&
            [committed[NSPreferenceSaveReceiptKey] isEqual:record[@"receipt"]]);

    // The manager's editable candidate already has the token. A read that
    // returns the old persisted configuration cannot use it as proof.
    [NSConfigurationCoordinator checkPendingSave];
    void (^probe)(NSError *) = manager.callbacks.lastObject;
    REQUIRE(manager.callbacks.count == 2);
    [NSConfigurationCoordinator checkPendingSave];
    REQUIRE(manager.callbacks.count == 2);
    manager.providerConfiguration.vendorConfiguration = original;
    probe(nil);
    REQUIRE(deliveries == 0 && [NSReadDocument(NSPendingConfigurationFile, NULL) isEqual:record]);
    NSConfigurationCoordinator *competing = [NSConfigurationCoordinator new];
    REQUIRE([competing begin:NULL]); // read admission cannot dispatch another write
    [competing remove:[ControlledPreferences new]
           completion:^(NSError *error) {
               REQUIRE(error);
           }];
    [competing finish];

    [NSConfigurationCoordinator checkPendingSave];
    probe = manager.callbacks.lastObject;
    manager.providerConfiguration.vendorConfiguration = committed;
    probe(nil);
    probe(nil);
    REQUIRE(deliveries == 1 && ConfigurationIsReserved());

    // A distinct token for the activation save prevents the staging receipt
    // and a delayed staging callback from settling activation.
    [owner save:manager completion:complete];
    NSDictionary *second = NSReadDocument(NSPendingConfigurationFile, NULL);
    REQUIRE(second && ![second[@"receipt"] isEqual:record[@"receipt"]]);
    firstSaveCallback(nil);
    REQUIRE(deliveries == 1 && [NSReadDocument(NSPendingConfigurationFile, NULL) isEqual:second]);
    void (^secondSaveCallback)(NSError *) = manager.callbacks.lastObject;
    [NSConfigurationCoordinator checkPendingSave];
    probe = manager.callbacks.lastObject;
    secondSaveCallback(nil);
    REQUIRE(deliveries == 1 && ConfigurationIsReserved());
    probe(nil);
    REQUIRE(deliveries == 2);
    [owner finish];
    [manager.callbacks removeAllObjects];

    // A relaunched app or helper must load preferences before it can clear a
    // receipt record. A matching committed receipt works on the same boot.
    NSString *boot = NSUUID.UUID.UUIDString;
    NSMutableDictionary *orphan = [second mutableCopy];
    orphan[@"version"] = @2; // Preserve recovery of the deployed receipt format.
    orphan[@"boot"] = boot;
    orphan[@"bootState"] = @"known";
    REQUIRE(NSWriteDocument(orphan, NSPendingConfigurationFile, NULL));
    owner.bootIdentifier = ^{
        return boot;
    };
    REQUIRE([owner beginReadOnly:NULL] == NSConfigurationMarkerUnresolved);
    [owner load:manager
        completion:^(NSError *error) {
            REQUIRE(!error && owner.markerState == NSConfigurationMarkerUnresolved);
        }];
    manager.providerConfiguration.vendorConfiguration = committed; // token from the first save
    void (^readCallback)(NSError *) = manager.callbacks.lastObject;
    readCallback(nil);
    [owner finish];

    REQUIRE([owner begin:NULL]); // admission to read only until receipt proof
    [owner remove:manager
        completion:^(NSError *error) {
            REQUIRE(error && manager.writes == 2);
        }];
    [owner load:manager
        completion:^(NSError *error) {
            REQUIRE(!error && owner.reconciledMarker && owner.markerState == NSConfigurationMarkerNone);
        }];
    manager.providerConfiguration.vendorConfiguration = @{NSPreferenceSaveReceiptKey : second[@"receipt"]};
    readCallback = manager.callbacks.lastObject;
    readCallback(nil);
    [owner remove:manager completion:complete];
    void (^removeCallback)(NSError *) = manager.callbacks.lastObject;
    removeCallback(nil);
    REQUIRE(deliveries == 3 && manager.writes == 3 && ConfigurationIsReserved());
    [owner finish];
    [manager.callbacks removeAllObjects];
}

static void TestLateSaveReceipt(void) {
    NSConfigurationCoordinator *owner = [NSConfigurationCoordinator new];
    ControlledPreferences *manager = [ControlledPreferences new];
    manager.providerConfiguration = [ReceiptConfiguration new];
    NSMutableArray *deadlines = [NSMutableArray new];
    owner.schedule = ^(NSTimeInterval delay, void (^work)(void)) {
        [deadlines addObject:[work copy]];
    };
    REQUIRE([owner begin:NULL]);
    __block NSUInteger deliveries = 0;
    [owner save:manager
        completion:^(NSError *error) {
            REQUIRE(error.code == ETIMEDOUT);
            deliveries++;
            [owner finish];
        }];
    void (^timeout)(void) = deadlines.lastObject;
    timeout(); // starts the one final receipt read
    REQUIRE(deliveries == 0 && manager.callbacks.count == 2);
    void (^readbackTimeout)(void) = deadlines.lastObject;
    readbackTimeout();
    REQUIRE(deliveries == 1 && owner.uncertain && NSReadDocument(NSPendingConfigurationFile, NULL));
    void (^probe)(NSError *) = manager.callbacks.lastObject;
    probe(nil); // fake NE has returned the persisted token from the submitted configuration
    REQUIRE(deliveries == 1 && manager.writes == 1 && !NSReadDocument(NSPendingConfigurationFile, NULL));
    NSConfigurationCoordinator *another = [NSConfigurationCoordinator new];
    REQUIRE([another begin:NULL]);
    [another finish];
    [manager.callbacks removeAllObjects];
    [deadlines removeAllObjects];
}

static void TestAcknowledgedSaveWithLostProbe(void) {
    NSConfigurationCoordinator *owner = [NSConfigurationCoordinator new];
    ControlledPreferences *manager = [ControlledPreferences new];
    manager.providerConfiguration = [ReceiptConfiguration new];
    NSMutableArray *deadlines = [NSMutableArray new];
    __block NSTimeInterval lastDelay = 0;
    owner.schedule = ^(NSTimeInterval delay, void (^work)(void)) {
        lastDelay = delay;
        [deadlines addObject:[work copy]];
    };
    REQUIRE([owner begin:NULL]);
    __block NSUInteger deliveries = 0;
    [owner saveWithAuthorization:manager
                      completion:^(NSError *error) {
                          REQUIRE(error.code == ETIMEDOUT &&
                                  owner.recoveryAction == NSConfigurationRecoveryReopenApp);
                          deliveries++;
                          [owner finish];
                      }];
    void (^saveCallback)(NSError *) = manager.callbacks.lastObject;
    [NSConfigurationCoordinator checkPendingSave];
    REQUIRE(manager.callbacks.count == 1 && lastDelay == 60);
    void (^authorizationTimeout)(void) = deadlines.lastObject;
    authorizationTimeout(); // Starts the final receipt read after the authorization wait.
    REQUIRE(manager.callbacks.count == 2 && lastDelay == 10);
    void (^lateRead)(NSError *) = manager.callbacks.lastObject;
    saveCallback(nil);
    REQUIRE(deliveries == 0 && ConfigurationIsReserved());
    void (^probeTimeout)(void) = deadlines.lastObject;
    probeTimeout();
    probeTimeout();
    REQUIRE(deliveries == 1);

    // Every wait leaves the physical lock free; a completed write can release
    // its logical reservation. This process must still
    // keep other reads/writes off the manager until the outstanding read drains.
    NSConfigurationCoordinator *refresh = [NSConfigurationCoordinator new];
    REQUIRE([refresh beginReadOnly:NULL] == NSConfigurationMarkerNone);
    [refresh load:manager
        completion:^(NSError *error) {
            REQUIRE(error.code == EBUSY);
        }];
    [refresh finish];
    REQUIRE(manager.callbacks.count == 2);
    lateRead(nil);
    lateRead(nil);
    saveCallback(nil);
    REQUIRE(deliveries == 1 &&
            [NSConfigurationCoordinator recoveryForManager:manager] == NSConfigurationRecoveryNone);
    REQUIRE([refresh beginReadOnly:NULL] == NSConfigurationMarkerNone);
    [refresh load:manager
        completion:^(NSError *error) {
            REQUIRE(!error);
        }];
    REQUIRE(manager.callbacks.count == 3);
    void (^freshRead)(NSError *) = manager.callbacks.lastObject;
    freshRead(nil);
    [refresh finish];
    [manager.callbacks removeAllObjects];
}

static void TestDurableRecovery(void) {
    NSURL *original = NSSharedURL(@"");
    NSURL *alias =
        [NSURL fileURLWithPath:[@"/private/var/tmp" stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                   isDirectory:YES];
    REQUIRE([alias.path hasPrefix:@"/private/var/"]);
    NSFileManager *files = NSFileManager.defaultManager;
    REQUIRE([files createDirectoryAtURL:alias withIntermediateDirectories:NO attributes:nil error:NULL]);
    NSSetTestContainer(alias);

    NSConfigurationCoordinator *owner = [NSConfigurationCoordinator new];
    owner.bootIdentifier = ^{
        return (NSString *)nil;
    };
    ControlledPreferences *manager = [ControlledPreferences new];
    REQUIRE([owner begin:NULL]);
    __block NSUInteger deliveries = 0;
    [owner save:manager
        completion:^(NSError *error) {
            REQUIRE(!error && !owner.acknowledgementError);
            deliveries++;
        }];
    REQUIRE([NSReadDocument(NSPendingConfigurationFile, NULL)[@"bootState"] isEqual:@"unavailable"]);
    void (^callback)(NSError *) = manager.callbacks.lastObject;
    callback(nil);
    callback(nil);
    REQUIRE(deliveries == 1 && ConfigurationIsReserved());

    NSError *cancelled = [NSError errorWithDomain:@"test.preferences" code:1 userInfo:nil];
    owner.retireDocument = ^BOOL(NSSharedDirectory *directory, NSString *leaf, NSError **error) {
        return ![leaf isEqual:NSPendingConfigurationFile] ||
               NSFileFailure(@"Remove document", leaf, EACCES, error);
    };
    __block BOOL denyAcknowledgement = NO;
    owner.acquireLock = ^NSStoreLock *(NSError **error) {
        if (denyAcknowledgement) {
            NSFileFailure(@"Acquire lock", NSConfigurationLockFile, EACCES, error);
            return nil;
        }
        return [NSStoreLock tryLockRoot:NSSharedURL(@"") leaf:NSConfigurationLockFile error:error];
    };
    [owner remove:manager
        completion:^(NSError *error) {
            REQUIRE(error == cancelled && owner.acknowledgementError);
            REQUIRE([owner writeErrorWithPreferenceError:error readbackError:nil]
                        .userInfo[@"acknowledgementError"] != nil);
            deliveries++;
        }];
    callback = manager.callbacks.lastObject;
    denyAcknowledgement = YES;
    callback(cancelled);
    denyAcknowledgement = NO;
    REQUIRE(deliveries == 2 &&
            [NSReadDocument(NSPendingConfigurationFile, NULL)[@"state"] isEqual:@"pending"]);
    [owner finish];
    [manager.callbacks removeAllObjects];
    NSConfigurationCoordinator *refresh = [NSConfigurationCoordinator new];
    refresh.retireDocument = owner.retireDocument;
    NSError *error = nil;
    REQUIRE([refresh beginReadOnly:&error] == NSConfigurationMarkerAcknowledged && error.code == EACCES);
    [refresh finish];
    refresh = [NSConfigurationCoordinator new];
    REQUIRE([refresh beginReadOnly:NULL] == NSConfigurationMarkerNone && refresh.reconciledMarker);
    [refresh finish];

    __block NSString *boot = NSUUID.UUID.UUIDString;
    NSString *operation = NSUUID.UUID.UUIDString;
    refresh.bootIdentifier = ^{
        return boot;
    };
    REQUIRE(NSWriteDocument(
        @{@"operation" : operation,
          @"phase" : @1,
          @"boot" : boot.lowercaseString},
        NSPendingConfigurationFile, NULL));
    REQUIRE([refresh beginReadOnly:NULL] == NSConfigurationMarkerUnresolved);
    [refresh finish];
    REQUIRE(![refresh begin:NULL] && NSReadDocument(NSPendingConfigurationFile, NULL));
    boot = NSUUID.UUID.UUIDString;
    REQUIRE([refresh beginReadOnly:NULL] == NSConfigurationMarkerNone && refresh.reconciledMarker);
    REQUIRE(ConfigurationIsReserved());
    [refresh load:manager
        completion:^(NSError *loadError) {
            REQUIRE(!loadError && manager.writes == 2);
            deliveries++;
        }];
    callback = manager.callbacks.lastObject;
    callback(nil);
    [refresh finish];
    REQUIRE(deliveries == 3);

    // 2.6.4 cleanup can leave a 2.6.6 marker with no policy document.
    // A remove is distinguishable from a save even when both still fence NE.
    for (NSString *kind in @[ @"save", @"remove" ]) {
        REQUIRE(NSWriteDocument(
            @{
                @"version" : @1,
                @"operation" : operation,
                @"phase" : @2,
                @"boot" : boot,
                @"bootState" : @"known",
                @"kind" : kind,
                @"state" : @"pending"
            },
            NSPendingConfigurationFile, NULL));
        REQUIRE([refresh beginReadOnly:NULL] == NSConfigurationMarkerUnresolved);
        REQUIRE(refresh.pendingRemoval == [kind isEqual:@"remove"]);
        REQUIRE(!NSReadPolicy(NULL));
        [refresh finish];
        REQUIRE(![refresh begin:NULL]);
    }
    boot = NSUUID.UUID.UUIDString;
    REQUIRE([refresh beginReadOnly:NULL] == NSConfigurationMarkerNone && refresh.reconciledMarker);
    REQUIRE([refresh.localAccess
                perform:^BOOL(NSSharedDirectory *directory, NSError **error) {
                    return NSEnsurePolicyIn(directory, error);
                }
                  error:NULL] &&
            NSReadPolicy(NULL));
    [refresh finish];

    NSDictionary *bootless = @{@"operation" : operation, @"phase" : @2, @"boot" : @""};
    REQUIRE(NSWriteDocument(bootless, NSPendingConfigurationFile, NULL));
    for (NSUInteger attempt = 0; attempt < 2; attempt++) {
        REQUIRE([refresh beginReadOnly:NULL] == NSConfigurationMarkerInvalid);
        REQUIRE([NSReadDocument(NSPendingConfigurationFile, NULL) isEqual:bootless]);
        REQUIRE([NSReadDocument(NSConfigurationRecoveryFile, NULL)[@"boot"] isEqual:boot]);
        [refresh finish];
    }
    boot = NSUUID.UUID.UUIDString;
    // A witness to the old phase cannot retire a different marker after reboot.
    REQUIRE(NSWriteDocument(
        @{@"operation" : operation,
          @"phase" : @3,
          @"boot" : @""},
        NSPendingConfigurationFile, NULL));
    REQUIRE([refresh beginReadOnly:NULL] == NSConfigurationMarkerInvalid);
    [refresh finish];
    boot = NSUUID.UUID.UUIDString;
    REQUIRE([refresh beginReadOnly:NULL] == NSConfigurationMarkerNone && refresh.reconciledMarker);
    REQUIRE(ConfigurationIsReserved() && !NSReadDocument(NSConfigurationRecoveryFile, NULL));
    [refresh finish];
    [manager.callbacks removeAllObjects];
    NSSetTestContainer(original);
    REQUIRE([files removeItemAtURL:alias error:NULL]);
}
// Reuse the controlled preference lane to exercise cross-process-style record
// replacement and app-only execution gating without linking UIKit into tests.
@interface ConfigurationExecutionFixture : NSObject <NSConfigurationExecution>
@property(atomic) BOOL valid;
@property(nonatomic, copy) void (^ended)(void);
@end
@implementation ConfigurationExecutionFixture
- (void)finish {
    RequirePhysicalConfigurationLockAvailable();
    self.valid = NO;
    if (self.ended) {
        self.ended();
    }
}
@end

static void TestReservationTransitions(void) {
    NSConfigurationCoordinator *old = [NSConfigurationCoordinator new];
    ControlledPreferences *manager = [ControlledPreferences new];
    REQUIRE([old begin:NULL]);
    NSConfigurationAccess *queuedBootstrap = old.localAccess;
    __block NSUInteger completions = 0;
    [old load:manager
        completion:^(NSError *error) {
            REQUIRE(error.code == ESTALE && old.uncertain);
            completions++;
        }];
    RequirePhysicalConfigurationLockAvailable();
    NSConfigurationCoordinator *automatic = [NSConfigurationCoordinator new];
    automatic.replaceIdleReservation = NO;
    REQUIRE(![automatic begin:NULL]);
    NSConfigurationCoordinator *replacement = [NSConfigurationCoordinator new];
    REQUIRE([replacement begin:NULL]); // Explicit action may replace a no-write reservation.
    NSDictionary *newRecord = NSReadDocument(NSPendingConfigurationFile, NULL);
    NSConfigurationCoordinator *passive = [NSConfigurationCoordinator new];
    REQUIRE([passive beginReadOnly:NULL] == NSConfigurationMarkerReserved && !passive.localAccess);
    [passive finish];
    REQUIRE([newRecord isEqual:NSReadDocument(NSPendingConfigurationFile, NULL)]);
    __block BOOL mutated = NO;
    REQUIRE(![queuedBootstrap
                perform:^BOOL(NSSharedDirectory *directory, NSError **error) {
                    mutated = YES;
                    return NSEnsurePolicyIn(directory, error);
                }
                  error:NULL] &&
            !mutated);
    REQUIRE(!NSWriteNotificationRetryRevision(NULL)); // Raw writers honor the logical owner.
    void (^loaded)(NSError *) = manager.callbacks.lastObject;
    loaded(nil);
    loaded(nil);
    REQUIRE(completions == 1 && manager.writes == 0);
    [old finish];
    REQUIRE([newRecord isEqual:NSReadDocument(NSPendingConfigurationFile, NULL)]);
    REQUIRE(![queuedBootstrap
                perform:^BOOL(NSSharedDirectory *directory, NSError **error) {
                    mutated = YES;
                    return NSRemoveSharedStateIn(directory, error);
                }
                  error:NULL] &&
            !mutated);
    [replacement finish];
    REQUIRE(!NSReadDocument(NSPendingConfigurationFile, NULL));
    [manager.callbacks removeAllObjects];
    NSMutableDictionary *unsupported = [newRecord mutableCopy];
    unsupported[@"version"] = @4;
    REQUIRE(NSWriteDocument(unsupported, NSPendingConfigurationFile, NULL));
    REQUIRE([passive beginReadOnly:NULL] == NSConfigurationMarkerInvalid);
    [passive finish];
    REQUIRE(![replacement begin:NULL] && !NSWriteNotificationRetryRevision(NULL));
    REQUIRE(NSWriteDocument(newRecord, NSPendingConfigurationFile, NULL));
    REQUIRE([replacement begin:NULL]);
    [replacement finish];

    for (NSNumber *supersede in @[ @NO, @YES ]) {
        NSConfigurationCoordinator *writer = [NSConfigurationCoordinator new];
        ControlledPreferences *saving = [ControlledPreferences new];
        saving.providerConfiguration = [ReceiptConfiguration new];
        REQUIRE([writer begin:NULL]);
        __block NSUInteger delivered = 0;
        [writer save:saving
            completion:^(NSError *error) {
                REQUIRE(!error && (writer.acknowledgementError != nil) == supersede.boolValue);
                REQUIRE(writer.uncertain == supersede.boolValue);
                delivered++;
            }];
        NSDictionary *pending = NSReadDocument(NSPendingConfigurationFile, NULL);
        REQUIRE([replacement begin:NULL] && !replacement.localAccess);
        [replacement remove:[ControlledPreferences new]
                 completion:^(NSError *error) {
                     REQUIRE(error);
                 }];
        [replacement finish];
        REQUIRE([pending isEqual:NSReadDocument(NSPendingConfigurationFile, NULL)]);
        // A different manager/process proves the receipt before the callback.
        ControlledPreferences *reading = [ControlledPreferences new];
        reading.providerConfiguration = [ReceiptConfiguration new];
        reading.providerConfiguration.vendorConfiguration = saving.providerConfiguration.vendorConfiguration;
        REQUIRE([passive beginReadOnly:NULL] == NSConfigurationMarkerUnresolved);
        [passive load:reading
            completion:^(NSError *error) {
                REQUIRE(!error && passive.markerState == NSConfigurationMarkerReserved);
            }];
        loaded = reading.callbacks.lastObject;
        loaded(nil);
        [passive finish];
        REQUIRE(ConfigurationIsReserved());
        if (supersede.boolValue) {
            REQUIRE([replacement begin:NULL]);
        }
        NSDictionary *settled = NSReadDocument(NSPendingConfigurationFile, NULL);
        void (^saved)(NSError *) = saving.callbacks.lastObject;
        saved(nil);
        saved(nil);
        REQUIRE(delivered == 1 && [settled isEqual:NSReadDocument(NSPendingConfigurationFile, NULL)]);
        [writer finish];
        if (supersede.boolValue) {
            REQUIRE([settled isEqual:NSReadDocument(NSPendingConfigurationFile, NULL)]);
            [replacement finish];
        }
        REQUIRE(!NSReadDocument(NSPendingConfigurationFile, NULL));
        [saving.callbacks removeAllObjects];
        [reading.callbacks removeAllObjects];
    }
}
static void TestLocalExecutionBudget(void) {
    __block BOOL allowed = YES;
    __block NSUInteger began = 0, ended = 0;
    __block ConfigurationExecutionFixture *latest = nil;
    __block void (^onEnd)(void) = nil;
    NSSetConfigurationExecutionFactory(^id<NSConfigurationExecution> {
        ConfigurationExecutionFixture *execution = [ConfigurationExecutionFixture new];
        execution.valid = allowed;
        execution.ended = ^{
            ended++;
            if (onEnd) {
                onEnd();
            }
        };
        latest = execution;
        began++;
        return execution;
    });
    NSConfigurationCoordinator *owner = [NSConfigurationCoordinator new];
    ControlledPreferences *manager = [ControlledPreferences new];
    manager.providerConfiguration = [ReceiptConfiguration new];
    REQUIRE([owner begin:NULL]);
    __block NSUInteger deliveries = 0;
    allowed = NO;
    [owner saveWithAuthorization:manager
                      completion:^(NSError *error) {
                          REQUIRE(!error && !owner.acknowledgementError);
                          deliveries++;
                      }];
    REQUIRE(manager.writes == 0 && ConfigurationIsReserved());
    RequirePhysicalConfigurationLockAvailable();
    allowed = YES;
    [NSConfigurationCoordinator checkPendingSave];
    REQUIRE(manager.writes == 1 && deliveries == 0);
    NSDictionary *pending = NSReadDocument(NSPendingConfigurationFile, NULL);
    allowed = NO;
    void (^saved)(NSError *) = manager.callbacks.lastObject;
    saved(nil); // OS result waits for safe local acknowledgement; no second save.
    REQUIRE(deliveries == 0 && [pending isEqual:NSReadDocument(NSPendingConfigurationFile, NULL)]);
    RequirePhysicalConfigurationLockAvailable();
    allowed = YES;
    [NSConfigurationCoordinator checkPendingSave];
    saved(nil);
    REQUIRE(deliveries == 1 && manager.writes == 1 && ConfigurationIsReserved());
    [owner finish];
    [manager.callbacks removeAllObjects];

    // Cancellation after verified preparation but before API dispatch may
    // retire only that known-unsubmitted record, without leaving a recovery trap.
    NSConfigurationCoordinator *cancelled = [NSConfigurationCoordinator new];
    ControlledPreferences *unsubmitted = [ControlledPreferences new];
    unsubmitted.providerConfiguration = [ReceiptConfiguration new];
    REQUIRE([cancelled begin:NULL]);
    __block BOOL cancelBeforeDispatch = YES;
    onEnd = ^{
        if (cancelBeforeDispatch &&
            [NSReadDocument(NSPendingConfigurationFile, NULL)[@"state"] isEqual:@"pending"]) {
            cancelBeforeDispatch = NO;
            [cancelled finish];
        }
    };
    [cancelled save:unsubmitted
         completion:^(NSError *error) {
             REQUIRE(NO);
         }];
    onEnd = nil;
    REQUIRE(!cancelBeforeDispatch && !unsubmitted.writes &&
            !NSReadDocument(NSPendingConfigurationFile, NULL));

    // A refused preparation that genuinely expires cannot replay on foreground.
    NSMutableArray *deadlines = [NSMutableArray new];
    cancelled.schedule = ^(NSTimeInterval delay, void (^work)(void)) {
        [deadlines addObject:[work copy]];
    };
    REQUIRE([cancelled begin:NULL]);
    NSConfigurationAccess *expiredAccess = cancelled.localAccess;
    allowed = NO;
    [cancelled saveWithAuthorization:unsubmitted
                          completion:^(NSError *error) {
                              REQUIRE(error.code == ETIMEDOUT);
                              deliveries++;
                              [cancelled finish];
                          }];
    void (^timeout)(void) = deadlines.lastObject;
    timeout();
    allowed = YES;
    [NSConfigurationCoordinator checkPendingSave];
    REQUIRE(deliveries == 2 && !unsubmitted.writes);
    __block BOOL staleWorkRan = NO;
    REQUIRE(![expiredAccess
                perform:^BOOL(NSSharedDirectory *directory, NSError **error) {
                    staleWorkRan = YES;
                    return YES;
                }
                  error:NULL] &&
            !staleWorkRan);
    REQUIRE([cancelled begin:NULL]); // Abandoned idle ownership needs no reboot.
    [cancelled finish];
    REQUIRE(!NSReadDocument(NSPendingConfigurationFile, NULL));
    [deadlines removeAllObjects];
    cancelled.schedule = nil;

    // Expiration between acquisition and admission must release the descriptor
    // and finish the protection token without entering the mutation body.
    __block BOOL ran = NO;
    NSError *error = nil;
    REQUIRE(!NSConfigurationSection(
        ^NSStoreLock *(NSError **lockError) {
            NSStoreLock *lock = [NSStoreLock tryLockRoot:NSSharedURL(@"")
                                                    leaf:NSConfigurationLockFile
                                                   error:lockError];
            latest.valid = NO;
            return lock;
        },
        ^BOOL(NSSharedDirectory *directory, NSError **localError) {
            ran = YES;
            return YES;
        },
        &error));
    REQUIRE(!ran && NSConfigurationExecutionDeferred(error) && began == ended);
    NSSetConfigurationExecutionFactory(nil);
    RequirePhysicalConfigurationLockAvailable();
}
void NSRunConfigurationTests(void) {
    TestReservationTransitions();
    TestLocalExecutionBudget();
    TestDurableRecovery();
    TestCommittedSaveReceipt();
    TestLateSaveReceipt();
    TestAcknowledgedSaveWithLostProbe();
    for (NSUInteger kind = 0; kind < 3; kind++) {
        NSConfigurationCoordinator *owner = [NSConfigurationCoordinator new];
        NSMutableArray *deadlines = [NSMutableArray new];
        __block NSTimeInterval budget = 0;
        owner.schedule = ^(NSTimeInterval delay, void (^work)(void)) {
            budget = delay;
            [deadlines addObject:[work copy]];
        };
        ControlledPreferences *manager = [ControlledPreferences new];
        REQUIRE([owner begin:NULL]);
        __block NSUInteger calls = 0;
        void (^completed)(NSError *) = ^(NSError *error) {
            REQUIRE(NSThread.isMainThread);
            calls++;
            REQUIRE(error.code == ETIMEDOUT);
            [owner finish];
        };
        if (kind == 0) {
            [owner load:manager completion:completed];
        } else if (kind == 1) {
            [owner saveWithAuthorization:manager completion:completed];
        } else {
            [owner remove:manager completion:completed];
        }
        REQUIRE(budget == (kind == 1 ? 60 : 10));
        void (^timeout)(void) = deadlines.lastObject;
        timeout();
        timeout();
        REQUIRE(calls == 1 && owner.uncertain);
        RequirePhysicalConfigurationLockAvailable();
        NSConfigurationCoordinator *other = [NSConfigurationCoordinator new];
        if (kind) {
            REQUIRE(![other begin:NULL]); // durable pending evidence fences writes without a physical lock
        } else {
            REQUIRE([other begin:NULL]);
            [other finish];
        }
        void (^late)(NSError *) = manager.callbacks.firstObject;
        late(nil);
        late(nil);
        REQUIRE(calls == 1 && manager.writes == (kind ? 1 : 0));
        REQUIRE([other begin:NULL]);
        [other finish];
        [deadlines removeAllObjects];
        owner.schedule = nil;
        [manager.callbacks removeAllObjects];
    }
    // Synchronous and duplicate callbacks advance the phase only once.
    NSConfigurationCoordinator *owner = [NSConfigurationCoordinator new];
    ControlledPreferences *manager = [ControlledPreferences new];
    REQUIRE([owner begin:NULL]);
    __block NSUInteger calls = 0;
    [owner load:manager
        completion:^(NSError *error) {
            REQUIRE(!error);
            calls++;
            [owner finish];
        }];
    void (^callback)(NSError *) = manager.callbacks.firstObject;
    callback(nil);
    callback(nil);
    REQUIRE(calls == 1);
    // Inject delivery off-main and service the main queue; the result remains exactly once.
    owner = [NSConfigurationCoordinator new];
    manager = [ControlledPreferences new];
    REQUIRE([owner begin:NULL]);
    NSConfigurationCoordinator *backgroundOwner = owner;
    __block BOOL backgroundDone = NO;
    [owner load:manager
        completion:^(NSError *error) {
            REQUIRE(!error && NSThread.isMainThread && !backgroundDone);
            backgroundDone = YES;
            [backgroundOwner finish];
        }];
    callback = manager.callbacks.firstObject;
    dispatch_semaphore_t sent = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        REQUIRE(!NSThread.isMainThread);
        callback(nil);
        callback(nil);
        dispatch_semaphore_signal(sent);
    });
    REQUIRE(dispatch_semaphore_wait(sent, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!backgroundDone && [limit timeIntervalSinceNow] > 0) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:limit];
    }
    REQUIRE(backgroundDone);
    // Reset must not replace policy before acquiring the activity lock.
    NSMutableDictionary *document = [[NSPolicy defaultDocument] mutableCopy];
    document[@"default"] = @"block";
    REQUIRE(NSWriteDocument(document, NSPolicyFile, NULL));
    NSStoreLock *activity = [NSStoreLock tryLockRoot:NSSharedURL(@"") leaf:@"activity.lock" error:NULL];
    REQUIRE(activity != nil);
    REQUIRE(!NSResetSharedState(NO, NULL));
    REQUIRE([NSReadPolicy(NULL).document[@"default"] isEqual:@"block"]);
    [activity unlock];
}
