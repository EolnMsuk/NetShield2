#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, NSFlowDirection) {
    NSFlowDirectionUnknown = 0,
    NSFlowDirectionInbound = 1,
    NSFlowDirectionOutbound = 2,
};

@interface NSPolicy : NSObject
@property(nonatomic, readonly, copy) NSDictionary *document;
+ (NSDictionary *)defaultDocument;
+ (nullable instancetype)policyWithDocument:(id)document error:(NSError *_Nullable *_Nullable)error;
- (BOOL)automaticallyAllowsIdentity:(nullable NSString *)identity;
- (BOOL)allowsIdentity:(nullable NSString *)identity direction:(NSFlowDirection)direction;
- (BOOL)requiresPermissionForIdentity:(nullable NSString *)identity;
@end
NS_ASSUME_NONNULL_END
