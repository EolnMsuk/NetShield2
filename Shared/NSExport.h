#import "NSPolicy.h"
#import "NSConstants.h"

// Immutable rules-only candidate. Parsing never reads or changes local state.
@interface NSRuleImportResult : NSObject
@property(nonatomic, readonly, copy) NSDictionary *identityRules;
@property(nonatomic, readonly, copy) NSDictionary *globalRules;
@property(nonatomic, readonly, copy) NSDictionary *acceptedCounts;
@property(nonatomic, readonly, copy) NSDictionary *rejectedCounts;
@property(nonatomic, readonly, copy) NSArray<NSString *> *rejections;
- (NSString *)summary;
@end
FOUNDATION_EXPORT NSRuleImportResult *NSParseRulesJSON(NSData *data, NSError **error);

FOUNDATION_EXPORT NSError *NSExportError(NSString *message);
FOUNDATION_EXPORT NSURL *NSExportCacheURL(NSURL *container, BOOL create, NSError **error);
FOUNDATION_EXPORT BOOL NSIsExportDirectoryName(NSString *name);
FOUNDATION_EXPORT NSURL *NSStageRulesAndActivityExport(NSData *data, NSURL *container, NSError **error);
FOUNDATION_EXPORT BOOL NSRemoveStagedExport(NSURL *container, NSURL *url, NSError **error);
FOUNDATION_EXPORT NSData *NSRulesAndActivityJSON(NSPolicy *policy, NSArray<NSDictionary *> *events,
                                                 NSString *version, NSError **error);
