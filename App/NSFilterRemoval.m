#import "NSFilterRemoval.h"

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
