#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
@class NSDashboard;

@interface NSAppDelegate : UIResponder <UIApplicationDelegate, UNUserNotificationCenterDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) NSDashboard *dashboard;
@end
