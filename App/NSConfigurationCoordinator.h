#import <Foundation/Foundation.h>
#import "../Shared/NSStoreLock.h"

// Main-queue transaction owner shared by dashboard, restart and removal helper.
// Lock order: configuration -> provider lifetime -> policy -> activity.
// A timeout does not cancel an OS write. The owner and durable pending fence
// survive terminal UI delivery until the actual callback acknowledges that write.
@interface NSConfigurationCoordinator : NSObject
@property(nonatomic, copy) void (^schedule)(NSTimeInterval, void (^)(void));
@property(nonatomic, copy) NSStoreLock * (^acquireLock)(NSError **);
@property(nonatomic) BOOL durableFence;
@property(nonatomic, copy) void (^abort)(NSError *);
@property(nonatomic, readonly) BOOL uncertain;
+ (BOOL)hasUnacknowledgedWrite;
- (BOOL)begin:(NSError **)error;
- (void)beginReadOnly;
- (void)load:(id)manager completion:(void (^)(NSError *))completion;
- (void)save:(id)manager completion:(void (^)(NSError *))completion;
- (void)remove:(id)manager completion:(void (^)(NSError *))completion;
- (void)finish;
@end
