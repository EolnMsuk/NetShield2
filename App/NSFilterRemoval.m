#import "NSFilterRemoval.h"
#import "../Shared/NSStore.h"
#include <errno.h>

static void NSAttemptSharedStateCleanup(NSTimeInterval deadline, NSError *lastError,
                                        void (^completion)(NSError *)) {
    if (NSProcessInfo.processInfo.systemUptime >= deadline) {
        NSMutableDictionary *info =
            [NSMutableDictionary dictionaryWithObject:@"Timed out waiting for saved-state cleanup locks."
                                               forKey:NSLocalizedDescriptionKey];
        if (lastError) {
            info[NSUnderlyingErrorKey] = lastError;
            info[NSLocalizedDescriptionKey] = [NSString
                stringWithFormat:@"Timed out waiting for saved-state cleanup locks. "
                                 @"Last error: %@ (%@ %ld).",
                                 lastError.localizedDescription, lastError.domain, (long)lastError.code];
        }
        completion([NSError errorWithDomain:@"NetShield2.Uninstall" code:ETIMEDOUT userInfo:info]);
        return;
    }
    NSError *error = nil;
    if (NSRemoveSharedStateAfterFilterRemoval(&error)) {
        completion(nil);
        return;
    }
    BOOL busy = [error.domain isEqual:NSPOSIXErrorDomain] &&
                (error.code == EWOULDBLOCK || error.code == EAGAIN || error.code == EBUSY);
    if (!busy) {
        completion(error);
        return;
    }
    NSTimeInterval delay = MIN(0.25, MAX(0, deadline - NSProcessInfo.processInfo.systemUptime));
    // Only this continuation is pending. Each failed attempt has released its
    // locks, and completion paths never schedule another attempt.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       NSAttemptSharedStateCleanup(deadline, error, completion);
                   });
}

void NSRemoveSharedStateAfterFilterRemovalWithRetry(NSTimeInterval deadline, void (^completion)(NSError *)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAttemptSharedStateCleanup(deadline, nil, completion);
    });
}

void NSRemoveInstalledFilter(id<NSFilterRemovalManager> manager, void (^completion)(NSError *)) {
    [manager loadFromPreferencesWithCompletionHandler:^(NSError *loadError) {
        if (loadError) {
            completion(loadError);
            return;
        }
        if (!manager.providerConfiguration && !manager.enabled) {
            completion(nil);
            return;
        }
        [manager removeFromPreferencesWithCompletionHandler:^(NSError *removeError) {
            if (removeError) {
                completion(removeError);
                return;
            }
            [manager loadFromPreferencesWithCompletionHandler:^(NSError *verifyError) {
                if (verifyError) {
                    completion(verifyError);
                } else if (manager.providerConfiguration || manager.enabled) {
                    completion([NSError errorWithDomain:@"NetShield2.Uninstall"
                                                   code:1
                                               userInfo:@{
                                                   NSLocalizedDescriptionKey :
                                                       @"The system filter still exists after removal."
                                               }]);
                } else {
                    completion(nil);
                }
            }];
        }];
    }];
}
