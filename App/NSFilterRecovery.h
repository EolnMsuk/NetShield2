#import <Foundation/Foundation.h>

@protocol NSFilterRecoveryManager <NSObject>
@property(nonatomic, readonly) id providerConfiguration;
@property(nonatomic, getter=isEnabled) BOOL enabled;
- (void)loadFromPreferencesWithCompletionHandler:(void (^)(NSError *))completion;
- (void)saveToPreferencesWithCompletionHandler:(void (^)(NSError *))completion;
- (void)removeFromPreferencesWithCompletionHandler:(void (^)(NSError *))completion;
@end

// Main-queue state machine. No store, provider, network, or jailbreak dependencies.
// Snapshot returns {present, enabled, fingerprint}; fingerprint excludes enabled.
@interface NSFilterRecovery : NSObject
@property(nonatomic, strong) id<NSFilterRecoveryManager> manager;
@property(nonatomic, copy) NSDictionary * (^snapshot)(void);
@property(nonatomic, copy) void (^schedule)(NSTimeInterval, void (^)(void));
@property(nonatomic) NSTimeInterval timeout;
@property(nonatomic, readonly) BOOL busy;
- (void)perform:(NSString *)operation
       evidence:(NSDictionary *)fingerprint
     completion:(void (^)(NSDictionary *result))completion;
@end
