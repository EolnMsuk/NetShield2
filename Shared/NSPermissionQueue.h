#import <Foundation/Foundation.h>
#import "NSPolicy.h"

NS_ASSUME_NONNULL_BEGIN
@interface NSPermissionQueue : NSObject
@property(nonatomic, readonly) NSArray<NSDictionary *> *requests;
@property(nonatomic, readonly) NSUInteger waitingCount;
- (nullable NSDictionary *)enqueueIdentity:(NSString *)identity
                                direction:(NSFlowDirection)direction
                                      now:(NSTimeInterval)now
                                     date:(NSDate *)date
                               completion:(void (^)(BOOL allow))completion;
- (void)resolveWithPolicy:(nullable NSPolicy *)policy now:(NSTimeInterval)now;
- (void)cancelAll;
@end
NS_ASSUME_NONNULL_END
