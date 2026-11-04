#import <Foundation/Foundation.h>
#import "../Shared/NSStoreLock.h"

typedef NS_ENUM(NSUInteger, NSConfigurationMarkerState) {
    NSConfigurationMarkerNone,
    NSConfigurationMarkerUnresolved,
    NSConfigurationMarkerAcknowledged,
    NSConfigurationMarkerPriorBoot,
    NSConfigurationMarkerInvalid,
    NSConfigurationMarkerUnavailable,
};
FOUNDATION_EXPORT NSNotificationName const NSConfigurationLateAcknowledgement;

// Main-queue transaction owner shared by dashboard, restart and removal helper.
// Lock order: configuration -> provider lifetime -> policy -> activity -> exports.
// A submitted write owns the lock until its OS callback, even after a timeout.
@interface NSConfigurationCoordinator : NSObject
@property(nonatomic, copy) void (^schedule)(NSTimeInterval, void (^)(void));
@property(nonatomic, copy) NSStoreLock * (^acquireLock)(NSError **);
@property(nonatomic, copy) NSString * (^bootIdentifier)(void);
@property(nonatomic, copy) BOOL (^retireDocument)(NSSharedDirectory *, NSString *, NSError **);
@property(nonatomic) BOOL durableFence;
@property(nonatomic, copy) void (^abort)(NSError *);
@property(nonatomic, readonly) BOOL uncertain;
@property(nonatomic, readonly) BOOL reconciledMarker;
// A recognized outstanding remove cannot create or enable a profile.
@property(nonatomic, readonly) BOOL pendingRemoval;
@property(nonatomic, readonly) NSSharedDirectory *directory;
@property(nonatomic, readonly) NSError *acknowledgementError;
- (BOOL)begin:(NSError **)error;
- (BOOL)beginWithAuthorizationBudget:(NSError **)error;
- (NSConfigurationMarkerState)beginReadOnly:(NSError **)error;
- (void)load:(id)manager completion:(void (^)(NSError *))completion;
- (void)save:(id)manager completion:(void (^)(NSError *))completion;
- (void)saveWithAuthorization:(id)manager completion:(void (^)(NSError *))completion;
- (void)remove:(id)manager completion:(void (^)(NSError *))completion;
- (void)finish;
// Keep the OS result and acknowledgement cleanup error independently inspectable.
- (NSError *)writeErrorWithPreferenceError:(NSError *)preferenceError readbackError:(NSError *)readbackError;
@end
