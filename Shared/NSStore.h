#import <Foundation/Foundation.h>
#import "NSPolicyReader.h"
#import "NSConstants.h"
#import "NSStoreLock.h"

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSDictionary *_Nullable NSReadDocument(NSString *name, NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL NSWriteDocument(NSDictionary *document, NSString *name,
                                       NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT NSDictionary *_Nullable NSReadDocumentIn(NSSharedDirectory *directory, NSString *name,
                                                           NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL NSWriteDocumentIn(NSSharedDirectory *directory, NSDictionary *document, NSString *name,
                                         NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT NSString *_Nullable NSReadNotificationRetryRevision(void);
FOUNDATION_EXPORT BOOL NSWriteNotificationRetryRevision(NSError **error);
FOUNDATION_EXPORT NSDictionary *NSReadMonitor(void);
// NSFileIsAbsent distinguishes a missing report from container, read and schema errors.
FOUNDATION_EXPORT NSDictionary *_Nullable NSReadMonitorWithError(NSError **error);
// The cutoff survives offline clears and stale provider snapshots. Monitor fields and requests survive.
FOUNDATION_EXPORT BOOL NSClearActivity(NSError **error);
FOUNDATION_EXPORT NSDictionary *_Nullable NSActivityEventWithCurrentBoundary(NSDictionary *event);
FOUNDATION_EXPORT NSArray<NSDictionary *> *NSActivityAfterClear(NSArray<NSDictionary *> *events);
FOUNDATION_EXPORT BOOL NSWriteMonitorSnapshot(NSDictionary *snapshot, NSError **error);
FOUNDATION_EXPORT BOOL NSEnsurePolicy(NSError **error);
FOUNDATION_EXPORT BOOL NSEnsurePolicyIn(NSSharedDirectory *directory, NSError **error);
FOUNDATION_EXPORT BOOL NSEnsureCompatiblePolicyIn(NSSharedDirectory *directory, BOOL legacyActive,
                                                  NSError **error);
FOUNDATION_EXPORT BOOL NSSetUnidentifiedMode(NSMutableDictionary *document, NSString *mode,
                                             BOOL preferencesLoaded, BOOL enabled, NSInteger configuredEngine,
                                             NSString *_Nullable activation, NSError **error);
FOUNDATION_EXPORT BOOL NSUpdatePolicy(BOOL (^mutation)(NSMutableDictionary *document, NSError **error),
                                      NSError **error);
// DNS cache refresh is atomic and does not flush transient answers.
FOUNDATION_EXPORT BOOL NSUpdateResolvedDNS(NSDictionary *pending, BOOL invalidate, NSError **error);
FOUNDATION_EXPORT BOOL NSUseDefaultRule(NSMutableDictionary *document, NSString *identity, NSError **error);
FOUNDATION_EXPORT BOOL NSToggleAppRule(NSMutableDictionary *document, NSString *identity, NSString *action,
                                       NSError **error);
FOUNDATION_EXPORT NSArray<NSString *> *_Nullable NSClearIdentityRules(NSMutableDictionary *document,
                                                                      BOOL system, NSArray *events,
                                                                      NSError **error);
FOUNDATION_EXPORT NSStoreLock *_Nullable NSAcquireProviderLock(NSError **error);
// Call only after Network Extension preference removal has been verified.
// The In variants require a validated NSConfigurationAccess section; the root
// wrappers take a short configuration lock and reject any logical owner.
FOUNDATION_EXPORT BOOL NSRemoveSharedStateAfterFilterRemoval(NSError **error);
FOUNDATION_EXPORT BOOL NSRemoveSharedStateIn(NSSharedDirectory *directory, NSError **error);
FOUNDATION_EXPORT BOOL NSResetSharedStateIn(NSSharedDirectory *directory, BOOL legacyProviderMayBeRunning,
                                            BOOL preserveSettings, NSError **error);
FOUNDATION_EXPORT BOOL NSResetSharedState(BOOL legacyProviderMayBeRunning, NSError **error);
FOUNDATION_EXPORT BOOL NSResetSharedStateWithOptions(BOOL legacyProviderMayBeRunning, BOOL preserveSettings,
                                                     NSError **error);
// Provider-only. Detach executes on the provider state queue with the policy locked.
FOUNDATION_EXPORT void NSDrainPermissionResponses(NSString *session, NSString *activation,
                                                  dispatch_block_t _Nullable (^detach)(NSDictionary *response,
                                                                                       NSPolicy *policy));
FOUNDATION_EXPORT void NSClearPermissionResponses(NSStoreLock *providerLock);
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
