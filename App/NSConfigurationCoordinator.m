#import "NSConfigurationCoordinator.h"
#import "../Shared/NSStore.h"
#include <errno.h>
#import "../Shared/NSBootSession.h"

@protocol NSConfigurationPreferences <NSObject>
- (void)loadFromPreferencesWithCompletionHandler:(void (^)(NSError *))completion;
- (void)saveToPreferencesWithCompletionHandler:(void (^)(NSError *))completion;
- (void)removeFromPreferencesWithCompletionHandler:(void (^)(NSError *))completion;
@end

@interface NSConfigurationCoordinator ()
@property(nonatomic, strong) NSStoreLock *lock;
@property(nonatomic, copy) NSString *operation;
@property(nonatomic) NSUInteger phase;
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL readOnly;
@property(nonatomic) BOOL pendingWrite;
@property(nonatomic, readwrite) BOOL uncertain;
@property(nonatomic, strong) dispatch_source_t phaseTimer;
@property(nonatomic, strong) dispatch_source_t overallTimer;
@end

static NSString *const NSPendingConfigurationFile = @"configuration-pending.plist";
static NSError *NSConfigurationError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"NetShield2.Configuration"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

@implementation NSConfigurationCoordinator
+ (BOOL)hasUnacknowledgedWrite {
    NSURL *url = NSSharedURL(NSPendingConfigurationFile);
    return url && [NSFileManager.defaultManager fileExistsAtPath:url.path];
}
- (instancetype)init {
    if ((self = [super init])) {
        _durableFence = YES;
        _acquireLock = ^NSStoreLock *(NSError **error) {
            NSURL *url = NSSharedURL(@"configuration.lock");
            return url ? [NSStoreLock tryLockURL:url error:error] : nil;
        };
    }
    return self;
}
- (void)deadline:(NSTimeInterval)delay overall:(BOOL)overall work:(void (^)(void))work {
    if (self.schedule) {
        self.schedule(delay, work);
        return;
    }
    dispatch_source_t timer =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!timer) {
        work();
        return;
    }
    if (overall) {
        self.overallTimer = timer;
    } else {
        self.phaseTimer = timer;
    }
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, NSEC_PER_MSEC * 10);
    dispatch_source_set_event_handler(timer, work);
    dispatch_resume(timer);
}
- (void)cancelPhaseTimer {
    if (self.phaseTimer) {
        dispatch_source_cancel(self.phaseTimer);
    }
    self.phaseTimer = nil;
}
- (BOOL)begin:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Configuration state belongs to the main queue");
    if (self.active || self.pendingWrite) {
        if (error) {
            *error =
                NSConfigurationError(EBUSY, @"A configuration operation or unresolved write is pending.");
        }
        return NO;
    }
    self.lock = self.acquireLock(error);
    if (!self.lock) {
        if (error && !*error) {
            *error = NSConfigurationError(EBUSY, @"Another app/helper configuration operation is pending.");
        }
        return NO;
    }
    // A previous process may have died while the OS still owned a write. Reads
    // and Settings remain available; a read alone cannot prove that write ended.
    if (self.durableFence && [NSConfigurationCoordinator hasUnacknowledgedWrite]) {
        NSDictionary *pending = NSReadDocument(NSPendingConfigurationFile, NULL);
        NSString *boot = NSBootSessionIdentifier();
        if (boot &&
            [[NSUUID alloc] initWithUUIDString:[pending[@"boot"] isKindOfClass:NSString.class]
                                                   ? pending[@"boot"]
                                                   : @""] &&
            ![pending[@"boot"] isEqual:boot]) {
            // An OS operation cannot remain in flight across a kernel reboot.
            // The transaction will still reload actual saved preferences.
            [NSFileManager.defaultManager removeItemAtURL:NSSharedURL(NSPendingConfigurationFile) error:NULL];
        }
    }
    if (self.durableFence && [NSConfigurationCoordinator hasUnacknowledgedWrite]) {
        [self.lock unlock];
        self.lock = nil;
        if (error) {
            *error = NSConfigurationError(
                EBUSY, @"An earlier preference write was not acknowledged. Saved state is unverified. "
                       @"Resolve the filter in Settings and restart the device before further app/helper "
                       @"changes; do not retry automatically.");
        }
        return NO;
    }
    self.readOnly = NO;
    self.operation = NSUUID.UUID.UUIDString;
    self.active = YES;
    self.uncertain = NO;
    NSString *operation = self.operation;
    __weak typeof(self) weakSelf = self;
    [self deadline:90
           overall:YES
              work:^{
                  NSConfigurationCoordinator *owner = weakSelf;
                  if (owner.active && [owner.operation isEqual:operation]) {
                      owner.uncertain = YES;
                      void (^abort)(NSError *) = owner.abort;
                      if (abort) {
                          abort(NSConfigurationError(
                              ETIMEDOUT,
                              @"The overall configuration deadline expired. Saved state is unverified."));
                      }
                  }
              }];
    return self.active;
}
- (void)beginReadOnly {
    NSAssert(NSThread.isMainThread, @"Configuration state belongs to the main queue");
    self.readOnly = YES;
    self.active = YES;
    self.uncertain = NO;
}
- (void)perform:(NSUInteger)kind
        manager:(id<NSConfigurationPreferences>)manager
     completion:(void (^)(NSError *))completion {
    NSAssert(NSThread.isMainThread, @"Configuration state belongs to the main queue");
    if (!self.active || self.pendingWrite || self.uncertain || (kind && self.readOnly)) {
        completion(NSConfigurationError(EBUSY, @"Configuration is busy or an earlier result is unverified."));
        return;
    }
    NSUInteger phase = ++self.phase;
    if (kind) {
        NSError *error = nil;
        if (self.durableFence && !NSWriteDocument(@{
                @"operation" : self.operation,
                @"phase" : @(phase),
                @"boot" : NSBootSessionIdentifier() ?: @""
            },
                                                  NSPendingConfigurationFile, &error)) {
            completion(error);
            return;
        }
        self.pendingWrite = YES;
    }
    __block BOOL acknowledged = NO;
    __weak typeof(self) weakSelf = self;
    [self
        deadline:10
         overall:NO
            work:^{
                NSConfigurationCoordinator *owner = weakSelf;
                if (owner.active && owner.phase == phase && !acknowledged) {
                    owner.phase++;
                    owner.uncertain = YES;
                    [owner cancelPhaseTimer];
                    completion(NSConfigurationError(
                        ETIMEDOUT, kind ? @"Preference write timed out and may still complete. No recovery "
                                          @"write is authorized; saved state is unknown/unverified."
                                        : @"Preference load timed out; saved state is unknown/unverified."));
                }
            }];
    if (!self.active || self.phase != phase) {
        return;
    }
    // The OS callback deliberately retains the owner and its lock while a write
    // remains pending. A late callback reconciles bookkeeping, never starts work.
    void (^callback)(NSError *) = ^(NSError *error) {
        void (^deliver)(void) = ^{
            NSError *result = error;
            if (acknowledged) {
                return;
            }
            acknowledged = YES;
            if (kind) {
                self.pendingWrite = NO;
                if (self.durableFence) {
                    NSError *removeError = nil;
                    NSDictionary *pending = NSReadDocument(NSPendingConfigurationFile, &removeError);
                    if (![pending[@"operation"] isEqual:self.operation] ||
                        ![NSFileManager.defaultManager removeItemAtURL:NSSharedURL(NSPendingConfigurationFile)
                                                                 error:&removeError]) {
                        self.uncertain = YES;
                        result =
                            removeError
                                ?: NSConfigurationError(EBUSY, @"The pending-write fence could not be "
                                                               @"reconciled. Saved state is unverified.");
                    }
                }
            }
            if (!self.active || self.phase != phase) {
                if (!self.active) {
                    [self.lock unlock];
                    self.lock = nil;
                }
                return;
            }
            self.phase++;
            [self cancelPhaseTimer];
            completion(result);
        };
        if (NSThread.isMainThread) {
            deliver();
        } else {
            dispatch_async(dispatch_get_main_queue(), deliver);
        }
    };
    if (kind == 1) {
        [manager saveToPreferencesWithCompletionHandler:callback];
    } else if (kind == 2) {
        [manager removeFromPreferencesWithCompletionHandler:callback];
    } else {
        [manager loadFromPreferencesWithCompletionHandler:callback];
    }
}
- (void)load:(id)manager completion:(void (^)(NSError *))completion {
    [self perform:0 manager:manager completion:completion];
}
- (void)save:(id)manager completion:(void (^)(NSError *))completion {
    [self perform:1 manager:manager completion:completion];
}
- (void)remove:(id)manager completion:(void (^)(NSError *))completion {
    [self perform:2 manager:manager completion:completion];
}
- (void)finish {
    NSAssert(NSThread.isMainThread, @"Configuration state belongs to the main queue");
    self.active = NO;
    self.phase++;
    self.abort = nil;
    [self cancelPhaseTimer];
    if (self.overallTimer) {
        dispatch_source_cancel(self.overallTimer);
    }
    self.overallTimer = nil;
    if (!self.pendingWrite) {
        [self.lock unlock];
        self.lock = nil;
    }
}
@end
