#import "NSDashboard+Internal.h"
#import "NSGlobalRuleEditor.h"
#import "../Shared/NSGlobalRule.h"
#import "../Shared/NSExport.h"
#import "../Shared/NSProviderHealth.h"

@interface NSCryptoWalletsController : UITableViewController
@property(nonatomic, copy) NSArray<NSArray<NSString *> *> *wallets;
@end

@implementation NSCryptoWalletsController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Crypto wallets";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 90;
    self.wallets = @[
        @[ @"BTC (Bitcoin Network)", @"31uHLpioo1TbxAmo9kM7rrKcLz3wvcoZaL" ],
        @[ @"ETH (Ethereum Network)", @"0x6060BEA4305BC4259bcF1db5eDbe756b7b74a895" ],
        @[ @"USDT (Ethereum Network)", @"0x17f0c9d7229E9A1Ad1cAccbfEe7979CF39F2301F" ],
        @[ @"USDC (Ethereum Network)", @"0xD69Dc2a18e64E071d096435dD6f9DdD52B10785c" ],
        @[ @"RNDR / ERC-20 (Ethereum Network)", @"0x9cc3fCc3b41a31cDC07E33930F1d622c3ed690E9" ],
        @[ @"LTC (Litecoin Network)", @"MNWMWwueZBoQSd7Ms9meQ1cMfeY16BA7E1" ],
        @[ @"SOL (Solana Network)", @"H2ydj95396KRErC4nMtK5B2BAjobPTyUh7LpYBFSmFnP" ],
        @[ @"BNB (BNB Smart Chain Network)", @"0x314148b89744663ad9F1Fb8EA6862a62abf2fC93" ]
    ];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? self.wallets.count : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Tap a wallet address to copy" : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                   reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByCharWrapping;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.accessibilityTraits |= UIAccessibilityTraitButton;
    if (path.section == 0) {
        cell.textLabel.text = self.wallets[path.row][0];
        cell.detailTextLabel.text = self.wallets[path.row][1];
        cell.detailTextLabel.textColor = UIColor.systemBlueColor;
        cell.accessibilityHint = @"Copies the wallet address";
    } else {
        cell.textLabel.text = @"Cancel";
        cell.textLabel.textColor = UIColor.systemBlueColor;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == 1) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    NSArray *wallet = self.wallets[path.row];
    UIPasteboard.generalPasteboard.string = wallet[1];
    UIAlertController *notice = [UIAlertController
        alertControllerWithTitle:@"Wallet address copied"
                         message:[NSString stringWithFormat:@"%@\n%@", wallet[0], wallet[1]]
                  preferredStyle:UIAlertControllerStyleAlert];
    [notice addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:notice animated:YES completion:nil];
}
@end

