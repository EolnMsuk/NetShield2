#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, NSFilterBootPolicyError) {
    NSFilterBootPolicyUnsupported = 1,
    NSFilterBootPolicyReadbackFailed,
    NSFilterBootPolicyCopyFailed,
    NSFilterBootPolicyPersistenceFailed,
    NSFilterBootPolicyMigrationLatchFailed,
};

// No OS/package/jailbreak combination is qualified yet. The build-only experiment
// opt-in is never evidence of qualification and is not a user-defaults switch.
FOUNDATION_EXPORT BOOL NSFilterBootPolicyQualified(void);
FOUNDATION_EXPORT BOOL NSFilterBootPolicyExperimentEnabled(void);
FOUNDATION_EXPORT BOOL NSFilterBootPolicyRequired(void);
FOUNDATION_EXPORT BOOL NSFilterBootPolicyRead(id configuration, BOOL *value, NSError **error);
FOUNDATION_EXPORT BOOL NSFilterBootPolicyApply(id configuration, NSError **error);
FOUNDATION_EXPORT NSDictionary *NSFilterBootPolicyReport(id configuration);
FOUNDATION_EXPORT NSString *NSFilterBootPolicyStatus(id configuration, BOOL loaded);

// Capture public scope and the complete vendor metadata independently of copies.
// The private flag is read separately; it is never stored in vendorConfiguration.
FOUNDATION_EXPORT NSDictionary *NSFilterConfigurationFields(id configuration);
FOUNDATION_EXPORT BOOL NSFilterConfigurationValidate(id configuration, NSDictionary *expectedFields,
                                                     BOOL requireBootPolicy, NSError **error);
FOUNDATION_EXPORT id NSFilterConfigurationCheckedCopy(id configuration, BOOL requireBootPolicy,
                                                      NSError **error);

// Persist a claim before an automatic migration. Repeated loads/relaunches for
// the same target do not retry it; an explicit user restart remains available.
FOUNDATION_EXPORT BOOL NSFilterBootPolicyClaimMigration(NSUserDefaults *defaults, NSString *target,
                                                        NSError **error);
