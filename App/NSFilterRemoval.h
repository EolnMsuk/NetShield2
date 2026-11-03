#import <Foundation/Foundation.h>

// Matches the NEFilterManager operations used here; also permits testing without
// accessing a real device's Network Extension preferences.
@protocol NSFilterRemovalManager <NSObject>
@property(nonatomic, readonly) id providerConfiguration;
@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
- (void)loadFromPreferencesWithCompletionHandler:(void (^)(NSError *error))completion;
- (void)removeFromPreferencesWithCompletionHandler:(void (^)(NSError *error))completion;
@end

FOUNDATION_EXPORT void NSRemoveInstalledFilter(id<NSFilterRemovalManager> manager,
                                               void (^completion)(NSError *error));

// Call only after verified preference removal. The deadline is absolute system
// uptime; cleanup attempts and the single completion run on the main queue.
FOUNDATION_EXPORT void NSRemoveSharedStateAfterFilterRemovalWithRetry(NSTimeInterval deadline,
                                                                      void (^completion)(NSError *error));

// The helper uses the same transaction for verified preference removal and cleanup.
FOUNDATION_EXPORT void NSRemoveInstalledFilterAndSharedState(id<NSFilterRemovalManager> manager,
                                                             NSTimeInterval deadline,
                                                             void (^completion)(NSError *));