@implementation NSDashboard
- (void)presentViewController:(UIViewController *)viewControllerToPresent
                     animated:(BOOL)animated
                   completion:(void (^)(void))completion {
    if ([viewControllerToPresent isKindOfClass:UIAlertController.class]) {
        UIAlertController *alert = (UIAlertController *)viewControllerToPresent;
        alert.view.tintColor = UIColor.systemBlueColor;
    }
    [super presentViewController:viewControllerToPresent animated:animated completion:completion];
}
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
    [self.updateTask cancel];
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
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.checkedForUpdateOnLaunch) {
        [self checkForUpdateManually:NO];
    }
    [self presentPendingUpdateResult];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
}
- (void)reloadMonitor {
    if (self.tableView.editing) {
        return;
    }
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
    NSSet *hiddenIdentities = [NSSet
        setWithArray:[NSUserDefaults.standardUserDefaults stringArrayForKey:@"hiddenRuleIdentities"] ?: @[]];
    for (NSDictionary *event in self.monitor[@"events"]) {
        NSString *identity = event[@"identity"];
        if ([identity isKindOfClass:NSString.class] && identity.length &&
            ![hiddenIdentities containsObject:identity]) {
            [identities addObject:identity];
        }
    }
    NSMutableSet *systemIdentities = [NSMutableSet new];
    for (NSString *identity in [identities allObjects]) {
        if (NSIsAppleSystemIdentity(identity)) {
            [systemIdentities addObject:identity];
            [identities removeObject:identity];
        }
    }
    self.identities = [[identities allObjects] sortedArrayUsingSelector:@selector(compare:)];
    self.systemIdentities = [[systemIdentities allObjects] sortedArrayUsingSelector:@selector(compare:)];
    self.globalRuleKeys =
        [[self.policy.document[@"globalRules"] allKeys] sortedArrayUsingSelector:@selector(compare:)];
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
    [self presentPendingUpdateResult];
}
- (BOOL)hasFreshMonitor {
    NSString *activation =
        NEFilterManager.sharedManager.providerConfiguration.vendorConfiguration[@"activation"];
    return NSHasCurrentControlHeartbeat(self.monitor, activation, NSDate.date);
}
- (void)showError:(NSError *)error {
    [self showError:error operation:@"Policy/storage"];
}
- (void)exportRulesAndRecentActivityFromRow:(NSIndexPath *)path {
    NSError *error = nil;
    NSPolicy *policy = NSReadPolicy(&error);
    if (!policy) {
        [self showError:error operation:@"Export"];
        return;
    }
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSData *data = NSRulesAndActivityJSON(policy, NSReadMonitor()[@"events"] ?: @[], version, &error);
    if (!data) {
        [self showError:error operation:@"Export"];
        return;
    }
    NSURL *directory = [NSURL
        fileURLWithPath:[NSTemporaryDirectory()
                            stringByAppendingPathComponent:[@"NetShield2-Export-"
                                                               stringByAppendingString:NSUUID.UUID
                                                                                           .UUIDString]]
            isDirectory:YES];
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self showError:error operation:@"Export"];
        return;
    }
    NSURL *url = [directory URLByAppendingPathComponent:@"NetShield2-Rules-and-Recent-Activity.json"];
    if (![data writeToURL:url options:NSDataWritingAtomic error:&error]) {
        [files removeItemAtURL:directory error:NULL];
        [self showError:error operation:@"Export"];
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[ url ]
                                                                        applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.tableView;
    share.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:path];
    __weak typeof(self) weakSelf = self;
    share.completionWithItemsHandler =
        ^(UIActivityType activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
            [files removeItemAtURL:directory error:NULL];
            if (activityError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf showError:activityError operation:@"Export"];
                });
            }
        };
    [self presentViewController:share animated:YES completion:nil];
}
- (void)showError:(NSError *)error operation:(NSString *)operation {
    self.message = [NSString stringWithFormat:@"%@: %@ (%@ %ld).", operation, error.localizedDescription,
                                              error.domain, (long)error.code];
    [self refreshTableKeepingPosition];
}
- (BOOL)updatePolicy:(BOOL (^)(NSMutableDictionary *, NSError **))mutation {
    NSError *error = nil;
    if (!NSUpdatePolicy(mutation, &error)) {
        [self showError:error];
        [self reloadMonitor];
        return NO;
    }
    NSRemoveAutomaticallyAllowedNotifications();
    self.message = @"Policy saved for new flows. Close existing connections and retry; admitted flows keep "
                   @"their previous verdict.";
    [self reloadMonitor];
    return YES;
}
- (BOOL)removeAppRuleForIdentity:(NSString *)identity {
    BOOL saved = [self updatePolicy:^BOOL(NSMutableDictionary *document, NSError **error) {
        return NSUseDefaultRule(document, identity, error);
    }];
    if (saved) {
        // History must not recreate a removed row on refresh or after relaunch.
        // A newly saved explicit rule will still make the identity visible.
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSMutableSet *hidden =
            [NSMutableSet setWithArray:[defaults stringArrayForKey:@"hiddenRuleIdentities"] ?: @[]];
        [hidden addObject:identity];
        [defaults setObject:hidden.allObjects forKey:@"hiddenRuleIdentities"];
        [self reloadMonitor];
    }
    return saved;
}
- (void)chooseActionForIdentity:(NSString *)identity defaultKey:(NSString *)key {
    if (!self.policy) {
        return;
    }
    NSString *title = NSIdentityDisplayName(identity);
    NSString *explanation = @"Choose a rule for new connections.";
    NSArray *actions = @[ @"allow", @"block-inbound", @"block", @"remove" ];
    if ([key isEqual:@"default"]) {
        title = @"Default Rule";
        explanation = @"Choose what happens when an app without a saved rule connects. Ask me lets you "
                      @"decide from a notification.";
        actions = @[ @"ask", @"allow", @"block" ];
    } else if ([key isEqual:@"unattributed"]) {
        title = @"Unidentified";
        explanation = @"These connections have no app identity from iOS. Allow is recommended to avoid "
                      @"interrupting system services.";
        actions = @[ @"allow", @"block" ];
    }
    NSRuleActionController *alert = [NSRuleActionController controllerWithTitle:title message:explanation];
    alert.selectedRule = key ? self.policy.document[key] : self.policy.document[@"rules"][identity];
    for (NSString *action in actions) {
        [alert addActionWithTitle:[self ruleTitle:action]
                             rule:action
                          handler:^{
                              if (!key && [action isEqual:@"remove"]) {
                                  [self removeAppRuleForIdentity:identity];
                                  return;
                              }
                              [self updatePolicy:^BOOL(NSMutableDictionary *document, NSError **error) {
                                  if (key) {
                                      document[key] = action;
                                  } else {
                                      NSMutableDictionary *rules = document[@"rules"];
                                      rules[identity] = action;
                                  }
                                  return YES;
                              }];
                          }];
    }
    [alert addActionWithTitle:@"Cancel" rule:nil handler:nil];
    [self presentViewController:alert animated:YES completion:nil];
}
- (NSString *)globalRuleTitle:(NSString *)key {
    NSArray *parts = NSCustomGlobalRuleComponents(key);
    if (parts) {
        NSMutableArray *names = [NSMutableArray new];
        for (NSString *identity in NSCustomGlobalRuleIdentities(parts)) {
            [names addObject:NSIdentityDisplayName(identity)];
        }
        return [NSString
            stringWithFormat:@"%@\n%@\n%@ / %@",
                             names.count ? [names componentsJoinedByString:@", "] : @"All apps",
                             [parts[1] length] ? [self globalRuleTitle:parts[1]] : @"All domains / IPs",
                             [parts[2] length] ? [self globalRuleTitle:parts[2]] : @"All ports",
                             [parts[3] isEqual:@"any"] ? @"UDP & TCP" : [parts[3] uppercaseString]];
    }
    if ([key hasPrefix:@"group:"]) {
        NSString *first = NSGlobalRuleMembers(key).firstObject;
        NSString *kind = [first hasPrefix:@"localPort:"] ? @"Local ports"
                         : [first hasPrefix:@"port:"]    ? @"Remote ports"
                                                         : @"IPs / Domains";
        NSArray *members = NSGlobalRuleMembers(key);
        NSArray *preview = [members subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)5, members.count))];
        NSString *text = NSGlobalRuleInputText(NSGlobalKeyFromMembers(preview));
        return [NSString stringWithFormat:@"%@: %@%@", kind, text, members.count > 5 ? @", ..." : @""];
    }
    NSRange colon = [key rangeOfString:@":"];
    NSString *kind = [key hasPrefix:@"localPort:"] ? @"Local port"
                     : [key hasPrefix:@"port:"]    ? @"Remote port"
                     : [key hasPrefix:@"ip:"]      ? @"IP"
                                                   : @"Domain";
    return [NSString stringWithFormat:@"%@: %@", kind, [key substringFromIndex:colon.location + 1]];
}
- (void)chooseGlobalRule:(NSString *)key {
    [self chooseGlobalRule:key editingKey:nil];
}
- (void)chooseGlobalRule:(NSString *)key editingKey:(NSString *)original {
    if (!self.policy) {
        return;
    }
    NSRuleActionController *alert =
        [NSRuleActionController controllerWithTitle:[self globalRuleTitle:key]
                                            message:@"Applies when all rule conditions match. Overrides app "
                                                    @"rules and the iOS system traffic allowance."];
    alert.opensExpanded = YES;
    alert.selectedRule = self.policy.document[@"globalRules"][key];
    NSMutableArray *actions = [@[ @"allow", @"block-inbound", @"block" ] mutableCopy];
    BOOL existing = !original && self.policy.document[@"globalRules"][key] != nil;
    if (existing) {
        [actions addObject:@"remove"];
    }
    for (NSString *action in actions) {
        [alert addActionWithTitle:[self ruleTitle:action]
                             rule:action
                          handler:^{
                              [self updatePolicy:^BOOL(NSMutableDictionary *document, NSError **error) {
                                  NSMutableDictionary *rules =
                                      [document[@"globalRules"] mutableCopy] ?: [NSMutableDictionary new];
                                  if (original) {
                                      if (!rules[original] || (![original isEqual:key] && rules[key])) {
                                          if (error) {
                                              *error =
                                                  [NSError errorWithDomain:@"NetShield2.Policy"
                                                                      code:2
                                                                  userInfo:@{
                                                                      NSLocalizedDescriptionKey :
                                                                          @"The original rule was removed or "
                                                                          @"an identical rule already exists."
                                                                  }];
                                          }
                                          return NO;
                                      }
                                      [rules removeObjectForKey:original];
                                  }
                                  if ([action isEqual:@"remove"]) {
                                      [rules removeObjectForKey:key];
                                  } else {
                                      rules[key] = action;
                                  }
                                  document[@"globalRules"] = rules;
                                  return YES;
                              }];
                          }];
    }
    if (existing) {
        [alert addActionWithTitle:@"Edit Rule"
                             rule:nil
                          handler:^{
                              [self editGlobalRule:key];
                          }];
    }
    [alert addActionWithTitle:@"Cancel" rule:nil handler:nil];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)editGlobalRule:(NSString *)original {
    if (!self.policy || self.busy) {
        return;
    }
    NSGlobalRuleEditor *editor = [[NSGlobalRuleEditor alloc] initWithStyle:UITableViewStyleInsetGrouped];
    NSMutableSet *identities = [NSMutableSet setWithArray:self.identities ?: @[]];
    [identities addObjectsFromArray:self.systemIdentities ?: @[]];
    for (NSString *key in self.globalRuleKeys) {
        [identities addObjectsFromArray:NSCustomGlobalRuleIdentities(NSCustomGlobalRuleComponents(key))];
    }
    editor.identities =
        [identities.allObjects sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    editor.originalKey = original;
    editor.originalAction = original ? self.policy.document[@"globalRules"][original] : nil;
    __weak typeof(self) weakSelf = self;
    editor.saveRule = ^BOOL(NSString *key, NSString *action, NSError **error) {
        BOOL saved = NSUpdatePolicy(
            ^BOOL(NSMutableDictionary *document, NSError **mutationError) {
                NSMutableDictionary *rules =
                    [document[@"globalRules"] mutableCopy] ?: [NSMutableDictionary new];
                if ((original && !rules[original]) || (![original isEqual:key] && rules[key])) {
                    if (mutationError) {
                        *mutationError = [NSError
                            errorWithDomain:@"NetShield2.Policy"
                                       code:2
                                   userInfo:@{
                                       NSLocalizedDescriptionKey : @"The original rule was removed or an "
                                                                   @"identical rule already exists."
                                   }];
                    }
                    return NO;
                }
                if (original) {
                    [rules removeObjectForKey:original];
                }
                rules[key] = action;
                document[@"globalRules"] = rules;
                return YES;
            },
            error);
        if (saved) {
            NSRemoveAutomaticallyAllowedNotifications();
            weakSelf.message = @"Policy saved for new flows. Close existing connections and retry; admitted "
                               @"flows keep their previous verdict.";
            [weakSelf reloadMonitor];
        }
        return saved;
    };
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:editor];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:navigation animated:YES completion:nil];
}
- (NSString *)ruleTitle:(NSString *)rule {
    return @{
        @"ask" : @"Ask Me",
        @"allow" : @"Allow",
        @"block" : @"Block In & Out",
        @"block-inbound" : @"Block Incoming",
        @"block-outbound" : @"Block Outgoing",
        @"remove" : @"Remove Rule"
    }[rule ?: @""]
               ?: @"Default Rule";
}
- (void)firewallChanged:(UISwitch *)sender {
    if (self.busy) {
        return;
    }
    if (!sender.on) {
        [self changeConfiguration:NSConfigurationDisable];
        return;
    }
    NSError *error = nil;
    if (!NSReadPolicy(&error)) {
        [self showError:error];
        [self reloadMonitor];
        return;
    }
    self.policy = NSReadPolicy(&error);
    self.policyReadError = self.policy ? @"" : error.localizedDescription;
    NSRemoveAutomaticallyAllowedNotifications();
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
                                 @"not load. Notification banners are suppressed while you are in "
                                 @"NetShield2. "
                                 @"You may need to return to NetShield2 to allow your browser. Choose Allow "
                                 @"In & Out "
                                 @"under Waiting for your decision, then open the link again. If you "
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
        alertControllerWithTitle:@"Support the Developer"
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
                         actionWithTitle:@"Crypto"
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *action) {
                                     dispatch_async(dispatch_get_main_queue(), ^{
                                         NSCryptoWalletsController *wallets =
                                             [[NSCryptoWalletsController alloc]
                                                 initWithStyle:UITableViewStyleInsetGrouped];
                                         UINavigationController *popup = [[UINavigationController alloc]
                                             initWithRootViewController:wallets];
                                         popup.modalPresentationStyle = UIModalPresentationFormSheet;
                                         [self presentViewController:popup animated:YES completion:nil];
                                     });
                                 }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)showNotificationHelp {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Answer without leaving your app"
                         message:@"Touch and hold a NetShield2 notification, then choose Allow, "
                                 @"Block Incoming, or Keep Blocking. Tapping the notification body opens "
                                 @"NetShield2.\n\nUsing "
                                 @"Do Not "
                                 @"Disturb? In Settings > Focus > Do Not Disturb > Apps, allow notifications "
                                 @"from NetShield2. Do the same for any other Focus you use.\n\nUnanswered "
                                 @"requests are blocked after 30 seconds. You can allow them later and retry "
                                 @"the connection."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
