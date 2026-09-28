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
