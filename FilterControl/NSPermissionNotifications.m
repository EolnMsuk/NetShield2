#import "NSPermissionNotifications.h"
#import "../Shared/NSNotifications.h"
#import "../Shared/NSNotificationPolicy.h"

@interface NSPermissionNotifications ()
@property(nonatomic, strong) id<NSPermissionNotificationCenter> center;
@property(nonatomic) BOOL stopped;
@property(nonatomic, copy) NSSet<NSString *> *tokens;
@property(nonatomic, copy) NSString *retryRevision;
@property(nonatomic, strong) NSMutableSet<NSString *> *submitted;
@property(nonatomic, strong) NSMutableSet<NSString *> *submitting;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *submissionIDs;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *attempts;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *attemptTimes;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *issues;
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
    if ((self = [super init])) {
        _center = center;
        _tokens = [NSSet set];
        _submitted = [NSMutableSet new];
        _submitting = [NSMutableSet new];
        _submissionIDs = [NSMutableDictionary new];
        _attempts = [NSMutableDictionary new];
        _attemptTimes = [NSMutableDictionary new];
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
            NSMutableArray *orphaned = [NSMutableArray new];
            for (UNNotificationRequest *request in requests) {
                if ([request.content.categoryIdentifier isEqual:NSPermissionCategory] &&
                    ![owner isCurrent:request.identifier]) {
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
    return !self.stopped && [self.tokens containsObject:token];
}
- (BOOL)publishSnapshot:(NSDictionary *)snapshot
                 policy:(NSPolicy *)policy
          retryRevision:(NSString *)revision
                  error:(NSError **)error {
    BOOL published = NSWriteDocument(snapshot, NSMonitorFile, error);
    [self updateRequests:published ? snapshot[@"requests"] : @[] policy:policy retryRevision:revision];
    return published;
}
- (void)updateRequests:(NSArray<NSDictionary *> *)requests
                policy:(NSPolicy *)policy
         retryRevision:(NSString *)revision {
    @synchronized(self) {
        if (self.stopped) {
            return;
        }
        NSSet *next = [NSSet setWithArray:[requests valueForKey:@"token"]];
        NSMutableSet *removed = [self.tokens mutableCopy];
        [removed minusSet:next];
        NSWithdrawNotifications(self.center, removed.allObjects);
        for (NSString *token in removed) {
            [self.submissionIDs removeObjectForKey:token];
            [self.submitted removeObject:token];
            [self.attempts removeObjectForKey:token];
            [self.attemptTimes removeObjectForKey:token];
            [self.issues removeObjectForKey:token];
        }
        self.tokens = next;
        if (revision && ![revision isEqual:self.retryRevision]) {
            self.retryRevision = revision;
            [self.submitted removeAllObjects];
            [self.attempts removeAllObjects];
            [self.attemptTimes removeAllObjects];
            [self.issues removeAllObjects];
            [self.submissionIDs removeAllObjects];
        }
        for (NSDictionary *request in requests) {
            if ([policy requiresPermissionForIdentity:request[@"identity"]]) {
                [self submit:request];
            }
        }
    }
}
- (void)submit:(NSDictionary *)request {
    NSString *token = request[@"token"];
    NSString *identity = request[@"identity"];
    NSUInteger attempts = [self.attempts[token] unsignedIntegerValue];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if ([self.submitted containsObject:token] || [self.submitting containsObject:token] || attempts >= 3 ||
        (attempts && now - [self.attemptTimes[token] doubleValue] < 5)) {
        return;
    }
    self.attempts[token] = @(attempts + 1);
    self.attemptTimes[token] = @(now);
    [self.submitting addObject:token];
    NSString *submission = NSUUID.UUID.UUIDString;
    self.submissionIDs[token] = submission;
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    // Keep destination details in the request/history, never in the system banner.
    content.title = identity;
    content.body = @"Wants network access. Long-press this banner to allow, block incoming or keep blocking.";
    content.categoryIdentifier = NSPermissionCategory;
    content.sound = UNNotificationSound.defaultSound;
    content.userInfo = @{@"token" : token, @"identity" : identity};
    UNNotificationRequest *notification = [UNNotificationRequest requestWithIdentifier:token
                                                                               content:content
                                                                               trigger:nil];
    id<NSPermissionNotificationCenter> center = self.center;
    __weak id<NSPermissionNotificationCenter> weakCenter = center;
    __weak typeof(self) weakSelf = self;
    [center addNotificationRequest:notification
             withCompletionHandler:^(NSError *error) {
                 id<NSPermissionNotificationCenter> center = weakCenter;
                 if (!center) {
                     return;
                 }
                 NSPermissionNotifications *owner = weakSelf;
                 // Each provider run owns a separate dispatcher. Old callbacks cannot touch the next run.
                 if (!owner) {
                     NSWithdrawNotifications(center, @[ token ]);
                     return;
                 }
                 @synchronized(owner) {
                     [owner.submitting removeObject:token];
                     if (![owner.submissionIDs[token] isEqual:submission]) {
                         // A failed monitor write or retry revoked this attempt.
                         // Do not let a late success suppress its replacement.
                         NSWithdrawNotifications(center, @[ token ]);
                         return;
                     }
                     if (NSShouldWithdrawPermissionNotification(NSReadPolicy(NULL), identity,
                                                                [owner isCurrent:token])) {
                         NSWithdrawNotifications(center, @[ token ]);
                         return;
                     }
                     if (error) {
                         owner.issues[token] =
                             [NSString stringWithFormat:@"Notification delivery failed: %@. Reopen "
                                                        @"notification settings, then return to retry.",
                                                        error.localizedDescription];
                         return;
                     }
                     [owner.submitted addObject:token];
                     [owner.issues removeObjectForKey:token];
                 }
                 [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
                     NSPermissionNotifications *current = weakSelf;
                     if (!current) {
                         return;
                     }
                     @synchronized(current) {
                         if (![current.submissionIDs[token] isEqual:submission]) {
                             return;
                         }
                         if (NSShouldWithdrawPermissionNotification(NSReadPolicy(NULL), identity,
                                                                    [current isCurrent:token])) {
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
        NSMutableSet *tokens = [self.tokens mutableCopy];
        [tokens unionSet:self.submitting];
        NSWithdrawNotifications(self.center, tokens.allObjects);
        self.tokens = [NSSet set];
        [self.issues removeAllObjects];
    }
}
@end
