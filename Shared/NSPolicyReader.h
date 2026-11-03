#import "NSPolicy.h"
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const NSGroupIdentifier;
FOUNDATION_EXPORT NSURL *_Nullable NSSharedURL(NSString *name);
FOUNDATION_EXPORT NSPolicy *_Nullable NSReadPolicy(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT void NSInvalidatePolicyCache(void);
#ifdef NS_TESTING
FOUNDATION_EXPORT void NSSetTestContainer(NSURL *url);
#endif
NS_ASSUME_NONNULL_END
