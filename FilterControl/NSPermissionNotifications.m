#import "../Shared/NSIdentityDisplay.h"
#import "NSPermissionNotifications.h"
#import "../Shared/NSNotifications.h"
#import "../Shared/NSNotificationPolicy.h"
#import "../Shared/NSDestination.h"
#import "../Shared/NSGlobalRule.h"

static NSString *NSPermissionNotificationBody(NSDictionary *request) {
    NSDictionary *destination =
        [request[@"destination"] isKindOfClass:NSDictionary.class] ? request[@"destination"] : @{};
    NSString *domain = NSCleanDestinationHost(destination[@"domain"]);
    NSString *address = NSCleanDestinationHost(destination[@"address"]);
    NSString *domainKey = NSGlobalHostKey(domain);
    NSString *addressKey = NSGlobalHostKey(address);
    NSString *peer = [domainKey hasPrefix:@"domain:"] ? domain
                     : [addressKey hasPrefix:@"ip:"]  ? address
                     : [domainKey hasPrefix:@"ip:"]   ? domain
                                                      : @"";
    if (!NSConnectionRuleValues(request[@"direction"]).count) {
        return peer.length ? [@"Open NetShield2 to review " stringByAppendingString:peer]
                           : @"Open NetShield2 to review this request";
    }
    NSString *instruction = @"Long press to Allow or Block";
    return peer.length ? [peer stringByAppendingFormat:@"\n%@", instruction] : instruction;
}

// One bounded record per current logical request. Callbacks retain only their
// own identifier; a retired operation can never withdraw its replacement.
@interface NSNotificationSubmission : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic) NSUInteger attempts;
@property(nonatomic) NSTimeInterval attemptedAt;
@property(nonatomic) BOOL pending;
@property(nonatomic) BOOL submitted;
@end
@implementation NSNotificationSubmission
@end

@interface NSPermissionNotifications ()
@property(nonatomic, strong) id<NSPermissionNotificationCenter> center;
@property(nonatomic) BOOL stopped;
@property(nonatomic, copy) NSDictionary<NSString *, NSDictionary *> *requestsByToken;
@property(nonatomic, copy) NSString *retryRevision;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNotificationSubmission *> *submissions;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *issues;
@property(nonatomic, copy) NSTimeInterval (^clock)(void);
@end

static void NSWithdrawNotifications(id<NSPermissionNotificationCenter> center, NSArray<NSString *> *tokens) {
    if (!tokens.count) {
        return;
    }
    [center removePendingNotificationRequestsWithIdentifiers:tokens];
    [center removeDeliveredNotificationsWithIdentifiers:tokens];
}

