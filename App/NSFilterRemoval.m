#import "NSFilterRemoval.h"
#import "NSConfigurationCoordinator.h"
#import "../Shared/NSStore.h"
#include <errno.h>

typedef void (^NSCleanupPrecheck)(void (^)(NSError *));
static void NSAttemptSharedStateCleanup(NSSharedDirectory *directory, NSTimeInterval deadline,
                                        NSError *lastError, NSCleanupPrecheck precheck,
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
    void (^attempt)(NSError *) = ^(NSError *verificationError) {
        if (verificationError) {
            completion(verificationError);
            return;
        }
        if (NSProcessInfo.processInfo.systemUptime >= deadline) {
            NSAttemptSharedStateCleanup(directory, deadline, lastError, nil, completion);
            return;
        }
        NSError *error = nil;
        BOOL cleaned = directory ? NSRemoveSharedStateIn(directory, &error)
                                 : NSRemoveSharedStateAfterFilterRemoval(&error);
        if (cleaned) {
            completion(nil);
            return;
        }
        if (!NSIsLockContention(error)) {
            completion(error);
            return;
        }
        NSTimeInterval delay = MIN(0.25, MAX(0, deadline - NSProcessInfo.processInfo.systemUptime));
        // Only this continuation is pending. Each failed attempt has released its
        // locks, and completion paths never schedule another attempt.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           NSAttemptSharedStateCleanup(directory, deadline, error, precheck, completion);
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
        NSAttemptSharedStateCleanup(nil, deadline, nil, nil, completion);
    });
}

NSString *const NSUninstallCleanupPendingKey = @"verifiedPreferencesCleanupPending";

static NSError *NSUninstallCleanupPending(NSError *error) {
    NSString *detail = [NSString stringWithFormat:@"Saved preferences were verified absent before cleanup. "
                                                  @"Saved-state cleanup did not complete. %@ (%@ %ld).",
                                                  error.localizedDescription, error.domain, (long)error.code];
    return [NSError errorWithDomain:@"NetShield2.Uninstall"
                               code:2
                           userInfo:@{
                               NSLocalizedDescriptionKey : detail,
                               NSUnderlyingErrorKey : error,
                               NSUninstallCleanupPendingKey : @YES
                           }];
}

static void NSRemoveFilter(id<NSFilterRemovalManager> manager, NSTimeInterval deadline,
                           void (^clearAppState)(void), void (^completion)(NSError *)) {
    NSConfigurationCoordinator *owner = [NSConfigurationCoordinator new];
    NSError *lockError = nil;
    if (![owner begin:&lockError]) {
        NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
        if (remaining > 0 && NSIsLockContention(lockError)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MIN(remaining, 0.25) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               if (NSProcessInfo.processInfo.systemUptime < deadline) {
                                   NSRemoveFilter(manager, deadline, clearAppState, completion);
                               } else {
                                   completion(lockError);
                               }
                           });
        } else {
            completion(lockError);
        }
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
        if (error || !clearAppState) {
            finished(error);
            return;
        }
        NSAttemptSharedStateCleanup(
            owner.directory, deadline, nil,
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
                        if (verifyError) {
                            finished(verifyError);
                            return;
                        }
                        checked(nil);
                    }];
            },
            ^(NSError *cleanupError) {
                if (cleanupError) {
                    finished(NSUninstallCleanupPending(cleanupError));
                    return;
                }
                clearAppState();
                finished(nil);
            });
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
                    if (removeError && !owner.acknowledgementError) {
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
                            NSError *result = [owner writeErrorWithPreferenceError:removeError
                                                                     readbackError:verifyError];
                            if (clearAppState && result && !removeError && !verifyError) {
                                result = NSUninstallCleanupPending(result);
                            }
                            removed(result);
                        }];
                }];
        }];
}
void NSRemoveInstalledFilter(id<NSFilterRemovalManager> manager, void (^completion)(NSError *)) {
    NSRemoveFilter(manager, 0, nil, completion);
}
void NSRemoveInstalledFilterAndSharedState(id<NSFilterRemovalManager> manager, NSTimeInterval deadline,
                                           void (^clearAppState)(void), void (^completion)(NSError *)) {
    NSRemoveFilter(manager, deadline, clearAppState, completion);
}
