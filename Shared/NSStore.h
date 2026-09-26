#import <Foundation/Foundation.h>
#import "NSPolicy.h"

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const NSGroupIdentifier;
FOUNDATION_EXPORT NSURL * _Nullable NSSharedURL(NSString *name);
FOUNDATION_EXPORT NSDictionary * _Nullable NSReadDocument(NSString *name, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT BOOL NSWriteDocument(NSDictionary *document, NSString *name, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSPolicy * _Nullable NSReadPolicy(NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSDictionary *NSReadMonitor(void);
NS_ASSUME_NONNULL_END
