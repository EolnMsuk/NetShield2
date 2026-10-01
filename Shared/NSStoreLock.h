#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSStoreLock : NSObject
+ (nullable instancetype)tryLockURL:(NSURL *)url error:(NSError **)error;
- (void)unlock;
@end

NS_ASSUME_NONNULL_END
