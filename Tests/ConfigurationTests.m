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
void NSRunConfigurationTests(void) {
    for (NSUInteger kind = 0; kind < 3; kind++) {
        NSConfigurationCoordinator *owner = [NSConfigurationCoordinator new];
        NSMutableArray *deadlines = [NSMutableArray new];
        owner.schedule = ^(NSTimeInterval delay, void (^work)(void)) {
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
            [owner save:manager completion:completed];
        } else {
            [owner remove:manager completion:completed];
        }
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
    NSStoreLock *activity = [NSStoreLock tryLockURL:NSSharedURL(@"activity.lock") error:NULL];
    REQUIRE(activity != nil);
    REQUIRE(!NSResetSharedState(NO, NULL));
    REQUIRE([NSReadPolicy(NULL).document[@"default"] isEqual:@"block"]);
    [activity unlock];
}
