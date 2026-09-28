#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#import "../Shared/NSPolicy.h"

@protocol NSPermissionNotificationCenter <NSObject>
- (void)addNotificationRequest:(UNNotificationRequest *)request
         withCompletionHandler:(void (^)(NSError *))completion;
- (void)removePendingNotificationRequestsWithIdentifiers:(NSArray<NSString *> *)identifiers;
- (void)removeDeliveredNotificationsWithIdentifiers:(NSArray<NSString *> *)identifiers;
- (void)getNotificationSettingsWithCompletionHandler:(void (^)(UNNotificationSettings *))completion;
@end

@interface NSPermissionNotifications : NSObject
- (instancetype)initWithCenter:(id<NSPermissionNotificationCenter>)center;
@property(nonatomic, readonly, copy) NSString *deliveryIssue;
- (void)updateRequests:(NSArray<NSDictionary *> *)requests
                policy:(NSPolicy *)policy
         retryRevision:(NSString *)revision;
- (void)stop;
@end
