#import <UIKit/UIKit.h>
#include <float.h>
#import <NetworkExtension/NetworkExtension.h>
#import "../Shared/NSStore.h"

@interface NSDashboard : UITableViewController
@property(nonatomic, strong) NSPolicy *policy;
@property(nonatomic, copy) NSDictionary *monitor;
@property(nonatomic, copy) NSArray<NSString *> *identities;
@property(nonatomic, copy) NSString *message;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL loaded;
@end

@implementation NSDashboard
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"NetShield 2 · Alpha 2";
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
    self.message = self.policy ? @"Filter is off until you enable it. Device deployment has not been validated." : error.localizedDescription;
    [self loadConfiguration];
}
- (void)configurationChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{ [self loadConfiguration]; });
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
    self.monitor = NSReadMonitor();
    NSMutableSet *identities = [NSMutableSet setWithArray:[self.policy.document[@"rules"] allKeys] ?: @[]];
    for (NSDictionary *event in self.monitor[@"events"]) {
        NSString *identity = event[@"identity"];
        if ([identity isKindOfClass:NSString.class] && identity.length) [identities addObject:identity];
    }
    self.identities = [[identities allObjects] sortedArrayUsingSelector:@selector(compare:)];
    [self.tableView reloadData];
}
- (void)showError:(NSError *)error {
    [self showError:error operation:@"Policy/storage"];
}
- (void)showError:(NSError *)error operation:(NSString *)operation {
    self.message = [NSString stringWithFormat:@"%@: %@ (%@ %ld). Activation and coverage are unverified.", operation, error.localizedDescription, error.domain, (long)error.code];
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
                    else self.message = operation == 1 ? @"Enable request saved. This does not prove the providers started or that all traffic is covered. Generate new traffic and inspect reports below." : @"Disable/remove request saved. Verify network access before uninstalling.";
                    [self loadConfiguration];
                });
            };
            if (operation == 2) { [manager removeFromPreferencesWithCompletionHandler:finished]; return; }
            if (operation == 1) {
                NEFilterProviderConfiguration *configuration = [NEFilterProviderConfiguration new];
                configuration.filterSockets = YES;
                configuration.filterBrowsers = YES;
                configuration.organization = @"NetShield";
                configuration.vendorConfiguration = @{@"schema": @2};
                // iOS locates the embedded providers. Bundle-ID setters and the
                // packet-filter switch are macOS-only APIs; do not use them here.
                manager.providerConfiguration = configuration;
                manager.localizedDescription = @"NetShield experimental flow filter";
            }
            manager.enabled = operation == 1;
            [manager saveToPreferencesWithCompletionHandler:finished];
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
    NSArray *actions = key ? @[@"allow", @"block"] : @[@"allow", @"block", @"block-inbound", @"block-outbound", @"use-default"];
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
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 5; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return 3;
    if (section == 2) return 4;
    if (section == 3) return MAX((NSUInteger)1, self.identities.count);
    return MAX((NSUInteger)1, [self.monitor[@"events"] count]);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"Deployment status", @"Filter configuration", @"Policy for new flows", @"OS identities · tap to edit", @"Recent flow reports · newest first"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"Target: iOS 16.1.1 / Dopamine 3.0.10. Supervision, entitlement acceptance, app-group access and provider registration must be verified on-device. No all-traffic or boot-time protection guarantee.";
    if (section == 2) return @"Unknown attribution has its own policy. Blocking it may interrupt system services. Existing allowed flows are not revoked. Reset restores allow defaults.";
    if (section == 4) return @"Up to 300 reports per control-provider session. Byte totals appear at flow close. Missing reports do not imply no traffic. Payloads and destinations are not recorded.";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    if (path.section == 0) {
        NSDate *updated = self.monitor[@"updated"];
        NSTimeInterval age = [updated isKindOfClass:NSDate.class] ? -updated.timeIntervalSinceNow : DBL_MAX;
        BOOL fresh = age >= 0 && age < 8 && [self.monitor[@"controlRunning"] boolValue];
        NSString *saved = !self.loaded ? @"unknown" : ([NEFilterManager sharedManager].enabled ? @"enabled" : @"disabled");
        cell.textLabel.text = [NSString stringWithFormat:@"Saved configuration: %@\nControl heartbeat: %@", saved, fresh ? @"recent" : @"absent or stale"];
        NSDate *last = self.monitor[@"lastReport"];
        NSString *report = [last isKindOfClass:NSDate.class] && last.timeIntervalSince1970 > 0 ? last.description : @"none";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\nLast OS flow report: %@\n%@", self.message ?: @"", report, self.monitor[@"policyError"] ?: @""];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == 1) {
        cell.textLabel.text = @[@"Enable filter…", @"Disable filter", @"Remove filter configuration"][path.row];
        cell.textLabel.textColor = self.busy ? UIColor.secondaryLabelColor : self.view.tintColor;
    } else if (path.section == 2) {
        cell.textLabel.text = @[@"Apps without a rule", @"Unattributed flows", @"Add exact identity…", @"Reset policy to allow defaults…"][path.row];
        if (path.row < 2) cell.detailTextLabel.text = self.policy.document[path.row ? @"unattributed" : @"default"] ?: @"Policy unavailable";
    } else if (path.section == 3) {
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
            cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@", event[@"action"], [event[@"identity"] length] ? event[@"identity"] : @"Unattributed"];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · event %@\nIn %@ B / Out %@ B",
                event[@"time"], event[@"direction"], event[@"event"],
                event[@"bytesIn"], event[@"bytesOut"]];
        }
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == 1 && !self.busy) {
        if (path.row) { [self changeConfiguration:path.row == 1 ? 0 : 2]; return; }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Enable experimental filter?" message:@"iOS may disable another app's content filter. A saved configuration does not prove filtering works. Use the device test checklist before relying on NetShield." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Enable" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self changeConfiguration:1]; }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else if (path.section == 2) {
        if (path.row < 2) [self chooseActionForIdentity:nil defaultKey:path.row ? @"unattributed" : @"default"];
        else if (path.row == 2) [self addIdentity];
        else {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset all v2 rules?" message:@"Restores allow for new attributed and unattributed flows. Does not enable or disable the OS filter." preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { [self savePolicy:[[NSPolicy defaultDocument] mutableCopy]]; }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    } else if (path.section == 3 && self.identities.count) [self chooseActionForIdentity:self.identities[path.row] defaultKey:nil];
}
@end

@interface NSAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation NSAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[[NSDashboard alloc] initWithStyle:UITableViewStyleInsetGrouped]];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(NSAppDelegate.class)); }
}
