#import <Foundation/Foundation.h>
@class NSConfigurationCoordinator;

// Matches the NEFilterManager operations used here; also permits testing without
// accessing a real device's Network Extension preferences.
@protocol NSFilterRemovalManager <NSObject>
@property(nonatomic, readonly) id providerConfiguration;
@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
- (void)loadFromPreferencesWithCompletionHandler:(void (^)(NSError *error))completion;
- (void)removeFromPreferencesWithCompletionHandler:(void (^)(NSError *error))completion;
@end

// The caller owns a logical reservation and has just loaded saved preferences.
// Preference waits hold no physical lock; every cleanup revalidates the token.
FOUNDATION_EXPORT void NSRemoveLoadedFilter(NSConfigurationCoordinator *owner,
                                            id<NSFilterRemovalManager> manager,
                                            void (^completion)(NSError *error));

FOUNDATION_EXPORT void NSRemoveInstalledFilter(id<NSFilterRemovalManager> manager,
                                               void (^completion)(NSError *error));

// Call only after verified preference removal. The deadline is absolute system
// uptime; cleanup attempts and the single completion run on the main queue.
FOUNDATION_EXPORT void NSRemoveSharedStateAfterFilterRemovalWithRetry(NSTimeInterval deadline,
                                                                      void (^completion)(NSError *error));

// The helper uses the same transaction for verified preference removal and cleanup.
FOUNDATION_EXPORT NSString *const NSUninstallCleanupPendingKey;
FOUNDATION_EXPORT void NSRemoveInstalledFilterAndSharedState(id<NSFilterRemovalManager> manager,
                                                             NSTimeInterval deadline,
                                                             void (^clearAppState)(void),
                                                             void (^completion)(NSError *));
