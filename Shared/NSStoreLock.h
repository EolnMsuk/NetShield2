#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Keep this object alive for the whole operation. Never unlink a lock file.
@interface NSStoreLock : NSObject
+ (nullable instancetype)tryLockURL:(NSURL *)url error:(NSError **)error;
- (void)unlock;
@end

NS_ASSUME_NONNULL_END
