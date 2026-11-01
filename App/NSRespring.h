#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL NSRespring(NSError **error);

#ifdef NS_TESTING
// Exercise the production launch/fallback logic without starting a real respring.
FOUNDATION_EXPORT BOOL NSRespringUsingLauncher(NSArray<NSString *> *paths, int (^launcher)(NSString *path),
                                               NSError **error);
#endif

NS_ASSUME_NONNULL_END
