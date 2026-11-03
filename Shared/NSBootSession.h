#import <Foundation/Foundation.h>
#include <sys/sysctl.h>
// Optional cross-process boot identity. Failure cannot acknowledge a pending
// configuration write; DNS still checks both its wall and monotonic expiry.
static inline NSString *NSBootSessionIdentifier(void) {
    static NSString *identifier;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        char value[128] = {0};
        size_t size = sizeof(value);
        if (!sysctlbyname("kern.bootsessionuuid", value, &size, NULL, 0) && size > 1 &&
            size <= sizeof(value) && value[size - 1] == 0) {
            identifier =
                [[[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:value]] UUIDString];
        }
    });
    return identifier;
}
