#import "NSPolicy.h"
#import "NSConstants.h"

FOUNDATION_EXPORT NSError *NSExportError(NSString *message);
FOUNDATION_EXPORT NSURL *NSExportCacheURL(NSURL *container, BOOL create, NSError **error);
FOUNDATION_EXPORT BOOL NSIsExportDirectoryName(NSString *name);
FOUNDATION_EXPORT NSURL *NSStageRulesAndActivityExport(NSData *data, NSURL *container, NSError **error);
FOUNDATION_EXPORT BOOL NSRemoveStagedExport(NSURL *container, NSURL *url, NSError **error);
FOUNDATION_EXPORT NSData *NSRulesAndActivityJSON(NSPolicy *policy, NSArray<NSDictionary *> *events,
                                                 NSString *version, NSError **error);
