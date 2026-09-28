#import "NSDashboard+Internal.h"
#include <float.h>

@implementation NSDashboard
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"NetShield2";
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.deferredRequests = [NSMutableSet new];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self
                                                      action:@selector(loadConfiguration)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    self.rowHeights = [NSMutableDictionary new];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(configurationChanged:)
                                               name:NEFilterConfigurationDidChangeNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(configurationChanged:)
                                               name:UIApplicationDidBecomeActiveNotification
                                             object:nil];
    NSError *error = nil;
    if (NSEnsurePolicy(&error)) {
        self.policy = NSReadPolicy(&error);
    }
    self.policyReadError = self.policy ? @"" : error.localizedDescription;
    self.message = @"";
    NSRemoveAutomaticallyAllowedNotifications();
    [self refreshNotificationSettings];
    [self loadConfiguration];
}
- (void)configurationChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshNotificationSettings];
        NSWriteDocument(@{@"revision" : NSUUID.UUID.UUIDString}, NSNotificationRetryFile, NULL);
        [self loadConfiguration];
    });
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.timer invalidate];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2
                                                 repeats:YES
                                                   block:^(NSTimer *timer) {
                                                       [weakSelf reloadMonitor];
                                                   }];
    [self reloadMonitor];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
}
- (void)reloadMonitor {
    NSError *policyError = nil;
    self.policy = NSReadPolicy(&policyError);
    self.policyReadError = self.policy ? @"" : policyError.localizedDescription;
    if (self.policy && (self.tableView.dragging || self.tableView.decelerating)) {
        return;
    }
    NSMutableDictionary *monitor = [NSReadMonitor() mutableCopy];
    NSMutableArray *requests = [NSMutableArray new];
    for (NSDictionary *request in monitor[@"requests"]) {
        if ([self.policy requiresPermissionForIdentity:request[@"identity"]]) {
            [requests addObject:request];
        }
    }
    monitor[@"requests"] = requests;
    self.monitor = monitor;
    if (self.permissionAlert &&
        ![[requests valueForKey:@"token"] containsObject:self.presentedRequest[@"token"]]) {
        [self.permissionAlert dismissViewControllerAnimated:NO completion:nil];
        self.permissionAlert = nil;
        self.presentedRequest = nil;
    }
    NSMutableSet *identities = [NSMutableSet setWithArray:[self.policy.document[@"rules"] allKeys] ?: @[]];
    for (NSDictionary *event in self.monitor[@"events"]) {
        NSString *identity = event[@"identity"];
        if ([identity isKindOfClass:NSString.class] && identity.length) {
            [identities addObject:identity];
        }
    }
    self.identities = [[identities allObjects] sortedArrayUsingSelector:@selector(compare:)];
    NSSet *tokens = [NSSet setWithArray:[self.monitor[@"requests"] valueForKey:@"token"] ?: @[]];
    [self.deferredRequests intersectSet:tokens];
    [self refreshTableKeepingPosition];
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive && !self.busy &&
        !self.presentedViewController && self.loaded && [NEFilterManager sharedManager].enabled &&
        [self hasFreshMonitor]) {
        for (NSDictionary *request in self.monitor[@"requests"]) {
            if (![self.deferredRequests containsObject:request[@"token"]]) {
                [self presentRequest:request];
                break;
            }
        }
    }
}
- (BOOL)hasFreshMonitor {
    NSDate *updated = self.monitor[@"updated"];
    NSTimeInterval age = [updated isKindOfClass:NSDate.class] ? -updated.timeIntervalSinceNow : DBL_MAX;
    return age >= 0 && age < NSMonitorFreshness && [self.monitor[@"controlRunning"] boolValue];
}
- (void)showError:(NSError *)error {
    [self showError:error operation:@"Policy/storage"];
}
- (void)showError:(NSError *)error operation:(NSString *)operation {
    self.message = [NSString stringWithFormat:@"%@: %@ (%@ %ld).", operation, error.localizedDescription,
                                              error.domain, (long)error.code];
    [self refreshTableKeepingPosition];
}
- (void)updatePolicy:(BOOL (^)(NSMutableDictionary *, NSError **))mutation {
    NSError *error = nil;
    if (!NSUpdatePolicy(mutation, &error)) {
        [self showError:error];
        [self reloadMonitor];
        return;
    }
    NSRemoveAutomaticallyAllowedNotifications();
    self.message = @"Policy saved for new flows. Close existing connections and retry; admitted flows keep "
                   @"their previous verdict.";
    [self reloadMonitor];
}
- (void)chooseActionForIdentity:(NSString *)identity defaultKey:(NSString *)key {
    if (!self.policy) {
        return;
    }
    NSString *title = identity;
    NSString *explanation = @"Choose a rule for new connections. Incoming/outgoing describes who starts the "
                            @"connection, not downloads or reply traffic.";
    NSArray *actions = @[ @"allow", @"block", @"block-inbound", @"block-outbound", @"use-default" ];
    if ([key isEqual:@"default"]) {
        title = @"Default Rule";
        explanation = @"Choose what happens when an app without a saved rule connects. Ask me lets you "
                      @"decide from a notification.";
        actions = @[ @"ask", @"allow", @"block" ];
    } else if ([key isEqual:@"unattributed"]) {
        title = @"Unidentified connections";
        explanation = @"These connections have no app identity from iOS. Allow is recommended to avoid "
                      @"interrupting system services.";
        actions = @[ @"allow", @"block" ];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:explanation
                                                            preferredStyle:UIAlertControllerStyleAlert];
    for (NSString *action in actions) {
        [alert addAction:[UIAlertAction actionWithTitle:[self ruleTitle:action]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *selected) {
                                                    [self updatePolicy:^BOOL(NSMutableDictionary *document,
                                                                             NSError **error) {
                                                        if (key) {
                                                            document[key] = action;
                                                        } else {
                                                            NSMutableDictionary *rules = document[@"rules"];
                                                            if ([action isEqual:@"use-default"]) {
                                                                [rules removeObjectForKey:identity];
                                                            } else {
                                                                rules[identity] = action;
                                                            }
                                                        }
                                                        return YES;
                                                    }];
                                                }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)addIdentity {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Exact OS identity"
                                            message:@"Prefer selecting an identity observed below. This "
                                                    @"value is sourceAppIdentifier from Network Extension; "
                                                    @"it may differ from the app's bundle identifier."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Exact sourceAppIdentifier";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Choose rule"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                                NSString *identity = alert.textFields.firstObject.text;
                                                if (identity.length) {
                                                    dispatch_async(dispatch_get_main_queue(), ^{
                                                        [self chooseActionForIdentity:identity
                                                                           defaultKey:nil];
                                                    });
                                                }
                                            }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (NSString *)ruleTitle:(NSString *)rule {
    return @{
        @"ask" : @"Ask me",
        @"allow" : @"Allow",
        @"block" : @"Block",
        @"block-inbound" : @"Block incoming connections",
        @"block-outbound" : @"Block outgoing connections",
        @"use-default" : @"Use Default Rule"
    }[rule ?: @""]
               ?: @"Use Default Rule";
}
- (void)firewallChanged:(UISwitch *)sender {
    if (self.busy) {
        return;
    }
    if (!sender.on) {
        [self changeConfiguration:NSConfigurationDisable];
        return;
    }
    self.busy = YES;
    [self refreshTableKeepingPosition];
    [self authorizeNotificationsThen:^{
        self.busy = NO;
        [self changeConfiguration:NSConfigurationEnable];
    }];
}
- (void)appleSystemProcessesChanged:(UISwitch *)sender {
    if (!self.policy || self.busy) {
        return;
    }
    BOOL allow = sender.on;
    [self updatePolicy:^BOOL(NSMutableDictionary *document, NSError **error) {
        document[@"allowAppleSystemProcesses"] = @(allow);
        return YES;
    }];
    [self refreshTableKeepingPosition];
}
- (void)openSupportURL:(NSURL *)url {
    void (^presentOrOpen)(void) = ^{
        if (![NEFilterManager sharedManager].enabled) {
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
            return;
        }
        UIAlertController *notice = [UIAlertController
            alertControllerWithTitle:@"Opening a link with Firewall enabled"
                             message:
                                 @"If the destination app or browser needs network permission, the link may "
                                 @"not load and a banner may not appear. Return to NetShield2, choose Allow "
                                 @"app under Waiting for your decision, then open the link again. If you "
                                 @"previously blocked that app, change its rule under App rules."
                      preferredStyle:UIAlertControllerStyleAlert];
        [notice addAction:[UIAlertAction actionWithTitle:@"Open link"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *action) {
                                                     [UIApplication.sharedApplication openURL:url
                                                                                      options:@{}
                                                                            completionHandler:nil];
                                                 }]];
        [notice addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                   style:UIAlertActionStyleCancel
                                                 handler:nil]];
        [self presentViewController:notice animated:YES completion:nil];
    };
    if (self.presentedViewController) {
        [self dismissViewControllerAnimated:YES completion:presentOrOpen];
    } else {
        presentOrOpen();
    }
}
- (void)supportDeveloper {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Support Developer"
                         message:@"Thank you for supporting EolnMsuk. Choose a donation method."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert
        addAction:[UIAlertAction
                      actionWithTitle:@"Venmo"
                                style:UIAlertActionStyleDefault
                              handler:^(UIAlertAction *action) {
                                  [self openSupportURL:[NSURL
                                                           URLWithString:@"https://venmo.com/u/rustonrails"]];
                              }]];
    [alert addAction:[UIAlertAction
                         actionWithTitle:@"Bitcoin"
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *action) {
                                     UIPasteboard.generalPasteboard.string =
                                         @"31uHLpioo1TbxAmo9kM7rrKcLz3wvcoZaL";
                                     dispatch_async(dispatch_get_main_queue(), ^{
                                         UIAlertController *confirmation = [UIAlertController
                                             alertControllerWithTitle:@"Bitcoin address copied"
                                                              message:@"The Bitcoin wallet address has been "
                                                                      @"copied to your clipboard."
                                                       preferredStyle:UIAlertControllerStyleAlert];
                                         [confirmation addAction:[UIAlertAction
                                                                     actionWithTitle:@"OK"
                                                                               style:UIAlertActionStyleDefault
                                                                             handler:nil]];
                                         [self presentViewController:confirmation
                                                            animated:YES
                                                          completion:nil];
                                     });
                                 }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)showNotificationHelp {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Answer without leaving your app"
                         message:@"Touch and hold a NetShield2 notification, then choose Allow app or Keep "
                                 @"blocking. Tapping the notification body opens NetShield2.\n\nUsing Do Not "
                                 @"Disturb? In Settings > Focus > Do Not Disturb > Apps, allow notifications "
                                 @"from NetShield2. Do the same for any other Focus you use.\n\nUnanswered "
                                 @"requests are blocked after 30 seconds. You can allow them later and retry "
                                 @"the connection."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
