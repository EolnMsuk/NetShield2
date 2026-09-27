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
    self.message = self.policy ? @"Choose Ask for apps without a rule to receive permission requests." : error.localizedDescription;
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
    self.monitor = NSReadMonitor();
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
            self.notificationStatus = [NSString stringWithFormat:@"Authorization: %@; alerts: %@. Tap for settings. Long-press banners for Allow / Keep blocking.",
                settings.authorizationStatus == UNAuthorizationStatusAuthorized ? @"allowed" :
                settings.authorizationStatus == UNAuthorizationStatusDenied ? @"denied" :
                settings.authorizationStatus == UNAuthorizationStatusNotDetermined ? @"not requested" : @"quiet/provisional",
                settings.alertSetting == UNNotificationSettingEnabled ? @"on" : @"off"];
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
- (void)testNotification {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = @"NetShield notification test";
    content.body = @"If you can see this, the app notification reached you. This test does not change firewall rules.";
    content.sound = UNNotificationSound.defaultSound;
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"netshield-test" content:content
        trigger:[UNTimeIntervalNotificationTrigger triggerWithTimeInterval:5 repeats:NO]];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) [self showError:error operation:@"Test notification"];
            else self.message = @"Test scheduled: go to the Home Screen and wait 10 seconds. No internet access is needed. Then use Copy notification diagnostics.";
            NSWriteDocument(@{@"scheduled": NSDate.date, @"result": error ? [NSString stringWithFormat:@"%@ (%@ %ld)", error.localizedDescription, error.domain, (long)error.code] : @"Scheduling accepted; delivery not confirmed"}, @"notification-test.plist", NULL);
            [self.tableView reloadData];
        });
    }];
}
- (void)copyNotificationDiagnostics {
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        [center getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> *pending) {
            [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *delivered) {
                BOOL pendingTest = NO, deliveredTest = NO;
                for (UNNotificationRequest *item in pending) if ([item.identifier isEqual:@"netshield-test"]) pendingTest = YES;
                for (UNNotification *item in delivered) if ([item.request.identifier isEqual:@"netshield-test"]) deliveredTest = YES;
                NSDictionary *monitor = NSReadMonitor();
                NSString *report = [NSString stringWithFormat:@"NetShield build 20006 notification diagnostics\nTime: %@\nAuthorization (0=not asked,1=denied,2=authorized,3=provisional): %ld\nSettings (0=unsupported,1=disabled,2=enabled): alerts=%ld sound=%ld center=%ld lockscreen=%ld summary=%ld\nAlert style (0=none,1=banner,2=alert): %ld\nApp test pending=%@ delivered=%@\nLast test: %@\nControl build: %@\nControl running: %@; updated: %@\nPending flow identities: %lu\nProvider notification result: %@\nPolicy error: %@\nDelivered means present in Notification Center, not proof of a visible banner.",
                    NSDate.date, (long)settings.authorizationStatus, (long)settings.alertSetting, (long)settings.soundSetting,
                    (long)settings.notificationCenterSetting, (long)settings.lockScreenSetting, (long)settings.scheduledDeliverySetting,
                    (long)settings.alertStyle, pendingTest ? @"yes" : @"no", deliveredTest ? @"yes" : @"no",
                    NSReadDocument(@"notification-test.plist", NULL) ?: @{}, monitor[@"engine"] ?: @"unknown",
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
                    else self.message = operation == 1 ? @"Filter enabled. Waiting for provider activity." : @"Filter disabled or removed.";
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
                    configuration.vendorConfiguration = @{@"schema": @2, @"engine": @20006};
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
    self.message = @"NetShield reset. Rules and history cleared. Restarting permission setup; iOS notification settings are retained.";
    [self.tableView reloadData];
    [self startPermissionPrompts];
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
    NSString *title = key ? ([key isEqual:@"default"] ? @"Apps without a rule" : @"Unattributed flows") : identity;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:@"Inbound/outbound refer to the initial flow direction, not reply packets. Changes apply to new flows." preferredStyle:UIAlertControllerStyleAlert];
    NSArray *actions = key ? ([key isEqual:@"default"] ? @[@"ask", @"allow", @"block"] : @[@"allow", @"block"]) : @[@"allow", @"block", @"block-inbound", @"block-outbound", @"use-default"];
    for (NSString *action in actions) {
        [alert addAction:[UIAlertAction actionWithTitle:action style:UIAlertActionStyleDefault handler:^(UIAlertAction *selected) {
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
- (void)startPermissionPrompts {
    NSError *error = nil;
    NSPolicy *policy = NSReadPolicy(&error);
    if (!policy) { [self showError:error]; return; }
    NSMutableDictionary *document = [policy.document mutableCopy];
    document[@"default"] = @"ask";
    document[@"revision"] = NSUUID.UUID.UUIDString;
    if (!NSWriteDocument(document, @"policy.plist", &error)) { [self showError:error]; return; }
    self.policy = [NSPolicy policyWithDocument:document error:NULL];
    [self authorizeNotificationsThen:^{ [self changeConfiguration:1]; }];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 6; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return 4;
    if (section == 2) return MAX((NSUInteger)1, [self.monitor[@"requests"] count]);
    if (section == 3) return 9;
    if (section == 4) return MAX((NSUInteger)1, self.identities.count);
    return MAX((NSUInteger)1, [self.monitor[@"events"] count]);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"Status", @"Controls", @"Permission requests", @"Rules", @"Apps and OS identities", @"Recent activity"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"NetShield filters connections delivered by iOS. System-exempt traffic and traffic before the filter starts are not guaranteed covered.";
    if (section == 2) return @"Allow or block an app once to save its rule. Unanswered connections are blocked after a 30-second deadline; expired requests remain here so you can allow the app and retry.";
    if (section == 3) return @"Ask prompts for apps without a rule. Unattributed traffic uses its own policy. Existing allowed connections keep their verdict until closed.";
    if (section == 4) return @"These are the identities iOS supplies. Tap one to change its rule. Shared system services may have no app identity.";
    if (section == 5) return @"Latest 300 events. Byte totals appear at flow close. Permission decisions are also listed. No payloads or destinations are stored.";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    if (path.section == 0) {
        BOOL enabled = self.loaded && [NEFilterManager sharedManager].enabled;
        BOOL fresh = [self hasFreshMonitor];
        NSDate *last = self.monitor[@"lastReport"];
        BOOL observed = [last isKindOfClass:NSDate.class] && last.timeIntervalSince1970 > 0;
        BOOL recentActivity = observed && last.timeIntervalSinceNow <= 0 && -last.timeIntervalSinceNow < 30;
        NSString *state = !self.loaded ? @"Unable to read filter state" : !enabled ? @"Filter off" : !fresh ? @"Filter unavailable: no current heartbeat" : !recentActivity ? @"Filter enabled: no recent traffic" : @"Filtering active";
        if (enabled && [self.monitor[@"policyError"] length]) state = @"Policy error: new flows are blocked";
        cell.textLabel.text = state;
        cell.textLabel.textColor = [state isEqual:@"Filtering active"] ? UIColor.systemGreenColor : UIColor.labelColor;
        NSString *time = observed ? [NSDateFormatter localizedStringFromDate:last dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle] : @"None yet";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"Last OS activity: %@\nControl build: %@ (expected 20006)\n%@\n%@\n%@", time, self.monitor[@"engine"] ?: @"older version",
            [self.message isEqual:@"Filter enabled. Waiting for provider activity."] && fresh && observed ? @"Rules are being applied to new connections." : (self.message ?: @""),
            self.monitor[@"policyError"] ?: @"", self.monitor[@"notificationError"] ?: @""];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == 1) {
        cell.textLabel.text = @[@"Start permission prompts", @"Enable filter with current rules", @"Disable filter", @"Remove filter configuration"][path.row];
        cell.textLabel.textColor = self.busy ? UIColor.secondaryLabelColor : self.view.tintColor;
    } else if (path.section == 2) {
        NSArray *requests = self.monitor[@"requests"];
        if (!requests.count) cell.textLabel.text = @"No apps waiting for permission";
        else {
            NSDictionary *request = requests[path.row];
            cell.textLabel.text = request[@"identity"];
            cell.detailTextLabel.text = [request[@"expired"] boolValue] ? @"Timed out and blocked: tap to save a rule, then retry the app" :
                [NSString stringWithFormat:@"%@ connection(s) waiting: tap Allow or Block", request[@"waiting"]];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (path.section == 3) {
        cell.textLabel.text = @[@"Apps without a rule", @"Unattributed flows", @"Notification permission", @"Add exact app identity...", @"Reset rules...", @"Test notification (5 seconds)", @"Retry pending notifications", @"Reset NetShield and restart setup...", @"Copy notification diagnostics"][path.row];
        if (path.row < 2) cell.detailTextLabel.text = self.policy.document[path.row ? @"unattributed" : @"default"] ?: @"Policy unavailable";
        if (path.row == 2) cell.detailTextLabel.text = self.notificationStatus ?: @"Tap to enable permission notifications";
    } else if (path.section == 4) {
        if (!self.identities.count) cell.textLabel.text = @"No app identities observed yet";
        else {
            NSString *identity = self.identities[path.row];
            cell.textLabel.text = identity;
            cell.detailTextLabel.text = self.policy.document[@"rules"][identity] ?: @"Uses default";
        }
    } else {
        NSArray *events = self.monitor[@"events"];
        if (!events.count) cell.textLabel.text = @"No flow reports received";
        else {
            NSDictionary *event = events[events.count - 1 - path.row];
            cell.textLabel.text = [NSString stringWithFormat:@"%@: %@", event[@"action"], [event[@"identity"] length] ? event[@"identity"] : @"Unattributed"];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ / %@\nIn %@ B / Out %@ B", event[@"time"], event[@"direction"], event[@"bytesIn"], event[@"bytesOut"]];
        }
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (self.busy) return;
    if (path.section == 1 && !self.busy) {
        if (path.row >= 2) { [self changeConfiguration:path.row == 2 ? 0 : 2]; return; }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Enable NetShield?" message:@"This starts or restarts NetShield and may disable another app's content filter. Existing saved app rules will be kept." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Enable" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            if (path.row == 0) [self startPermissionPrompts]; else [self changeConfiguration:1];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else if (path.section == 2 && [self.monitor[@"requests"] count]) {
        [self presentRequest:self.monitor[@"requests"][path.row]];
    } else if (path.section == 3) {
        if (path.row < 2) [self chooseActionForIdentity:nil defaultKey:path.row ? @"unattributed" : @"default"];
        else if (path.row == 2) [self requestNotifications];
        else if (path.row == 3) [self addIdentity];
        else if (path.row == 8) [self copyNotificationDiagnostics];
        else if (path.row == 7) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset NetShield?" message:@"Removes the filter configuration, all app rules, pending requests and activity history, then starts Ask setup again. Filtering is off during reset. iOS notification authorization is retained; this cannot force a new system permission dialog." preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Reset and restart setup" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { [self resetNetShield]; }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
        else if (path.row == 5) [self testNotification];
        else if (path.row == 6) { NSWriteDocument(@{@"revision": NSUUID.UUID.UUIDString}, @"notification-retry.plist", NULL); self.message = @"Requested notification retry. Check Status for provider results."; [self reloadMonitor]; }
        else {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset all rules?" message:@"Removes saved app decisions, asks for unknown apps and allows unattributed traffic. Does not enable or disable the filter." preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { [self savePolicy:[[NSPolicy defaultDocument] mutableCopy]]; }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    } else if (path.section == 4 && self.identities.count) [self chooseActionForIdentity:self.identities[path.row] defaultKey:nil];
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
    // The foreground inbox handles requests; the delivery test should still be visible.
    dispatch_async(dispatch_get_main_queue(), ^{ [self.dashboard reloadMonitor]; completionHandler([notification.request.identifier isEqual:@"netshield-test"] ? UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound : UNNotificationPresentationOptionNone); });
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
