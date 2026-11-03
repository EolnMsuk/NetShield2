#import <Foundation/Foundation.h>
#import "NSConfigurationCoordinator.h"

@protocol NSFilterRestartManager <NSObject>
@property(nonatomic, strong) id providerConfiguration;
@property(nonatomic, getter=isEnabled) BOOL enabled;
@property(nonatomic, copy) NSString *localizedDescription;
- (void)loadFromPreferencesWithCompletionHandler:(void (^)(NSError *))completion;
- (void)saveToPreferencesWithCompletionHandler:(void (^)(NSError *))completion;
@end

FOUNDATION_EXPORT NSString *const NSFilterLocalizedDescription;

typedef NS_ENUM(NSInteger, NSFilterRestartState) {
    NSFilterRestartUnchanged,
    // Preferences and current control heartbeat only, never data enforcement.
    NSFilterRestartEnabledVerified,
    NSFilterRestartOffVerified,
    NSFilterRestartUnknown,
};

// All state and callbacks belong to the main queue. Dependencies are injectable
// so preference errors and provider handoff can be tested without NetworkExtension.
@interface NSFilterRestart : NSObject
@property(nonatomic, strong) id<NSFilterRestartManager> manager;
@property(nonatomic, strong) NSConfigurationCoordinator *coordinator;
@property(nonatomic, copy) id (^configuration)(id previous, BOOL restoring, NSError **error);
@property(nonatomic, copy) BOOL (^isStopped)(BOOL previouslyEnabled);
@property(nonatomic, copy) BOOL (^isRunning)(id configuration);
@property(nonatomic, copy) void (^schedule)(NSTimeInterval delay, void (^work)(void));
@property(nonatomic, copy) void (^report)(NSString *stage, id configuration, BOOL enabled);
@property(nonatomic, readonly) NSFilterRestartState state;
- (void)start:(void (^)(NSError *error))completion;
@end
