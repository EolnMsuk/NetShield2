#import "NSPolicyReader.h"
#import "NSPolicyCache.h"
#import "NSConstants.h"

NSString *const NSGroupIdentifier = @"group.com.eolnmsuk.netshield";
#ifdef NS_TESTING
static NSURL *NSTestContainer;
void NSSetTestContainer(NSURL *url) {
    NSTestContainer = url;
    NSInvalidatePolicyCache();
}
#endif
NSURL *NSSharedURL(NSString *name) {
#ifdef NS_TESTING
    if (NSTestContainer) {
        return [NSTestContainer URLByAppendingPathComponent:name];
    }
#endif
    NSURL *root =
        [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:NSGroupIdentifier];
    return root ? [root URLByAppendingPathComponent:name] : nil;
}
static NSPolicyCache *NSSharedPolicyCache(void) {
    static NSPolicyCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSPolicyCache new];
    });
    return cache;
}
void NSInvalidatePolicyCache(void) {
    [NSSharedPolicyCache() invalidate];
}
NSPolicy *NSReadPolicy(NSError **error) {
    NSURL *url = NSSharedURL(NSPolicyFile);
    if (!url) {
        NSInvalidatePolicyCache();
        if (error) {
            *error = [NSError
                errorWithDomain:@"NetShield2.Storage"
                           code:1
                       userInfo:@{
                           NSLocalizedDescriptionKey : @"The shared app-group container is unavailable."
                       }];
        }
        return nil;
    }
    return [NSSharedPolicyCache() readURL:url error:error];
}
