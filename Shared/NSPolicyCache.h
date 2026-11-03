#import "NSPolicy.h"

NS_ASSUME_NONNULL_BEGIN
@class NSSharedDirectory;
@interface NSPolicyCache : NSObject
- (nullable NSPolicy *)readInDirectory:(NSSharedDirectory *)directory error:(NSError **)error;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
