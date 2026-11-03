#import "NSPolicyReader.h"
#import "NSPolicyCache.h"
#import "NSConstants.h"
#import "NSBoundedFile.h"

NSString *const NSGroupIdentifier = @"group.com.eolnmsuk.netshield";
#ifdef NS_TESTING
static NSURL *NSTestContainer;
void NSSetTestContainer(NSURL *url) {
    NSTestContainer = url;
    NSInvalidatePolicyCache();
}
#endif
NSURL *NSSharedURL(NSString *name) {
    NSURL *root = nil;
#ifdef NS_TESTING
    root = NSTestContainer;
#endif
    if (!root) {
        root = [NSFileManager.defaultManager
            containerURLForSecurityApplicationGroupIdentifier:NSGroupIdentifier];
    }
    return name.length ? [root URLByAppendingPathComponent:name] : root;
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
    NSSharedDirectory *directory = [NSSharedDirectory openRoot:NSSharedURL(@"")
                                                          leaf:NSPolicyFile
                                                         error:error];
    if (!directory) {
        NSInvalidatePolicyCache();
        return nil;
    }
    return NSReadPolicyIn(directory, error);
}
NSPolicy *NSReadPolicyIn(NSSharedDirectory *directory, NSError **error) {
    return [NSSharedPolicyCache() readInDirectory:directory error:error];
}
