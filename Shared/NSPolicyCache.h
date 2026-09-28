#import "NSPolicy.h"

NS_ASSUME_NONNULL_BEGIN
@interface NSPolicyCache : NSObject
- (nullable NSPolicy *)readURL:(NSURL *)url error:(NSError **)error;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