@implementation NSPermissionNotifications
- (instancetype)init {
    NSRegisterPermissionActions();
    return [self initWithCenter:(id<NSPermissionNotificationCenter>)
                                    UNUserNotificationCenter.currentNotificationCenter];
}
- (instancetype)initWithCenter:(id<NSPermissionNotificationCenter>)center {
    return [self initWithCenter:center
                          clock:^{
                              return NSProcessInfo.processInfo.systemUptime;
                          }];
}
- (instancetype)initWithCenter:(id<NSPermissionNotificationCenter>)center
                         clock:(NSTimeInterval (^)(void))clock {
    if ((self = [super init])) {
        _center = center;
        _clock = [clock copy];
        _requestsByToken = @{};
        _submissions = [NSMutableDictionary new];
        _issues = [NSMutableDictionary new];
        [self reconcileNotifications];
    }
    return self;
}
- (void)reconcileNotifications {
    __weak typeof(self) weakSelf = self;
    void (^reconcile)(NSArray<UNNotificationRequest *> *) = ^(NSArray<UNNotificationRequest *> *requests) {
        NSPermissionNotifications *owner = weakSelf;
        if (!owner) {
            return;
        }
        @synchronized(owner) {
            if (owner.stopped) {
                return;
            }
            NSMutableArray *orphaned = [NSMutableArray new];
            for (UNNotificationRequest *request in requests) {
                NSString *token = request.content.userInfo[@"token"];
                if (NSIsPermissionCategory(request.content.categoryIdentifier) &&
                    (![token isKindOfClass:NSString.class] ||
                     ![owner.submissions[token].identifier isEqual:request.identifier])) {
                    [orphaned addObject:request.identifier];
                }
            }
            NSWithdrawNotifications(owner.center, orphaned);
        }
    };
    [self.center getPendingNotificationRequestsWithCompletionHandler:reconcile];
    [self.center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
        NSMutableArray *requests = [NSMutableArray new];
        for (UNNotification *notification in notifications) {
            [requests addObject:notification.request];
        }
        reconcile(requests);
    }];
}
- (NSString *)deliveryIssue {
    @synchronized(self) {
        NSString *token = [[self.issues.allKeys sortedArrayUsingSelector:@selector(compare:)] firstObject];
        return token ? self.issues[token] : @"";
    }
}
- (BOOL)isCurrent:(NSString *)token {
    return !self.stopped && self.requestsByToken[token] != nil;
}
- (BOOL)publishSnapshot:(NSDictionary *)snapshot
                 policy:(NSPolicy *)policy
          retryRevision:(NSString *)revision
                  error:(NSError **)error {
    BOOL published = NSWriteMonitorSnapshot(snapshot, error);
    [self updateRequests:published ? snapshot[@"requests"] : @[] policy:policy retryRevision:revision];
    return published;
}
- (void)retire:(NSString *)token {
    NSString *identifier = self.submissions[token].identifier;
    [self.submissions removeObjectForKey:token];
    [self.issues removeObjectForKey:token];
    if (identifier) {
        NSWithdrawNotifications(self.center, @[ identifier ]);
    }
}
- (void)updateRequests:(NSArray<NSDictionary *> *)requests
                policy:(NSPolicy *)policy
         retryRevision:(NSString *)revision {
    @synchronized(self) {
        if (self.stopped) {
            return;
        }
        NSMutableDictionary *next = [NSMutableDictionary new];
        for (NSDictionary *request in requests) {
            NSString *token = request[@"token"];
            if ([token isKindOfClass:NSString.class] && token.length &&
                next.count < NSMaximumActiveRequests + NSMaximumRequestHistory &&
                [policy requiresPermissionForRequest:request]) {
                next[token] = request;
            }
        }
        BOOL retry = revision && ![revision isEqual:self.retryRevision];
        if (revision) {
            self.retryRevision = revision;
        }
        for (NSString *token in self.submissions.allKeys) {
            NSDictionary *previous = self.requestsByToken[token];
            NSDictionary *current = next[token];
            if (retry || !current ||
                ![[previous dictionaryWithValuesForKeys:@[
                    @"identity", @"direction", @"askGeneration", @"session", @"activation"
                ]]
                    isEqual:[current dictionaryWithValuesForKeys:@[
                        @"identity", @"direction", @"askGeneration", @"session", @"activation"
                    ]]] ||
                ![NSPermissionNotificationBody(previous) isEqual:NSPermissionNotificationBody(current)]) {
                [self retire:token];
            }
        }
        self.requestsByToken = [next copy];
        for (NSDictionary *request in next.allValues) {
            [self submit:request];
        }
    }
}
- (void)submit:(NSDictionary *)request {
    NSString *token = request[@"token"];
    NSString *identity = request[@"identity"];
    NSTimeInterval now = self.clock();
    NSNotificationSubmission *record = self.submissions[token];
    if (record.pending && now - record.attemptedAt >= 10) {
        record.pending = NO;
        NSWithdrawNotifications(self.center, @[ record.identifier ]);
        self.issues[token] = @"Notification submission timed out. Return to notification settings to retry.";
    }
    if (record.submitted || record.pending || record.attempts >= 3 ||
        (record.attempts && now - record.attemptedAt < 5)) {
        return;
    }
    NSUInteger attempts = record.attempts;
    record = [NSNotificationSubmission new];
    record.attempts = attempts + 1;
    record.attemptedAt = now;
    record.pending = YES;
    NSString *submission = [@"NetShield2.permission." stringByAppendingString:NSUUID.UUID.UUIDString];
    record.identifier = submission;
    self.submissions[token] = record;
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = NSIdentityDisplayName(identity);
    content.body = NSPermissionNotificationBody(request);
    content.categoryIdentifier = NSPermissionCategoryForDirection(request[@"direction"]);
    content.sound = UNNotificationSound.defaultSound;
    content.userInfo =
        @{@"token" : token, @"identity" : identity, @"direction" : request[@"direction"] ?: @"unknown"};
    NSMutableDictionary *payload = [content.userInfo mutableCopy];
    for (NSString *key in @[ @"session", @"activation", @"askGeneration" ]) {
        if (request[key]) {
            payload[key] = request[key];
        }
    }
    content.userInfo = payload;
    UNNotificationRequest *notification = [UNNotificationRequest requestWithIdentifier:submission
                                                                               content:content
                                                                               trigger:nil];
    id<NSPermissionNotificationCenter> center = self.center;
    __weak id<NSPermissionNotificationCenter> weakCenter = center;
    __weak typeof(self) weakSelf = self;
    [center
        addNotificationRequest:notification
         withCompletionHandler:^(NSError *error) {
             id<NSPermissionNotificationCenter> center = weakCenter;
             if (!center) {
                 return;
             }
             NSPermissionNotifications *owner = weakSelf;
             if (!owner) {
                 NSWithdrawNotifications(center, @[ submission ]);
                 return;
             }
             @synchronized(owner) {
                 NSNotificationSubmission *currentRecord = owner.submissions[token];
                 if (![currentRecord.identifier isEqual:submission] || !currentRecord.pending) {
                     // Duplicate successful callbacks for a live submitted record are harmless.
                     if (![currentRecord.identifier isEqual:submission] || !currentRecord.submitted) {
                         NSWithdrawNotifications(center, @[ submission ]);
                     }
                     return;
                 }
                 currentRecord.pending = NO;
                 if (NSShouldWithdrawPermissionRequestNotification(
                         NSReadPolicy(NULL), owner.requestsByToken[token], [owner isCurrent:token])) {
                     NSWithdrawNotifications(center, @[ submission ]);
                     return;
                 }
                 if (error) {
                     owner.issues[token] =
                         [NSString stringWithFormat:@"Notification delivery failed: %@. Reopen "
                                                    @"notification settings, then return to retry.",
                                                    error.localizedDescription];
                     return;
                 }
                 currentRecord.submitted = YES;
                 [owner.issues removeObjectForKey:token];
             }
             [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
                 NSPermissionNotifications *current = weakSelf;
                 if (!current) {
                     return;
                 }
                 @synchronized(current) {
                     if (![current.submissions[token].identifier isEqual:submission]) {
                         return;
                     }
                     if (NSShouldWithdrawPermissionRequestNotification(
                             NSReadPolicy(NULL), current.requestsByToken[token], [current isCurrent:token])) {
                         return;
                     }
                     if (settings.authorizationStatus == UNAuthorizationStatusDenied ||
                         settings.authorizationStatus == UNAuthorizationStatusNotDetermined ||
                         settings.alertSetting == UNNotificationSettingDisabled) {
                         current.issues[token] =
                             @"iOS is not allowing alerts from the filter provider. Enable Allow "
                             @"Notifications and Banners in Notification settings, then return to retry.";
                     }
                 }
             }];
         }];
}
- (void)stop {
    @synchronized(self) {
        self.stopped = YES;
        for (NSString *token in self.submissions.allKeys) {
            [self retire:token];
        }
        self.requestsByToken = @{};
        [self.issues removeAllObjects];
    }
}
@end
