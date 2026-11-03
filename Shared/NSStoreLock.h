#import "NSBoundedFile.h"

NS_ASSUME_NONNULL_BEGIN

// Stable lock files must never be unlinked. unlock is protected and idempotent.
@interface NSStoreLock : NSObject
@property(nonatomic, strong, readonly, nullable) NSSharedDirectory *directory;
+ (nullable instancetype)tryLockRoot:(nullable NSURL *)root leaf:(NSString *)leaf error:(NSError **)error;
+ (nullable instancetype)tryLockInDirectory:(NSSharedDirectory *)directory
                                       leaf:(NSString *)leaf
                                      error:(NSError **)error;
- (void)unlock;
@end

NS_ASSUME_NONNULL_END
