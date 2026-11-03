#import "NSFilterRemoval.h"
#import "NSConfigurationCoordinator.h"
#import "../Shared/NSStore.h"
#include <errno.h>

typedef void (^NSCleanupPrecheck)(void (^)(NSError *));
static void NSAttemptSharedStateCleanup(NSTimeInterval deadline, NSError *lastError,
                                        NSCleanupPrecheck precheck, void (^completion)(NSError *)) {
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
    void (^attempt)(NSError *) = ^(NSError *verificationError) {
        if (verificationError) {
            completion(verificationError);
            return;
        }
        if (NSProcessInfo.processInfo.systemUptime >= deadline) {
            NSAttemptSharedStateCleanup(deadline, lastError, nil, completion);
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
                           NSAttemptSharedStateCleanup(deadline, error, precheck, completion);
                       });
    };
    if (precheck) {
        precheck(attempt);
    } else {
        attempt(nil);
    }
}

void NSRemoveSharedStateAfterFilterRemovalWithRetry(NSTimeInterval deadline, void (^completion)(NSError *)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAttemptSharedStateCleanup(deadline, nil, nil, completion);
    });
}

static void NSRemoveFilter(id<NSFilterRemovalManager> manager, BOOL cleanup, NSTimeInterval deadline,
                           void (^completion)(NSError *)) {
    NSConfigurationCoordinator *owner = [NSConfigurationCoordinator new];
    NSError *lockError = nil;
    if (![owner begin:&lockError]) {
        completion(lockError);
        return;
    }
    __block BOOL done = NO;
    void (^finished)(NSError *) = ^(NSError *error) {
        if (done) {
            return;
        }
        done = YES;
        [owner finish];
        completion(error);
    };
    owner.abort = finished;
    void (^removed)(NSError *) = ^(NSError *error) {
        if (error || !cleanup) {
            finished(error);
            return;
        }
        NSAttemptSharedStateCleanup(
            deadline, nil,
            ^(void (^checked)(NSError *)) {
                [owner load:manager
                    completion:^(NSError *verifyError) {
                        if (!verifyError && (manager.providerConfiguration || manager.enabled)) {
                            verifyError = [NSError errorWithDomain:@"NetShield2.Uninstall"
                                                              code:EBUSY
                                                          userInfo:@{
                                                              NSLocalizedDescriptionKey :
                                                                  @"The saved filter changed while waiting. "
                                                                  @"Shared files were preserved."
                                                          }];
                        }
                        checked(verifyError);
                    }];
            },
            finished);
    };
    [owner load:manager
        completion:^(NSError *loadError) {
            if (loadError) {
                finished(loadError);
                return;
            }
            if (!manager.providerConfiguration && !manager.enabled) {
                removed(nil);
                return;
            }
            [owner remove:manager
                completion:^(NSError *removeError) {
                    if (removeError) {
                        finished(removeError);
                        return;
                    }
                    [owner load:manager
                        completion:^(NSError *verifyError) {
                            if (!verifyError && (manager.providerConfiguration || manager.enabled)) {
                                verifyError =
                                    [NSError errorWithDomain:@"NetShield2.Uninstall"
                                                        code:1
                                                    userInfo:@{
                                                        NSLocalizedDescriptionKey :
                                                            @"The system filter still exists after removal."
                                                    }];
                            }
                            removed(verifyError);
                        }];
                }];
        }];
}
void NSRemoveInstalledFilter(id<NSFilterRemovalManager> manager, void (^completion)(NSError *)) {
    NSRemoveFilter(manager, NO, 0, completion);
}
void NSRemoveInstalledFilterAndSharedState(id<NSFilterRemovalManager> manager, NSTimeInterval deadline,
                                           void (^completion)(NSError *)) {
    NSRemoveFilter(manager, YES, deadline, completion);
}
