#import <Foundation/Foundation.h>

@protocol NSFilterRestartManager <NSObject>
@property(nonatomic, strong) id providerConfiguration;
@property(nonatomic, getter=isEnabled) BOOL enabled;
@property(nonatomic, copy) NSString *localizedDescription;
- (void)loadFromPreferencesWithCompletionHandler:(void (^)(NSError *))completion;
- (void)saveToPreferencesWithCompletionHandler:(void (^)(NSError *))completion;
@end

// All state and callbacks belong to the main queue. Dependencies are injectable
// so preference errors and provider handoff can be tested without NetworkExtension.
@interface NSFilterRestart : NSObject
@property(nonatomic, strong) id<NSFilterRestartManager> manager;
@property(nonatomic, copy) id (^configuration)(id previous, BOOL restoring, NSError **error);
@property(nonatomic, copy) BOOL (^isStopped)(BOOL previouslyEnabled);
@property(nonatomic, copy) BOOL (^isRunning)(id configuration);
@property(nonatomic, copy) void (^schedule)(NSTimeInterval delay, void (^work)(void));
- (void)start:(void (^)(NSError *error))completion;
@end
