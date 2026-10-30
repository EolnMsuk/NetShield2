#import <Foundation/Foundation.h>
#import "NSFilterRecovery.h"

FOUNDATION_EXPORT NSFilterRecovery *NSRecoveryService(void);
FOUNDATION_EXPORT NSDictionary *NSRecoverySnapshot(void);
FOUNDATION_EXPORT NSDictionary *NSRecoveryEvidence(void);
FOUNDATION_EXPORT NSDictionary *NSRecoveryReport(void);
FOUNDATION_EXPORT BOOL NSRecoveryCaptureEvidence(NSDictionary *snapshot, NSError **error);
FOUNDATION_EXPORT BOOL NSRecoveryImportEvidence(NSURL *url, NSError **error);
FOUNDATION_EXPORT void NSRecoveryPerform(NSString *operation, void (^completion)(NSDictionary *));
FOUNDATION_EXPORT NSString *NSRecoveryMessage(NSDictionary *result);
FOUNDATION_EXPORT BOOL NSRecoveryIsPlainPoC(void);
