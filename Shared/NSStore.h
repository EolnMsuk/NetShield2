#import <Foundation/Foundation.h>
#import "NSPolicy.h"
#import "NSConstants.h"
#import "NSStoreLock.h"

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const NSGroupIdentifier;
FOUNDATION_EXPORT NSURL *_Nullable NSSharedURL(NSString *name);
FOUNDATION_EXPORT NSDictionary *_Nullable NSReadDocument(NSString *name, NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL NSWriteDocument(NSDictionary *document, NSString *name,
                                       NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT NSPolicy *_Nullable NSReadPolicy(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT NSDictionary *NSReadMonitor(void);
FOUNDATION_EXPORT void NSInvalidatePolicyCache(void);
FOUNDATION_EXPORT BOOL NSEnsurePolicy(NSError **error);
FOUNDATION_EXPORT BOOL NSUpdatePolicy(BOOL (^mutation)(NSMutableDictionary *document, NSError **error),
                                      NSError **error);
FOUNDATION_EXPORT BOOL NSUseDefaultRule(NSMutableDictionary *document, NSString *identity, NSError **error);
FOUNDATION_EXPORT NSStoreLock *_Nullable NSAcquireProviderLock(NSError **error);
FOUNDATION_EXPORT BOOL NSResetSharedState(BOOL legacyProviderMayBeRunning, NSError **error);
FOUNDATION_EXPORT BOOL NSResetSharedStateWithOptions(BOOL legacyProviderMayBeRunning, BOOL preserveSettings,
                                                     NSError **error);
#ifdef NS_TESTING
FOUNDATION_EXPORT void NSSetTestContainer(NSURL *url);
#endif
FOUNDATION_EXPORT BOOL NSAnswerPermissionRequestWithRule(NSDictionary *request, NSString *rule,
                                                         NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL NSAnswerPermissionRequest(NSDictionary *request, BOOL allow,
                                                 NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT NSDictionary *_Nullable NSPermissionResponseDocument(NSDictionary *request,
                                                                       NSDictionary *monitor,
                                                                       NSPolicy *policy, NSDate *now,
                                                                       BOOL allow,
                                                                       NSError *_Nullable *_Nullable error);
NS_ASSUME_NONNULL_END
