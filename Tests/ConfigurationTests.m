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
@interface ControlledPreferences : NSObject
@property(nonatomic, strong) NSMutableArray *callbacks;
@property(nonatomic) NSUInteger writes;
@end
@implementation ControlledPreferences
- (instancetype)init {
    if ((self = [super init])) {
        _callbacks = [NSMutableArray new];
    }
    return self;
}
- (void)loadFromPreferencesWithCompletionHandler:(void (^)(NSError *))completion {
    [self.callbacks addObject:[completion copy]];
}
- (void)saveToPreferencesWithCompletionHandler:(void (^)(NSError *))completion {
    self.writes++;
    [self.callbacks addObject:[completion copy]];
}
- (void)removeFromPreferencesWithCompletionHandler:(void (^)(NSError *))completion {
    self.writes++;
    [self.callbacks addObject:[completion copy]];
}
@end
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
    REQUIRE(deliveries == 1 && !NSReadDocument(NSPendingConfigurationFile, NULL));

    NSError *cancelled = [NSError errorWithDomain:@"test.preferences" code:1 userInfo:nil];
    owner.retireDocument = ^BOOL(NSSharedDirectory *directory, NSString *leaf, NSError **error) {
        return ![leaf isEqual:NSPendingConfigurationFile] ||
               NSFileFailure(@"Remove document", leaf, EACCES, error);
    };
    [owner remove:manager
        completion:^(NSError *error) {
            REQUIRE(error == cancelled && owner.acknowledgementError);
            REQUIRE([owner writeErrorWithPreferenceError:error readbackError:nil]
                        .userInfo[@"acknowledgementError"] != nil);
            deliveries++;
        }];
    callback = manager.callbacks.lastObject;
    callback(cancelled);
    REQUIRE(deliveries == 2 &&
            [NSReadDocument(NSPendingConfigurationFile, NULL)[@"state"] isEqual:@"acknowledged"]);
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
    REQUIRE(!NSReadDocument(NSPendingConfigurationFile, NULL));
    [refresh load:manager
        completion:^(NSError *loadError) {
            REQUIRE(!loadError && manager.writes == 2);
            deliveries++;
        }];
    callback = manager.callbacks.lastObject;
    callback(nil);
    [refresh finish];
    REQUIRE(deliveries == 3);

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
    REQUIRE(!NSReadDocument(NSPendingConfigurationFile, NULL) &&
            !NSReadDocument(NSConfigurationRecoveryFile, NULL));
    [refresh finish];
    [manager.callbacks removeAllObjects];
    NSSetTestContainer(original);
    REQUIRE([files removeItemAtURL:alias error:NULL]);
}
void NSRunConfigurationTests(void) {
    TestDurableRecovery();
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
        NSConfigurationCoordinator *other = [NSConfigurationCoordinator new];
        if (kind) {
            REQUIRE(![other begin:NULL]); // timed-out write still owns the real file lock
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
