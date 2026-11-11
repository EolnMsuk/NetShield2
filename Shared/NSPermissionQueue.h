#import <Foundation/Foundation.h>
#import "NSPolicy.h"

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, NSPermissionResult) {
    NSPermissionBlocked,
    NSPermissionAllowedByPolicy,
    NSPermissionAllowedOnce,
    NSPermissionBlockedOnce,
};
// Not internally thread safe. All access belongs to one caller-owned serial
// queue. Completions are synchronous after waiter detachment; callers must move
// external delivery off that queue if it can reenter provider state.
@interface NSPermissionQueue : NSObject
@property(nonatomic, readonly) NSArray<NSDictionary *> *requests;
@property(nonatomic, readonly) NSUInteger waitingCount;
@property(nonatomic, readonly) NSUInteger overflowCount;
@property(nonatomic, readonly) NSUInteger evictedRequestCount;
- (nullable NSDictionary *)enqueueIdentity:(NSString *)identity
                                 direction:(NSFlowDirection)direction
                                       now:(NSTimeInterval)now
                                      date:(NSDate *)date
                                completion:(void (^)(BOOL allow))completion;
- (nullable NSDictionary *)enqueueIdentity:(NSString *)identity
                                 direction:(NSFlowDirection)direction
                               destination:(NSDictionary *)destination
                                       now:(NSTimeInterval)now
                                      date:(NSDate *)date
                                completion:(void (^)(BOOL allow))completion;
- (nullable NSDictionary *)enqueueIdentity:(NSString *)identity
                                 direction:(NSFlowDirection)direction
                               destination:(NSDictionary *)destination
                                      flow:(NSString *)flow
                                       now:(NSTimeInterval)now
                                      date:(NSDate *)date
                                    result:(void (^)(NSPermissionResult result))completion;
// Detach under the policy lock and deliver the returned block after unlocking.
- (nullable dispatch_block_t)takeResponse:(NSDictionary *)response
                                   policy:(NSPolicy *)policy
                                      now:(NSTimeInterval)now;
- (void)resolveWithPolicy:(nullable NSPolicy *)policy now:(NSTimeInterval)now;
- (void)cancelAll;
@end
NS_ASSUME_NONNULL_END
