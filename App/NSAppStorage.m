#import "NSAppStorage.h"
#import <UIKit/UIKit.h>
#import "NSConfigurationCoordinator.h"

@interface NSAppConfigurationExecution : NSObject <NSConfigurationExecution>
@property(atomic) BOOL valid;
@property(nonatomic) UIBackgroundTaskIdentifier identifier;
@end
static BOOL NSConfigurationBudgetExpired; // main queue only, reset on foreground return
@implementation NSAppConfigurationExecution
- (void)finish {
    // The caller has already released every local lock. Main never waits for a
    // storage worker while that worker needs to start/end this assertion.
    void (^end)(void) = ^{
        if (self.identifier != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:self.identifier];
            self.identifier = UIBackgroundTaskInvalid;
        }
        self.valid = NO;
    };
    if (NSThread.isMainThread) {
        end();
    } else {
        dispatch_async(dispatch_get_main_queue(), end);
    }
}
@end
void NSRegisterConfigurationExecution(void) {
    NSSetConfigurationExecutionFactory(^id<NSConfigurationExecution> {
        __block NSAppConfigurationExecution *execution = nil;
        void (^begin)(void) = ^{
            if (NSConfigurationBudgetExpired) {
                return;
            }
            execution = [NSAppConfigurationExecution new];
            execution.identifier = UIBackgroundTaskInvalid;
            __weak NSAppConfigurationExecution *weakExecution = execution;
            execution.identifier = [UIApplication.sharedApplication
                beginBackgroundTaskWithName:@"NetShield2 local configuration"
                          expirationHandler:^{
                              NSAppConfigurationExecution *expired = weakExecution;
                              if (!expired || expired.identifier == UIBackgroundTaskInvalid) {
                                  return;
                              }
                              NSConfigurationBudgetExpired = YES;
                              expired.valid = NO;
                              // A running synchronous section ends its own task
                              // after releasing locks. Never close its fd here.
                          }];
            execution.valid = execution.identifier != UIBackgroundTaskInvalid;
        };
        if (NSThread.isMainThread) {
            begin();
        } else {
            dispatch_sync(dispatch_get_main_queue(), begin);
        } // before any file lock
        return execution;
    });
}
void NSResumeConfigurationExecution(void) {
    NSConfigurationBudgetExpired = NO;
    [NSConfigurationCoordinator checkPendingSave];
}
dispatch_queue_t NSAppStorageQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.eolnmsuk.netshield.app.storage", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}
