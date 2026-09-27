#import <Foundation/Foundation.h>
#import "NSPolicy.h"

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const NSGroupIdentifier;
FOUNDATION_EXPORT NSURL * _Nullable NSSharedURL(NSString *name);
FOUNDATION_EXPORT NSDictionary * _Nullable NSReadDocument(NSString *name, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT BOOL NSWriteDocument(NSDictionary *document, NSString *name, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSPolicy * _Nullable NSReadPolicy(NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSDictionary *NSReadMonitor(void);
FOUNDATION_EXPORT BOOL NSAnswerPermissionRequest(NSDictionary *request, BOOL allow, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSDictionary * _Nullable NSPermissionResponseDocument(NSDictionary *request, NSDictionary *monitor, NSPolicy *policy, NSDate *now, BOOL allow, NSError * _Nullable * _Nullable error);
NS_ASSUME_NONNULL_END
