#import <UIKit/UIKit.h>
#include <float.h>
#import <NetworkExtension/NetworkExtension.h>
#import "../Shared/NSStore.h"
#import "../Shared/NSNotifications.h"

@interface NSDashboard : UITableViewController
@property(nonatomic, strong) NSPolicy *policy;
@property(nonatomic, copy) NSDictionary *monitor;
@property(nonatomic, copy) NSArray<NSString *> *identities;
@property(nonatomic, copy) NSString *message;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL loaded;
@property(nonatomic, strong) NSMutableSet<NSString *> *deferredRequests;
@property(nonatomic, copy) NSString *notificationStatus;
- (void)answerRequest:(NSDictionary *)request allow:(BOOL)allow;
- (void)presentRequest:(NSDictionary *)request;
- (void)reloadMonitor;
@end

@implementation NSDashboard
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"NetShield";
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    // Remove only the obsolete notification-test artifact from pre-release builds.
    [UNUserNotificationCenter.currentNotificationCenter removePendingNotificationRequestsWithIdentifiers:@[@"netshield-test"]];
    [UNUserNotificationCenter.currentNotificationCenter removeDeliveredNotificationsWithIdentifiers:@[@"netshield-test"]];
    NSURL *oldTest = NSSharedURL(@"notification-test.plist");
    if (oldTest) [NSFileManager.defaultManager removeItemAtURL:oldTest error:NULL];
    self.deferredRequests = [NSMutableSet new];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(loadConfiguration)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(configurationChanged:) name:NEFilterConfigurationDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(configurationChanged:) name:UIApplicationDidBecomeActiveNotification object:nil];
    NSError *error = nil;
    self.policy = NSReadPolicy(&error);
    if (!self.policy && [error.domain isEqual:NSCocoaErrorDomain] &&
        (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)) {
        if (NSWriteDocument([NSPolicy defaultDocument], @"policy.plist", &error)) self.policy = NSReadPolicy(&error);
    }
    self.message = self.policy ? @"" : error.localizedDescription;
    [self refreshNotificationSettings];
    [self loadConfiguration];
}
- (void)configurationChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{ [self refreshNotificationSettings]; NSWriteDocument(@{@"revision": NSUUID.UUID.UUIDString}, @"notification-retry.plist", NULL); [self loadConfiguration]; });
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.timer invalidate];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) { [weakSelf reloadMonitor]; }];
    [self reloadMonitor];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
}
- (void)reloadMonitor {
    NSPolicy *latest = NSReadPolicy(NULL);
    if (latest) self.policy = latest;
    NSMutableDictionary *monitor = [NSReadMonitor() mutableCopy];
    // The provider clears resolved requests on its next tick. Hide overridden
    // Apple requests immediately so saving the switch cannot reopen a stale prompt.
    NSMutableArray *requests = [NSMutableArray new];
    for (NSDictionary *request in monitor[@"requests"]) {
        if (![self.policy automaticallyAllowsIdentity:request[@"identity"]]) [requests addObject:request];
    }
    monitor[@"requests"] = requests;
    self.monitor = monitor;
    NSMutableSet *identities = [NSMutableSet setWithArray:[self.policy.document[@"rules"] allKeys] ?: @[]];
    for (NSDictionary *event in self.monitor[@"events"]) {
        NSString *identity = event[@"identity"];
        if ([identity isKindOfClass:NSString.class] && identity.length) [identities addObject:identity];
    }
    self.identities = [[identities allObjects] sortedArrayUsingSelector:@selector(compare:)];
    NSSet *tokens = [NSSet setWithArray:[self.monitor[@"requests"] valueForKey:@"token"] ?: @[]];
    [self.deferredRequests intersectSet:tokens];
    [self.tableView reloadData];
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
        !self.busy && !self.presentedViewController && self.loaded && [NEFilterManager sharedManager].enabled && [self hasFreshMonitor]) {
        for (NSDictionary *request in self.monitor[@"requests"]) {
            if (![self.deferredRequests containsObject:request[@"token"]]) { [self presentRequest:request]; break; }
        }
    }
}
- (BOOL)hasFreshMonitor {
    NSDate *updated = self.monitor[@"updated"];
    NSTimeInterval age = [updated isKindOfClass:NSDate.class] ? -updated.timeIntervalSinceNow : DBL_MAX;
    return age >= 0 && age < 8 && [self.monitor[@"controlRunning"] boolValue];
}
- (void)refreshNotificationSettings {
    [UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.notificationStatus = settings.authorizationStatus == UNAuthorizationStatusAuthorized && settings.alertSetting == UNNotificationSettingEnabled
                ? @"Banners enabled. Tap to change notification settings."
                : @"Enable notifications and banners to answer requests in other apps.";
            [self.tableView reloadData];
        });
    }];
}
- (void)authorizeNotificationsThen:(void (^)(void))completion {
    NSRegisterPermissionActions();
    [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound completionHandler:^(BOOL granted, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshNotificationSettings];
            if (error) [self showError:error operation:@"Notification authorization"];
            else if (!granted) self.message = @"Notifications are off. Enable Allow Notifications and Banners in notification settings.";
            // Re-attempt existing requests after a permission change, without restarting the filter.
            NSWriteDocument(@{@"revision": NSUUID.UUID.UUIDString}, @"notification-retry.plist", NULL);
            if (completion) completion();
        });
    }];
}
- (void)requestNotifications {
    [UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (settings.authorizationStatus == UNAuthorizationStatusNotDetermined) [self authorizeNotificationsThen:nil];
            else [UIApplication.sharedApplication openURL:[NSURL URLWithString:UIApplicationOpenNotificationSettingsURLString] options:@{} completionHandler:nil];
        });
    }];
}
- (void)copyNotificationDiagnostics {
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        [center getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> *pending) {
            [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *delivered) {
                NSUInteger pendingPermissions = 0, deliveredPermissions = 0;
                for (UNNotificationRequest *item in pending) if ([item.content.categoryIdentifier isEqual:NSPermissionCategory]) pendingPermissions++;
                for (UNNotification *item in delivered) if ([item.request.content.categoryIdentifier isEqual:NSPermissionCategory]) deliveredPermissions++;
                NSDictionary *monitor = NSReadMonitor();
                NSString *report = [NSString stringWithFormat:@"NetShield 2.0.0 notification diagnostics\nTime: %@\nAuthorization (0=not asked,1=denied,2=authorized,3=provisional): %ld\nSettings (0=unsupported,1=disabled,2=enabled): alerts=%ld sound=%ld center=%ld lockscreen=%ld summary=%ld\nAlert style (0=none,1=banner,2=alert): %ld\nPermission notifications pending=%lu delivered=%lu\nControl build: %@\nControl running: %@; updated: %@\nPending flow identities: %lu\nProvider notification result: %@\nPolicy error: %@\nDelivered means present in Notification Center, not proof of a visible banner.",
                    NSDate.date, (long)settings.authorizationStatus, (long)settings.alertSetting, (long)settings.soundSetting,
                    (long)settings.notificationCenterSetting, (long)settings.lockScreenSetting, (long)settings.scheduledDeliverySetting,
                    (long)settings.alertStyle, (unsigned long)pendingPermissions, (unsigned long)deliveredPermissions, monitor[@"engine"] ?: @"unknown",
                    monitor[@"controlRunning"] ?: @NO, monitor[@"updated"] ?: @"none", (unsigned long)[monitor[@"requests"] count],
                    monitor[@"notificationError"] ?: @"No submission recorded", monitor[@"policyError"] ?: @""];
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIPasteboard.generalPasteboard.string = report;
                    self.message = @"Notification diagnostics copied. Paste them into the support conversation. No app identities or destinations are included.";
                    [self.tableView reloadData];
                });
            }];
        }];
    }];
}
- (void)answerRequest:(NSDictionary *)request allow:(BOOL)allow {
    NSError *error = nil;
    if (!NSAnswerPermissionRequest(request, allow, &error)) [self showError:error];
    else self.message = @"Rule saved. Retry the requesting app if its connection timed out.";
    [self reloadMonitor];
}
- (void)presentRequest:(NSDictionary *)request {
    if (self.presentedViewController) return;
    [self.deferredRequests addObject:request[@"token"]];
    NSString *message = [NSString stringWithFormat:@"%@\n\nSave a rule for this app's incoming and outgoing connections. Unanswered connections are blocked after 30 seconds; retry the app if it has already timed out.", request[@"identity"]];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Allow network access?" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Allow app" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self answerRequest:request allow:YES]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Block app" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { [self answerRequest:request allow:NO]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Not now" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)showError:(NSError *)error {
    [self showError:error operation:@"Policy/storage"];
}
- (void)showError:(NSError *)error operation:(NSString *)operation {
    self.message = [NSString stringWithFormat:@"%@: %@ (%@ %ld).", operation, error.localizedDescription, error.domain, (long)error.code];
    [self.tableView reloadData];
}
- (void)loadConfiguration {
    if (self.busy) return;
    self.busy = YES;
    [[NEFilterManager sharedManager] loadFromPreferencesWithCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.loaded = error == nil;
            if (error) [self showError:error operation:@"Load filter configuration"];
            [self reloadMonitor];
        });
    }];
}
- (void)changeConfiguration:(NSInteger)operation {
    if (self.busy) return;
    NSError *policyError = nil;
    if (operation == 1 && !NSReadPolicy(&policyError)) { [self showError:policyError]; return; }
    self.busy = YES;
    NEFilterManager *manager = [NEFilterManager sharedManager];
    [manager loadFromPreferencesWithCompletionHandler:^(NSError *loadError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (loadError) {
                self.busy = NO;
                self.loaded = NO;
                [self showError:loadError operation:@"Load before configuration change"];
                return;
            }
            void (^finished)(NSError *) = ^(NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.busy = NO;
                    if (error) [self showError:error operation:operation == 2 ? @"Remove filter configuration" : (operation == 1 ? @"Save enabled filter" : @"Save disabled filter")];
                    else self.message = operation == 1 ? @"" : operation == 2 ? @"System filter removed. You can now uninstall NetShield." : @"Firewall is off. Your rules are saved.";
                    [self loadConfiguration];
                });
            };
            if (operation == 2) { [manager removeFromPreferencesWithCompletionHandler:finished]; return; }
            void (^saveRequestedState)(void) = ^{
                if (operation == 1) {
                    NEFilterProviderConfiguration *configuration = [NEFilterProviderConfiguration new];
                    configuration.filterSockets = YES;
                    configuration.filterBrowsers = YES;
                    configuration.organization = @"NetShield";
                    configuration.vendorConfiguration = @{@"schema": @2, @"engine": @20010};
                    manager.providerConfiguration = configuration;
                    manager.localizedDescription = @"NetShield network access control";
                }
                manager.enabled = operation == 1;
                [manager saveToPreferencesWithCompletionHandler:finished];
            };
            if (operation == 1 && manager.enabled) {
                // Restart through NE so an upgrade does not keep the old provider
                // instance alive while the new app writes an Ask policy.
                manager.enabled = NO;
                [manager saveToPreferencesWithCompletionHandler:^(NSError *disableError) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (disableError) {
                            self.busy = NO;
                            [self showError:disableError operation:@"Stop filter before restart"];
                            [self loadConfiguration];
                            return;
                        }
                        [manager loadFromPreferencesWithCompletionHandler:^(NSError *reloadError) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (reloadError) {
                                    self.busy = NO;
                                    self.loaded = NO;
                                    [self showError:reloadError operation:@"Reload filter before restart"];
                                    return;
                                }
                                saveRequestedState();
                            });
                        }];
                    });
                }];
            } else saveRequestedState();
        });
    }];
}
- (void)finishResetWhenStopped:(NSUInteger)attempt {
    NSDictionary *monitor = NSReadMonitor();
    NSDate *updated = monitor[@"updated"];
    BOOL recent = updated && updated.timeIntervalSinceNow <= 0 && updated.timeIntervalSinceNow > -8;
    if ([monitor[@"controlRunning"] boolValue] && recent) {
        if (attempt >= 60) {
            self.busy = NO;
            self.message = @"Filter removal finished, but the provider is still running. Reset stopped without deleting rules. Try again after it stops.";
            [self loadConfiguration];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{ [self finishResetWhenStopped:attempt + 1]; });
        return;
    }
    NSError *error = nil;
    if (!NSWriteDocument([NSPolicy defaultDocument], @"policy.plist", &error)) {
        self.busy = NO; [self showError:error]; return;
    }
    for (NSString *name in @[@"monitor.plist", @"notification-retry.plist", @"notification-test.plist"]) {
        NSURL *url = NSSharedURL(name);
        if (url && [NSFileManager.defaultManager fileExistsAtPath:url.path] && ![NSFileManager.defaultManager removeItemAtURL:url error:&error]) {
            self.busy = NO; [self showError:error operation:@"Reset shared state"]; return;
        }
    }
    [UNUserNotificationCenter.currentNotificationCenter removeAllPendingNotificationRequests];
    [UNUserNotificationCenter.currentNotificationCenter removeAllDeliveredNotifications];
    [self.deferredRequests removeAllObjects];
    self.policy = NSReadPolicy(NULL);
    self.monitor = @{};
    self.identities = @[];
    self.loaded = YES;
    self.busy = NO;
    self.message = @"Defaults restored. Turn on Firewall when you are ready. Notification settings are kept.";
    [self.tableView reloadData];
    [self loadConfiguration];
}
- (void)resetNetShield {
    if (self.busy) return;
    self.busy = YES;
    self.message = @"Removing filter configuration before resetting NetShield...";
    [self.tableView reloadData];
    NEFilterManager *manager = NEFilterManager.sharedManager;
    [manager loadFromPreferencesWithCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) { self.busy = NO; [self showError:error operation:@"Load before reset"]; return; }
            if (!manager.providerConfiguration) { [self finishResetWhenStopped:0]; return; }
            [manager removeFromPreferencesWithCompletionHandler:^(NSError *removeError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (removeError) { self.busy = NO; [self showError:removeError operation:@"Remove before reset"]; return; }
                    [self finishResetWhenStopped:0];
                });
            }];
        });
    }];
}
- (void)savePolicy:(NSMutableDictionary *)document {
    document[@"revision"] = NSUUID.UUID.UUIDString;
    NSError *error = nil;
    NSPolicy *policy = [NSPolicy policyWithDocument:document error:&error];
    if (!policy || !NSWriteDocument(policy.document, @"policy.plist", &error)) { [self showError:error]; return; }
    self.policy = policy;
    self.message = @"Policy saved for new flows. Close existing connections and retry; admitted flows keep their previous verdict.";
    [self reloadMonitor];
}
- (void)chooseActionForIdentity:(NSString *)identity defaultKey:(NSString *)key {
    if (!self.policy) return;
    NSString *title = key ? ([key isEqual:@"default"] ? @"New apps" : @"Unidentified connections") : identity;
    NSString *explanation = [key isEqual:@"default"] ? @"Choose what happens when an app without a saved rule connects. Ask me lets you decide from a notification." : [key isEqual:@"unattributed"] ? @"These connections have no app identity from iOS. Allow is recommended to avoid interrupting system services." : @"Choose a rule for new connections. Incoming/outgoing describes who starts the connection, not downloads or reply traffic.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:explanation preferredStyle:UIAlertControllerStyleAlert];
    NSArray *actions = key ? ([key isEqual:@"default"] ? @[@"ask", @"allow", @"block"] : @[@"allow", @"block"]) : @[@"allow", @"block", @"block-inbound", @"block-outbound", @"use-default"];
    for (NSString *action in actions) {
        [alert addAction:[UIAlertAction actionWithTitle:[self ruleTitle:action] style:UIAlertActionStyleDefault handler:^(UIAlertAction *selected) {
            NSMutableDictionary *document = [self.policy.document mutableCopy];
            if (key) document[key] = action;
            else {
                NSMutableDictionary *rules = [document[@"rules"] mutableCopy];
                if ([action isEqual:@"use-default"]) [rules removeObjectForKey:identity];
                else rules[identity] = action;
                document[@"rules"] = rules;
            }
            [self savePolicy:document];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)addIdentity {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Exact OS identity" message:@"Prefer selecting an identity observed below. This value is sourceAppIdentifier from Network Extension; it may differ from the app's bundle identifier." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Exact sourceAppIdentifier";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Choose rule" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *identity = alert.textFields.firstObject.text;
        if (identity.length) dispatch_async(dispatch_get_main_queue(), ^{ [self chooseActionForIdentity:identity defaultKey:nil]; });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (NSString *)ruleTitle:(NSString *)rule {
    return @{@"ask": @"Ask me", @"allow": @"Allow", @"block": @"Block", @"block-inbound": @"Block incoming connections", @"block-outbound": @"Block outgoing connections", @"use-default": @"Use new-app setting"}[rule ?: @""] ?: @"Use new-app setting";
}
- (void)firewallChanged:(UISwitch *)sender {
    if (self.busy) return;
    if (!sender.on) { [self changeConfiguration:0]; return; }
    self.busy = YES;
    [self.tableView reloadData];
    [self authorizeNotificationsThen:^{ self.busy = NO; [self changeConfiguration:1]; }];
}
- (void)appleSystemProcessesChanged:(UISwitch *)sender {
    if (!self.policy || self.busy) return;
    NSMutableDictionary *document = [self.policy.document mutableCopy];
    document[@"allowAppleSystemProcesses"] = @(sender.on);
    [self savePolicy:document];
    [self.tableView reloadData];
}
- (void)showNotificationHelp {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Answer without leaving your app" message:@"Touch and hold a NetShield notification, then choose Allow app or Keep blocking. Tapping the notification body opens NetShield.\n\nUsing Do Not Disturb? In Settings > Focus > Do Not Disturb > Apps, allow notifications from NetShield. Do the same for any other Focus you use.\n\nUnanswered requests are blocked after 30 seconds. You can allow them later and retry the connection." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 6; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 4;
    if (section == 1) return MAX((NSUInteger)1, [self.monitor[@"requests"] count]);
    if (section == 4) return MAX((NSUInteger)1, self.identities.count);
    if (section == 2) return 2;
    if (section == 3) return 8;
    return MAX((NSUInteger)1, MIN((NSUInteger)20, [self.monitor[@"events"] count]));
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"Firewall", @"Waiting for your decision", @"Notifications", @"Advanced & support", @"App rules", @"Recent activity"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"Your rules are kept when you turn the firewall off. Ask me prompts only for apps without a saved rule.";
    if (section == 1) return @"Unanswered requests are blocked after 30 seconds. Allow an app here, then retry if its connection timed out.";
    if (section == 4) return @"Tap an app identity to change its rule. Changes affect new connections; close and reopen the app to end existing connections.";
    if (section == 2) return @"Do Not Disturb silences banners unless you allow NetShield in Settings > Focus > Do Not Disturb > Apps.";
    if (section == 5) return @"Latest 20 of up to 300 recorded events. Data totals arrive when a connection closes; permission decisions show no data totals.";
    return @"NetShield 2.0.0 / iOS 16 rootless. Filters connections provided by iOS; system-exempt traffic is not guaranteed covered.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (path.section == 0 && path.row == 0) {
        cell.textLabel.text = @"Firewall";
        cell.detailTextLabel.text = @"Control internet access for your apps";
        cell.imageView.image = [UIImage systemImageNamed:@"shield.lefthalf.filled"];
        UISwitch *toggle = [UISwitch new];
        toggle.on = self.loaded && NEFilterManager.sharedManager.enabled;
        toggle.enabled = self.loaded && !self.busy;
        toggle.accessibilityLabel = @"Firewall";
        [toggle addTarget:self action:@selector(firewallChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == 0 && path.row == 1) {
        BOOL enabled = self.loaded && NEFilterManager.sharedManager.enabled;
        BOOL healthy = enabled && [self hasFreshMonitor] && ![self.monitor[@"policyError"] length];
        cell.textLabel.text = self.busy ? @"Updating..." : !self.loaded ? @"Unable to read firewall status" : !enabled ? @"Off" : healthy ? @"Active" : @"Needs attention";
        cell.textLabel.textColor = healthy ? UIColor.systemGreenColor : UIColor.labelColor;
        NSString *detail = !enabled ? @"Turn on Firewall to apply your rules." : healthy ? @"Your rules are being applied to new connections." : @"The filter has not reported a healthy status. Turn Firewall off and on; copy diagnostics if this continues.";
        if ([self.monitor[@"policyError"] length]) detail = self.monitor[@"policyError"];
        cell.detailTextLabel.text = [self.message length] ? [NSString stringWithFormat:@"%@\n%@", detail, self.message] : detail;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == 0 && path.row == 3) {
        cell.textLabel.text = @"Allow all iOS system processes";
        cell.detailTextLabel.text = @"Allow identities starting with com.apple. or .com.apple. Saved rules are ignored until this is off.";
        UISwitch *toggle = [UISwitch new];
        toggle.on = [self.policy.document[@"allowAppleSystemProcesses"] boolValue];
        toggle.enabled = self.policy != nil && !self.busy;
        toggle.accessibilityLabel = cell.textLabel.text;
        [toggle addTarget:self action:@selector(appleSystemProcessesChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == 0) {
        cell.textLabel.text = @"New apps";
        cell.detailTextLabel.text = [self ruleTitle:self.policy.document[@"default"]];
    } else if (path.section == 1) {
        NSArray *requests = self.monitor[@"requests"];
        if (!requests.count) { cell.textLabel.text = @"No apps waiting"; cell.accessoryType = UITableViewCellAccessoryNone; }
        else {
            NSDictionary *request = requests[path.row];
            cell.textLabel.text = request[@"identity"];
            cell.detailTextLabel.text = [request[@"expired"] boolValue] ? @"Blocked while waiting. Tap to decide." : @"Tap to allow or keep blocking";
        }
    } else if (path.section == 4) {
        if (!self.identities.count) { cell.textLabel.text = @"Apps appear here when they connect"; cell.accessoryType = UITableViewCellAccessoryNone; }
        else { NSString *identity = self.identities[path.row]; cell.textLabel.text = identity; cell.detailTextLabel.text = [self.policy automaticallyAllowsIdentity:identity] ? [NSString stringWithFormat:@"Allowed by iOS system processes setting. Saved rule: %@", [self ruleTitle:self.policy.document[@"rules"][identity]]] : [self ruleTitle:self.policy.document[@"rules"][identity]]; }
    } else if (path.section == 2) {
        cell.textLabel.text = path.row == 0 ? @"Notification settings" : @"Banners & Do Not Disturb";
        cell.detailTextLabel.text = path.row == 0 ? self.notificationStatus : @"How to answer while using another app";
    } else if (path.section == 5) {
        NSArray *events = self.monitor[@"events"];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (!events.count) cell.textLabel.text = @"No activity yet";
        else {
            NSDictionary *event = events[events.count - 1 - path.row];
            NSString *action = @{@"allow": @"Allowed", @"block": @"Blocked", @"permission-allow": @"Allowed by rule", @"permission-block": @"Blocked"}[event[@"action"]] ?: @"Connection";
            cell.textLabel.text = [NSString stringWithFormat:@"%@ / %@", action, [event[@"identity"] length] ? event[@"identity"] : @"Unidentified app"];
            NSString *time = [NSDateFormatter localizedStringFromDate:event[@"time"] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ / %@\nReceived %@ B / Sent %@ B", time, event[@"direction"], event[@"bytesIn"], event[@"bytesOut"]];
        }
    } else {
        cell.textLabel.text = @[@"Unidentified connections", @"Add a rule by app identity", @"Copy notification diagnostics", @"Reset NetShield...", @"Prepare for uninstall...", @"GitHub Link", @"Support the Dev - Venmo", @"Support the Dev - BTC"][path.row];
        cell.detailTextLabel.text = @[[self ruleTitle:self.policy.document[@"unattributed"]], @"For an exact identity supplied by iOS", @"Copy technical details for support", @"Clear rules and history; leave the firewall off", @"Remove the system filter before deleting NetShield", @"Source code, releases and issues", @"Donate with Venmo", @"View the Bitcoin donation address"][path.row];
        if (path.row == 3 || path.row == 4) cell.textLabel.textColor = UIColor.systemRedColor;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (self.busy) return;
    if (path.section == 0 && path.row == 2) [self chooseActionForIdentity:nil defaultKey:@"default"];
    else if (path.section == 1 && [self.monitor[@"requests"] count]) [self presentRequest:self.monitor[@"requests"][path.row]];
    else if (path.section == 4 && self.identities.count) [self chooseActionForIdentity:self.identities[path.row] defaultKey:nil];
    else if (path.section == 2) { if (path.row == 0) [self requestNotifications]; else [self showNotificationHelp]; }
    else if (path.section == 3) {
        if (path.row == 0) [self chooseActionForIdentity:nil defaultKey:@"unattributed"];
        else if (path.row == 1) [self addIdentity];
        else if (path.row == 2) [self copyNotificationDiagnostics];
        else if (path.row >= 5) {
            NSString *url = @[@"https://github.com/EolnMsuk/NetShield2/", @"https://venmo.com/u/rustonrails", @"https://www.blockchain.com/explorer/addresses/btc/31uHLpioo1TbxAmo9kM7rrKcLz3wvcoZaL"][path.row - 5];
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:url] options:@{} completionHandler:nil];
        } else {
            BOOL reset = path.row == 3;
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:reset ? @"Reset NetShield?" : @"Prepare for uninstall?" message:reset ? @"Deletes app rules, pending requests and history. Restores Ask me for new apps, allows unidentified connections and leaves Firewall off. iOS notification settings are kept." : @"Removes NetShield's system filter and stops filtering. After this succeeds, uninstall NetShield in your package manager." preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:reset ? @"Reset" : @"Remove system filter" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { if (reset) [self resetNetShield]; else [self changeConfiguration:2]; }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }
}

@end

@interface NSAppDelegate : UIResponder <UIApplicationDelegate, UNUserNotificationCenterDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) NSDashboard *dashboard;
@end
@implementation NSAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    NSRegisterPermissionActions();
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    if (application.applicationState != UIApplicationStateBackground) [self createInterface];
    return YES;
}
- (void)createInterface {
    if (self.window) return;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.dashboard = [[NSDashboard alloc] initWithStyle:UITableViewStyleInsetGrouped];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:self.dashboard];
    [self.window makeKeyAndVisible];
}
- (void)applicationDidBecomeActive:(UIApplication *)application {
    [self createInterface];
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification
        withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    // The foreground inbox handles permission requests.
    dispatch_async(dispatch_get_main_queue(), ^{ [self.dashboard reloadMonitor]; completionHandler(UNNotificationPresentationOptionNone); });
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response
        withCompletionHandler:(void (^)(void))completionHandler {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *request = response.notification.request.content.userInfo;
        if ([response.notification.request.content.categoryIdentifier isEqual:NSPermissionCategory] &&
            [request[@"token"] isKindOfClass:NSString.class] && [request[@"identity"] isKindOfClass:NSString.class]) {
            if ([response.actionIdentifier isEqual:NSAllowAction] || [response.actionIdentifier isEqual:NSBlockAction]) {
                NSError *error = nil;
                BOOL saved = NSAnswerPermissionRequest(request, [response.actionIdentifier isEqual:NSAllowAction], &error);
                if (!saved) {
                    UNMutableNotificationContent *failure = [UNMutableNotificationContent new];
                    failure.title = @"NetShield decision not saved";
                    failure.body = error.localizedDescription ?: @"Open NetShield to review the request.";
                    [center addNotificationRequest:[UNNotificationRequest requestWithIdentifier:@"netshield-action-error" content:failure trigger:nil] withCompletionHandler:nil];
                }
                if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) [self.dashboard reloadMonitor];
            } else [self.dashboard reloadMonitor];
        }
        completionHandler();
    });
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(NSAppDelegate.class)); }
}
