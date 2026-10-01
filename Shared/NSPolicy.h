#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
static inline BOOL NSIsAppleSystemIdentity(NSString *_Nullable identity) {
    return [identity isKindOfClass:NSString.class] &&
           ([identity hasPrefix:@"com.apple."] || [identity hasPrefix:@".com.apple."] ||
            [identity hasPrefix:@"Apple.com.apple."]);
}

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
- (BOOL)requiresPermissionForIdentity:(nullable NSString *)identity destination:(NSDictionary *)destination;
- (BOOL)needsSocketDestination:(NSDictionary *)destination;
- (BOOL)allowsIdentity:(nullable NSString *)identity
             direction:(NSFlowDirection)direction
           destination:(NSDictionary *)destination;
@end
NS_ASSUME_NONNULL_END
