#import <Foundation/Foundation.h>
#import "../Shared/NSStoreLock.h"
#import "../Shared/NSConfigurationRecord.h"

typedef NS_ENUM(NSUInteger, NSConfigurationMarkerState) {
    NSConfigurationMarkerNone,
    NSConfigurationMarkerReserved,
    NSConfigurationMarkerUnresolved,
    NSConfigurationMarkerAcknowledged,
    NSConfigurationMarkerPriorBoot,
    NSConfigurationMarkerInvalid,
    NSConfigurationMarkerUnavailable,
};
typedef NS_ENUM(NSUInteger, NSConfigurationRecoveryAction) {
    NSConfigurationRecoveryNone,
    NSConfigurationRecoveryWaitForWrite,
    NSConfigurationRecoveryRetryRead,
    NSConfigurationRecoveryReopenApp,
    NSConfigurationRecoveryReboot,
    NSConfigurationRecoveryCheckStorageOrSettings,
    NSConfigurationRecoveryRetryEnable,
    NSConfigurationRecoveryProvider,
    NSConfigurationRecoveryConsent,
    NSConfigurationRecoveryExternalChange,
};
FOUNDATION_EXPORT NSNotificationName const NSConfigurationLateAcknowledgement;
FOUNDATION_EXPORT NSString *const NSPreferenceSaveReceiptKey;

// Main-queue transaction owner shared by dashboard, restart and removal helper.
// Lock order: configuration -> provider lifetime -> policy -> activity -> exports.
// Logical reservations span phases; pending records fence uncancellable OS writes.
// The physical lock protects bounded local sections only, never preference APIs
// or asynchronous waits. Callbacks and client completions run after unlock.
@interface NSConfigurationCoordinator : NSObject
@property(nonatomic, copy) void (^schedule)(NSTimeInterval, void (^)(void));
@property(nonatomic, copy) NSStoreLock * (^acquireLock)(NSError **);
@property(nonatomic, copy) NSString * (^bootIdentifier)(void);
@property(nonatomic, copy) BOOL (^retireDocument)(NSSharedDirectory *, NSString *, NSError **);
@property(nonatomic) BOOL durableFence;
// Explicit configuration/removal actions may replace an idle reservation.
// Automatic migration must leave another operation's reservation alone.
@property(nonatomic) BOOL replaceIdleReservation;
@property(nonatomic, copy) void (^abort)(NSError *);
@property(nonatomic, readonly) BOOL uncertain;
@property(nonatomic, readonly) BOOL reconciledMarker;
// A recognized outstanding remove cannot create or enable a profile.
@property(nonatomic, readonly) BOOL pendingRemoval;
@property(nonatomic, readonly) NSConfigurationMarkerState markerState;
@property(nonatomic, readonly) NSError *markerError;
@property(nonatomic, readonly) NSSharedDirectory *directory;
// Snapshot on main, then use on any queue. A superseded token cannot mutate storage.
@property(nonatomic, readonly) NSConfigurationAccess *localAccess;
@property(nonatomic, readonly) NSError *acknowledgementError;
@property(nonatomic, readonly) NSConfigurationRecoveryAction recoveryAction;
// Request a receipt check on preference change or foreground return. A live
// authorization save waits for its callback or the final deadline check.
+ (void)checkPendingSave;
// An in-process owner may still hold the manager after its UI attempt ends.
+ (NSConfigurationRecoveryAction)recoveryForManager:(id)manager;
+ (NSString *)guidanceForRecovery:(NSConfigurationRecoveryAction)action;
- (BOOL)begin:(NSError **)error;
- (BOOL)beginWithAuthorizationBudget:(NSError **)error;
- (NSConfigurationMarkerState)beginReadOnly:(NSError **)error;
- (void)load:(id)manager completion:(void (^)(NSError *))completion;
- (void)save:(id)manager completion:(void (^)(NSError *))completion;
- (void)saveWithAuthorization:(id)manager completion:(void (^)(NSError *))completion;
- (void)remove:(id)manager completion:(void (^)(NSError *))completion;
// Main-queue bounded storage work, after a fresh saved-state read. A deferred
// result must recheck preferences before retrying destructive cleanup.
- (void)performLocalMutation:(BOOL (^)(NSSharedDirectory *, NSError **))work
                  completion:(void (^)(NSError *))completion;
- (void)whenLocalExecutionAvailable:(void (^)(void))work;
- (BOOL)expireIfNeeded;
- (void)finish;
// Keep the OS result and acknowledgement cleanup error independently inspectable.
- (NSError *)writeErrorWithPreferenceError:(NSError *)preferenceError readbackError:(NSError *)readbackError;
@end
