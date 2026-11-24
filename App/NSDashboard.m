#import "NSDashboard+Internal.h"
#import "NSGlobalRuleEditor.h"
#import "../Shared/NSActivity.h"
#import "../Shared/NSGlobalRule.h"
#import "../Shared/NSExport.h"
#import "../Shared/NSProviderHealth.h"
#import "../Shared/NSRuleChoices.h"
#import "../Shared/NSPermissionRequest.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <errno.h>

NSString *const NSSystemRulesLockedMessage = @"Disable \"Allow iOS system traffic\" to modify system rules.";
NSString *const NSAppRulesLockedMessage = @"Disable \"Allow third-party traffic\" to modify app rules.";
static NSString *const NSSystemRulesLockedErrorDomain = @"NetShield2.SystemRulesLocked";
static NSString *const NSAppRulesLockedErrorDomain = @"NetShield2.AppRulesLocked";

// Recheck inside the policy transaction before changing rules or ask generations.
static BOOL NSIdentityRuleEditAllowed(NSDictionary *document, BOOL system, NSError **error) {
    if (!(system ? NSAppleSystemTrafficEnabled(document) : NSThirdPartyTrafficEnabled(document))) {
        return YES;
    }
    if (error) {
        *error =
            [NSError errorWithDomain:system ? NSSystemRulesLockedErrorDomain : NSAppRulesLockedErrorDomain
                                code:1
                            userInfo:@{
                                NSLocalizedDescriptionKey : system ? NSSystemRulesLockedMessage
                                                                   : NSAppRulesLockedMessage
                            }];
    }
    return NO;
}

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
- (void)tableView:(UITableView *)tableView
    willDisplayHeaderView:(UIView *)view
               forSection:(NSInteger)section {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        ((UITableViewHeaderFooterView *)view).textLabel.font = [[UIFontMetrics
            metricsForTextStyle:UIFontTextStyleFootnote] scaledFontForFont:[UIFont systemFontOfSize:16]];
    }
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
    [self cancelRowPress];
    [self clearCopyFeedback];
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
    self.submittedOnce = [NSMutableDictionary new];
    [self restoreCollapsedSections];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self
                                                      action:@selector(refreshThenOfferRespring:)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self installRowPressGesture];
    UITapGestureRecognizer *outside =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissActivityKeyboard)];
    outside.delegate = self;
    outside.cancelsTouchesInView = NO;
    [self.tableView addGestureRecognizer:outside];
    self.navigationKeyboardDismissGesture =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissActivityKeyboard)];
    self.navigationKeyboardDismissGesture.delegate = self;
    self.navigationKeyboardDismissGesture.cancelsTouchesInView = NO;
    self.rowHeights = [NSMutableDictionary new];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(configurationChanged:)
                                               name:NEFilterConfigurationDidChangeNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(configurationChanged:)
                                               name:UIApplicationDidBecomeActiveNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(activityKeyboardFrameDidChange:)
                                               name:UIKeyboardDidChangeFrameNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(configurationChanged:)
                                               name:NSConfigurationLateAcknowledgement
                                             object:nil];
    self.message = @"";
    self.policyBootstrapPending = YES;
    NSRemoveAutomaticallyManagedNotifications();
    [self refreshNotificationSettings];
    [self loadConfiguration];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.tableView.bounds.size.width;
    NSString *category = self.traitCollection.preferredContentSizeCategory;
    if (width != self.measuredTableWidth || ![category isEqual:self.measuredContentSizeCategory]) {
        self.measuredTableWidth = width;
        self.measuredContentSizeCategory = category;
        [self refreshTableKeepingPosition];
    }
}
- (void)configurationChanged:(NSNotification *)notification {
    BOOL returning = [notification.name isEqual:UIApplicationDidBecomeActiveNotification];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshNotificationSettings];
        if (returning || [notification.name isEqual:NEFilterConfigurationDidChangeNotification]) {
            [NSConfigurationCoordinator checkPendingSave];
        }
        [self loadConfigurationWithCompletion:^{
            if (returning && !self.busy && self.preferencesLoaded && self.configurationReady &&
                self.savedEnabled) {
                NSWriteNotificationRetryRevision(NULL);
            }
        }];
    });
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.timer invalidate];
    [self.clipboardFeedbackTimer invalidate];
    [self.clipboardFeedbackView removeFromSuperview];
    [self.updateTask cancel];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController.navigationBar addGestureRecognizer:self.navigationKeyboardDismissGesture];
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
    // A returning sheet/editor is not another launch. Use one gate per process
    // even if a dashboard is recreated; the persisted schedule handles relaunches.
    static dispatch_once_t launchUpdateCheck;
    dispatch_once(&launchUpdateCheck, ^{
        [self checkForUpdateManually:NO];
    });
    [self presentPendingUpdateResult];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self cancelRowPress];
    [self clearCopyFeedback];
    [self dismissActivityKeyboard];
    [self.navigationController.navigationBar removeGestureRecognizer:self.navigationKeyboardDismissGesture];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
}
- (void)reloadMonitor {
    if (self.tableView.editing ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        return;
    }
    if (self.snapshotPending) {
        self.snapshotAgain = YES;
        return;
    }
    self.snapshotPending = YES;
    NSUInteger generation = self.storageGeneration;
    NSArray *cachedEvents = self.activityEvents, *cachedGroups = self.activityGroups;
    __weak typeof(self) weakSelf = self;
    dispatch_async(NSAppStorageQueue(), ^{
        NSError *policyError = nil, *monitorError = nil;
        NSPolicy *policy = NSReadPolicy(&policyError);
        NSDictionary *report = NSReadMonitorWithError(&monitorError) ?: @{};
        NSArray *events = report[@"events"] ?: @[];
        NSArray *groups =
            [events isEqual:cachedEvents] && cachedGroups ? cachedGroups : NSGroupedActivity(events);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSDashboard *owner = weakSelf;
            if (!owner) {
                return;
            }
            owner.snapshotPending = NO;
            BOOL again = owner.snapshotAgain;
            owner.snapshotAgain = NO;
            if (generation == owner.storageGeneration && !owner.tableView.editing &&
                !owner.tableView.dragging && !owner.tableView.decelerating) {
                owner.policy = policy;
                owner.globalRulesAwaitingReadback = !policy;
                owner.policyMissing = !policy && NSFileIsAbsent(policyError);
                owner.policyReadError = policy ? @"" : policyError.localizedDescription;
                owner.monitorReadError =
                    monitorError && !NSFileIsAbsent(monitorError) ? monitorError.localizedDescription : @"";
                owner.activityEvents = report[@"events"] ?: @[];
                owner.activityGroups = groups;
                [owner applyMonitor:report];
            }
            if (generation == owner.storageGeneration &&
                (owner.tableView.editing || owner.tableView.dragging || owner.tableView.decelerating)) {
                owner.monitorRefreshDeferred = YES;
            }
            if (again || generation != owner.storageGeneration) {
                [owner reloadMonitor];
            }
        });
    });
}
- (void)trackOneTimePermissionRequest:(NSDictionary *)request action:(NSString *)action {
    if (self.submittedOnce.count < NSMaximumActiveRequests) {
        NSMutableDictionary *submission = [request mutableCopy];
        submission[@"submittedAction"] = action;
        self.submittedOnce[request[@"token"]] = submission;
    }
    self.message = @"One-time decision submitted. Waiting for the filter to confirm.";
    [self reloadMonitor];
}
- (void)applyMonitor:(NSDictionary *)report {
    NSMutableDictionary *monitor = [report mutableCopy];
    NSMutableArray *requests = [NSMutableArray new];
    for (NSDictionary *request in monitor[@"requests"]) {
        if (NSPermissionGenerationMatches(self.policy, request) &&
            [self.policy requiresPermissionForRequest:request]) {
            [requests addObject:request];
        }
    }
    monitor[@"requests"] = requests;
    self.monitor = monitor;
    NSDictionary *represented = nil;
    for (NSDictionary *request in requests) {
        if ([request[@"token"] isEqual:self.presentedRequest[@"token"]]) {
            represented = request;
        }
    }
    if (self.permissionAlert &&
        (!NSPermissionPresentationMatches(self.presentedRequest, represented) ||
         ![represented[@"expired"] isEqual:self.presentedRequest[@"expired"]] || ![self hasFreshMonitor])) {
        [self.permissionAlert dismissViewControllerAnimated:NO completion:nil];
        self.permissionAlert = nil;
        self.presentedRequest = nil;
    }
    NSMutableSet *identities = [NSMutableSet setWithArray:[self.policy.document[@"rules"] allKeys] ?: @[]];
    NSMutableSet *hiddenIdentities = [NSMutableSet
        setWithArray:[NSUserDefaults.standardUserDefaults stringArrayForKey:@"hiddenRuleIdentities"] ?: @[]];
    [hiddenIdentities minusSet:identities];
    // Activation reveals all exact telemetry keys, including never-observed or
    // previously removed rows. Later unlocked removals remain hidden.
    if ([self.policy.document[@"blockAppleSystemTelemetry"] boolValue]) {
        [hiddenIdentities minusSet:[NSSet setWithArray:NSAppleSystemTelemetryIdentities()]];
    }
    NSSet *previousHidden = [NSSet
        setWithArray:[NSUserDefaults.standardUserDefaults stringArrayForKey:@"hiddenRuleIdentities"] ?: @[]];
    if (![previousHidden isEqual:hiddenIdentities]) {
        [NSUserDefaults.standardUserDefaults setObject:hiddenIdentities.allObjects
                                                forKey:@"hiddenRuleIdentities"];
    }
    for (NSDictionary *event in self.monitor[@"events"]) {
        NSString *identity = event[@"identity"];
        if ([identity isKindOfClass:NSString.class] && identity.length &&
            ![hiddenIdentities containsObject:identity]) {
            [identities addObject:identity];
        }
    }
    if ([self.policy.document[@"appleSystemTelemetryIntroduced"] boolValue]) {
        for (NSString *identity in NSAppleSystemTelemetryIdentities()) {
            if (![hiddenIdentities containsObject:identity]) {
                [identities addObject:identity];
            }
        }
    }
    NSMutableSet *systemIdentities = [NSMutableSet new];
    // Keep manually entered identities visible while their editor has no saved selection.
    if (self.ruleEditor && !self.ruleEditor.isBeingDismissed && self.editingRuleIdentity.length) {
        [identities addObject:self.editingRuleIdentity];
    }
    for (NSString *identity in [identities allObjects]) {
        if (NSIsAppleSystemIdentity(identity)) {
            [systemIdentities addObject:identity];
            [identities removeObject:identity];
        }
    }
    NSComparator byDisplayName = ^NSComparisonResult(NSString *left, NSString *right) {
        return NSCompareIdentityDisplayNames(left, right);
    };
    self.identities = [[identities allObjects] sortedArrayUsingComparator:byDisplayName];
    self.systemIdentities = [[systemIdentities allObjects] sortedArrayUsingComparator:byDisplayName];
    NSSet *tokens = [NSSet setWithArray:[self.monitor[@"requests"] valueForKey:@"token"] ?: @[]];
    [self.deferredRequests intersectSet:tokens];
    [self checkSubmittedPermissionDecisions];
    [self refreshTableKeepingPosition];
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive && !self.busy &&
        !self.importPending && !self.presentedViewController && self.preferencesLoaded && self.savedEnabled &&
        [self hasFreshMonitor]) {
        for (NSDictionary *request in self.monitor[@"requests"]) {
            if (![self.deferredRequests containsObject:request[@"token"]] &&
                ![request[@"deferred"] boolValue] &&
                !([request[@"mode"] isEqual:@"once"] && [request[@"expired"] boolValue])) {
                [self presentRequest:request];
                break;
            }
        }
    }
    [self presentPendingUpdateResult];
}
- (BOOL)hasFreshMonitor {
    return self.preferencesLoaded &&
           NSHasCurrentControlHeartbeat(self.monitor, self.savedActivation, NSDate.date);
}
- (void)showError:(NSError *)error {
    [self showError:error operation:@"Policy/storage"];
}
- (void)finishImportPresentation {
    self.importPending = NO;
    [self refreshTableKeepingPosition];
    [self reloadMonitor];
    if (self.configurationRefreshPending && !self.busy) {
        [self loadConfiguration];
    }
}
- (void)showImportResult:(NSString *)message success:(BOOL)success {
    // Keep request cards and automatic configuration refresh behind the result.
    self.importPending = YES;
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:success ? @"Rules Imported" : @"Import Rules Failed"
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                                [weakSelf finishImportPresentation];
                                            }]];
    [self refreshTableKeepingPosition];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)importRules {
    if (self.busy || self.importPending || self.exportPending || self.presentedViewController) {
        return;
    }
    self.importPending = YES;
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeJSON ] asCopy:NO];
    picker.allowsMultipleSelection = NO;
    picker.delegate = self;
    picker.title = @"Replace All Saved Rules";
    picker.navigationItem.prompt = @"Replaces Global, App and System rules; keeps settings and activity";
    [self refreshTableKeepingPosition];
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self finishImportPresentation];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (!self.importPending) {
        return;
    }
    NSUInteger generation = self.storageGeneration;
    NSURL *url = urls.count == 1 ? urls.firstObject : nil;
    [controller
        dismissViewControllerAnimated:YES
                           completion:^{
                               dispatch_async(NSAppStorageQueue(), ^{
                                   __block NSError *readError = nil;
                                   __block NSRuleImportResult *result = nil;
                                   BOOL scoped = [url startAccessingSecurityScopedResource];
                                   @try {
                                       if (url.isFileURL) {
                                           NSFileCoordinator *coordinator =
                                               [[NSFileCoordinator alloc] initWithFilePresenter:nil];
                                           NSError *coordinationError = nil;
                                           [coordinator
                                               coordinateReadingItemAtURL:url
                                                                  options:
                                                                      NSFileCoordinatorReadingWithoutChanges
                                                                    error:&coordinationError
                                                               byAccessor:^(NSURL *coordinatedURL) {
                                                                   NSData *data = NSReadBoundedExternalURL(
                                                                       coordinatedURL, &readError);
                                                                   if (data) {
                                                                       result =
                                                                           NSParseRulesJSON(data, &readError);
                                                                   }
                                                               }];
                                           if (coordinationError) {
                                               readError = coordinationError;
                                               result = nil;
                                           }
                                       }
                                   } @finally {
                                       if (scoped) {
                                           [url stopAccessingSecurityScopedResource];
                                       }
                                   }
                                   dispatch_async(dispatch_get_main_queue(), ^{
                                       if (generation != self.storageGeneration || self.busy) {
                                           [self showImportResult:
                                                     @"Saved state changed while reading the file. Select "
                                                     @"the file again to replace the current rules."
                                                          success:NO];
                                           return;
                                       }
                                       if (!result) {
                                           [self
                                               showImportResult:readError.localizedDescription
                                                                    ?: @"The selected JSON file could not be "
                                                                       @"read. No replacement was published."
                                                        success:NO];
                                           return;
                                       }
                                       // Admission is synchronous on main; busy takes ownership before
                                       // any other command can enter. Reading never held a file lock.
                                       self.importPending = NO;
                                       [self
                                           performStorageCommand:^BOOL(NSError **error) {
                                               return NSReplaceRulesFromImport(result, error);
                                           }
                                           completion:^(BOOL saved, NSError *error) {
                                               self.importPending = YES;
                                               if (saved ||
                                                   [error.userInfo[@"replacementPublished"] boolValue]) {
                                                   [self.submittedOnce removeAllObjects];
                                                   [self.deferredRequests removeAllObjects];
                                                   NSRemoveAutomaticallyManagedNotifications();
                                                   [self applyMonitor:self.monitor ?: @{}];
                                               }
                                               [self showImportResult:saved ? result.summary
                                                                            : error.localizedDescription
                                                              success:saved];
                                           }];
                                   });
                               });
                           }];
}
- (void)exportRulesAndRecentActivityFromRow:(NSIndexPath *)path {
    if (self.exportPending || self.importPending || self.busy) {
        return;
    }
    self.exportPending = YES;
    NSUInteger generation = self.storageGeneration;
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    dispatch_async(NSAppStorageQueue(), ^{
        NSError *error = nil;
        NSPolicy *policy = NSReadPolicy(&error);
        NSData *data =
            policy ? NSRulesAndActivityJSON(policy, NSReadMonitor()[@"events"] ?: @[], version, &error) : nil;
        NSURL *container = NSSharedURL(@"");
        NSURL *url = data ? NSStageRulesAndActivityExport(data, container, &error) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.exportPending = NO;
            if (generation != self.storageGeneration || self.busy) {
                if (url) {
                    dispatch_async(NSAppStorageQueue(), ^{
                        NSRemoveStagedExport(container, url, NULL);
                    });
                }
                return;
            }
            if (!url) {
                [self showError:error operation:@"Export"];
                return;
            }
            NSError *presentationError = nil;
            @try {
                UIActivityViewController *share =
                    [[UIActivityViewController alloc] initWithActivityItems:@[ url ]
                                                      applicationActivities:nil];
                share.popoverPresentationController.sourceView = self.tableView;
                share.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:path];
                __weak typeof(self) weakSelf = self;
                share.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed,
                                                     NSArray *returnedItems, NSError *activityError) {
                    dispatch_async(NSAppStorageQueue(), ^{
                        NSError *cleanupError = nil;
                        NSRemoveStagedExport(container, url, &cleanupError);
                        NSError *resultError = activityError ?: cleanupError;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (resultError) {
                                [weakSelf showError:resultError operation:@"Export"];
                            } else if (completed && [weakSelf.message hasPrefix:@"Export: "]) {
                                weakSelf.message = @"";
                                [weakSelf refreshTableKeepingPosition];
                            }
                        });
                    });
                };
                if (self.view.window && !self.presentedViewController && !self.isBeingDismissed) {
                    [self presentViewController:share animated:YES completion:nil];
                }
                if (!share.presentingViewController) {
                    presentationError =
                        NSExportError(@"The share sheet could not open. Return to NetShield2 and "
                                      @"retry Export.");
                }
            } @catch (NSException *exception) {
                presentationError = NSExportError(
                    [NSString stringWithFormat:@"The share sheet could not open: %@", exception.reason]);
            }
            if (presentationError) {
                dispatch_async(NSAppStorageQueue(), ^{
                    NSRemoveStagedExport(container, url, NULL);
                });
                [self showError:presentationError operation:@"Export"];
            }
        });
    });
}
- (void)showError:(NSError *)error operation:(NSString *)operation {
    if ([error.domain isEqual:NSSystemRulesLockedErrorDomain] ||
        [error.domain isEqual:NSAppRulesLockedErrorDomain]) {
        [self showRulesLockedForSystem:[error.domain isEqual:NSSystemRulesLockedErrorDomain]];
        return;
    }
    self.message = [NSString stringWithFormat:@"%@: %@ (%@ %ld).", operation, error.localizedDescription,
                                              error.domain, (long)error.code];
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if ([operation isEqual:@"Export"] && underlying) {
        self.message = [self.message stringByAppendingFormat:@" Underlying: %@ (%@ %ld).",
                                                             underlying.localizedDescription,
                                                             underlying.domain, (long)underlying.code];
    }
    [self refreshTableKeepingPosition];
}
- (void)showRulesLockedForSystem:(BOOL)system {
    [self.tableView setEditing:NO animated:YES];
    NSString *message = system ? NSSystemRulesLockedMessage : NSAppRulesLockedMessage;
    UIViewController *presented = self.presentedViewController;
    if ([presented isKindOfClass:UIAlertController.class] &&
        [((UIAlertController *)presented).message isEqual:message]) {
        return;
    }
    void (^present)(void) = ^{
        UIAlertController *notice =
            [UIAlertController alertControllerWithTitle:system ? @"System Rules Locked" : @"App Rules Locked"
                                                message:message
                                         preferredStyle:UIAlertControllerStyleAlert];
        [notice addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:notice animated:YES completion:nil];
    };
    if ([presented isKindOfClass:NSRuleActionController.class]) {
        [(NSRuleActionController *)presented finishRuleSelectionWithRules:nil message:nil];
    }
    if (presented) {
        [self dismissViewControllerAnimated:YES completion:present];
    } else {
        present();
    }
}
- (void)performStorageCommand:(BOOL (^)(NSError **))work completion:(void (^)(BOOL, NSError *))completion {
    if (self.busy || self.importPending) {
        completion(NO, [NSError errorWithDomain:@"NetShield2.Storage"
                                           code:EBUSY
                                       userInfo:@{
                                           NSLocalizedDescriptionKey :
                                               @"Another operation is in progress. Try again shortly."
                                       }]);
        return;
    }
    NSConfigurationCoordinator *owner = [NSConfigurationCoordinator new];
    NSError *admissionError = nil;
    if (![owner begin:&admissionError]) {
        completion(NO, admissionError);
        return;
    }
    NSConfigurationAccess *access = owner.localAccess;
    if (!access) {
        [owner finish];
        completion(NO, owner.markerError);
        return;
    }
    self.busy = YES;
    self.storageGeneration++;
    [self refreshTableKeepingPosition];
    dispatch_async(NSAppStorageQueue(), ^{
        NSError *error = nil;
        BOOL saved = [access
            perform:^BOOL(NSSharedDirectory *directory, NSError **localError) {
                return work(localError);
            }
              error:&error];
        if (!saved && !error) {
            error = [NSError errorWithDomain:@"NetShield2.Storage"
                                        code:1
                                    userInfo:@{
                                        NSLocalizedDescriptionKey :
                                            @"Saved state is unavailable or the operation did not persist."
                                    }];
        }
        NSError *readError = nil;
        NSPolicy *persisted = NSReadPolicy(&readError);
        dispatch_async(dispatch_get_main_queue(), ^{
            [owner finish];
            self.busy = NO;
            self.storageGeneration++;
            if (persisted) {
                self.policy = persisted;
            }
            self.globalRulesAwaitingReadback = !persisted;
            self.policyMissing = !persisted && NSFileIsAbsent(readError);
            self.policyReadError = persisted ? @"" : readError.localizedDescription;
            self.presentationRefreshPending = YES;
            completion(saved, error);
            [self reloadMonitor];
            if (self.configurationRefreshPending && !self.busy && !self.importPending) {
                [self loadConfiguration];
            }
        });
    });
}
- (void)updatePolicy:(BOOL (^)(NSMutableDictionary *, NSError **))mutation
          completion:(void (^)(BOOL))completion {
    [self
        performStorageCommand:^BOOL(NSError **error) {
            return NSUpdatePolicy(mutation, error);
        }
        completion:^(BOOL saved, NSError *error) {
            if (saved) {
                NSRemoveAutomaticallyManagedNotifications();
                self.message = @"Policy saved for new flows. Close existing connections and retry; admitted "
                               @"flows keep their previous verdict.";
            } else {
                [self showError:error];
            }
            if (completion) {
                completion(saved);
            }
        }];
}
- (void)removeAppRuleForIdentity:(NSString *)identity completion:(void (^)(BOOL))completion {
    if (!NSIdentityRuleEditAllowed(self.policy.document, NSIsAppleSystemIdentity(identity), NULL)) {
        if (completion) {
            completion(NO);
        }
        [self showRulesLockedForSystem:NSIsAppleSystemIdentity(identity)];
        return;
    }
    [self
        updatePolicy:^BOOL(NSMutableDictionary *document, NSError **error) {
            if (!NSIdentityRuleEditAllowed(document, NSIsAppleSystemIdentity(identity), error)) {
                return NO;
            }
            return NSUseDefaultRule(document, identity, error);
        }
        completion:^(BOOL saved) {
            if (saved) {
                NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
                NSMutableSet *hidden =
                    [NSMutableSet setWithArray:[defaults stringArrayForKey:@"hiddenRuleIdentities"] ?: @[]];
                [hidden addObject:identity];
                [defaults setObject:hidden.allObjects forKey:@"hiddenRuleIdentities"];
            }
            if (completion) {
                completion(saved);
            }
        }];
}
- (void)clearSectionTapped:(UIButton *)sender {
    if (self.busy || self.importPending || self.clearingSection) {
        return;
    }
    NSInteger section = sender.tag;
    BOOL activity = section == NSDashboardSectionActivity;
    BOOL global = section == NSDashboardSectionGlobalRules;
    BOOL system = section == NSDashboardSectionSystemRules;
    BOOL identityRules = system || section == NSDashboardSectionRules;
    if (identityRules && !NSIdentityRuleEditAllowed(self.policy.document, system, NULL)) {
        [self showRulesLockedForSystem:system];
        return;
    }
    NSString *name = activity ? @"Recent Activity"
                     : global ? @"Global Rules"
                     : system ? @"System Rules"
                              : @"App Rules";
    self.clearingSection = YES;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"Clear %@?", name]
                         message:[NSString stringWithFormat:
                                               @"All saved items in %@ will be removed%@", name,
                                               activity ? @". The search does not limit what is cleared. New "
                                                          @"activity can appear as connections continue."
                                                        : @""]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *action) {
                                                self.clearingSection = NO;
                                                [self refreshTableKeepingPosition];
                                            }]];
    [alert
        addAction:[UIAlertAction
                      actionWithTitle:@"Clear"
                                style:UIAlertActionStyleDestructive
                              handler:^(UIAlertAction *action) {
                                  NSMutableSet *removed = [NSMutableSet new];
                                  [self
                                      performStorageCommand:^BOOL(NSError **error) {
                                          if (activity) {
                                              return NSClearActivity(error);
                                          }
                                          return NSUpdatePolicy(
                                              ^BOOL(NSMutableDictionary *document, NSError **mutationError) {
                                                  if (identityRules && !NSIdentityRuleEditAllowed(
                                                                           document, system, mutationError)) {
                                                      return NO;
                                                  }
                                                  if (global) {
                                                      document[@"globalRules"] = @{};
                                                      return YES;
                                                  }
                                                  NSArray *identities = NSClearIdentityRules(
                                                      document, system, NSReadMonitor()[@"events"] ?: @[],
                                                      mutationError);
                                                  if (!identities) {
                                                      return NO;
                                                  }
                                                  [removed addObjectsFromArray:identities];
                                                  return YES;
                                              },
                                              error);
                                      }
                                      completion:^(BOOL saved, NSError *error) {
                                          self.clearingSection = NO;
                                          if (!saved) {
                                              [self showError:error
                                                    operation:[@"Clear " stringByAppendingString:name]];
                                              return;
                                          }
                                          if (removed.count) {
                                              NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
                                              NSMutableSet *hidden = [NSMutableSet
                                                  setWithArray:[defaults
                                                                   stringArrayForKey:@"hiddenRuleIdentities"]
                                                                   ?: @[]];
                                              [hidden unionSet:removed];
                                              [defaults setObject:hidden.allObjects
                                                           forKey:@"hiddenRuleIdentities"];
                                          }
                                          if (!activity) {
                                              NSRemoveAutomaticallyManagedNotifications();
                                          }
                                          self.message = [NSString stringWithFormat:@"%@ cleared.", name];
                                      }];
                              }]];
    [self presentViewController:alert animated:YES completion:nil];
    [self refreshTableKeepingPosition];
}
- (void)chooseActionForIdentity:(NSString *)identity defaultKey:(NSString *)key {
    [self chooseActionForIdentity:identity defaultKey:key connection:nil];
}
- (void)chooseActionForIdentity:(NSString *)identity
                     defaultKey:(NSString *)key
                     connection:(NSDictionary *)connection {
    if (!self.policy) {
        return;
    }
    if (!key && !connection &&
        !NSIdentityRuleEditAllowed(self.policy.document, NSIsAppleSystemIdentity(identity), NULL)) {
        [self showRulesLockedForSystem:NSIsAppleSystemIdentity(identity)];
        return;
    }
    NSString *fullName = NSIdentityFullDisplayName(identity);
    NSString *title = fullName.length ? fullName : @"Unidentified app";
    NSString *explanation = nil;
    NSArray *actions = [NSDirectionRuleValues() arrayByAddingObject:@"remove"];
    if ([key isEqual:@"default"]) {
        title = @"Default Rule";
        explanation = @"Choose what happens when an app without a saved rule connects. Ask me lets you "
                      @"decide from a notification.";
        actions = @[ @"ask", @"allow", @"block" ];
    } else if ([key isEqual:@"unattributed"]) {
        title = @"Unidentified";
        explanation = @"These connections have no app identity from iOS. Ask Me prompts for each unresolved "
                      @"connection, and unanswered connections are blocked after 30 seconds.";
        actions = @[ @"allow", @"block", @"ask" ];
    }
    if (connection) {
        actions = NSConnectionRuleValues(connection[@"direction"]);
    }
    if (connection && !identity.length) {
        actions = @[];
        explanation =
            @"iOS did not provide an app identity. A custom rule can match this connection's endpoints.";
    }
    NSRuleActionController *alert = [NSRuleActionController controllerWithTitle:title message:explanation];
    if (connection) {
        alert.detailRows = NSActivityDetailRows(connection);
        alert.processNameUnavailable = !fullName.length;
        alert.clipboardText = NSActivityClipboardLine(connection);
        alert.connectionLayout = YES;
    } else if (!key && fullName.length) {
        alert.titleCopyText = title;
    }
    alert.centersTitle = !key;
    alert.opensAtMediumDetent =
        connection != nil || [key isEqual:@"default"] || [key isEqual:@"unattributed"];
    alert.opensExpanded = !alert.opensAtMediumDetent;
    alert.selectedRule = key ? self.policy.document[key] : nil;
    alert.selectedRules = key ? @[] : NSAppRuleSelections(self.policy.document[@"rules"][identity ?: @""]);
    alert.keepsRuleSelectionsOpen = !key && !connection;
    alert.allowsRuleDeselection = !key && !connection;
    if (alert.allowsRuleDeselection) {
        self.ruleEditor = alert;
        self.editingRuleIdentity = identity;
    }
    __weak NSRuleActionController *weakAlert = alert;
    for (NSString *action in actions) {
        [alert
            addActionWithTitle:[self ruleTitle:action]
                          rule:action
                       handler:^{
                           if (!key && !NSIdentityRuleEditAllowed(self.policy.document,
                                                                  NSIsAppleSystemIdentity(identity), NULL)) {
                               [weakAlert finishRuleSelectionWithRules:nil message:nil];
                               [self showRulesLockedForSystem:NSIsAppleSystemIdentity(identity)];
                               return;
                           }
                           if (!key && [action isEqual:@"remove"]) {
                               [self removeAppRuleForIdentity:identity completion:nil];
                               return;
                           }
                           BOOL ready = self.preferencesLoaded && self.configurationReady;
                           BOOL enabled = self.savedEnabled;
                           NSInteger engine = self.savedEngine;
                           NSString *activation = self.savedActivation;
                           __block NSArray<NSString *> *committedRules = nil;
                           [self
                               updatePolicy:^BOOL(NSMutableDictionary *document, NSError **error) {
                                   if (!key && !NSIdentityRuleEditAllowed(
                                                   document, NSIsAppleSystemIdentity(identity), error)) {
                                       return NO;
                                   }
                                   if ([key isEqual:@"unattributed"]) {
                                       return NSSetUnidentifiedMode(document, action, ready, enabled, engine,
                                                                    activation, error);
                                   }
                                   if (key) {
                                       document[key] = action;
                                   } else {
                                       if (!connection) {
                                           if (!NSToggleAppRule(document, identity, action, error)) {
                                               return NO;
                                           }
                                           // Capture while locked; publish only after the save succeeds.
                                           committedRules =
                                               [NSAppRuleSelections(document[@"rules"][identity]) copy];
                                           return YES;
                                       }
                                       NSMutableDictionary *rules = document[@"rules"];
                                       rules[identity] = NSAppRuleBySelecting(rules[identity], action);
                                   }
                                   return YES;
                               }
                               completion:^(BOOL saved) {
                                   if (!key && !connection) {
                                       [weakAlert finishRuleSelectionWithRules:saved ? committedRules : nil
                                                                       message:saved ? nil : self.message];
                                   }
                               }];
                       }];
    }
    if (!key) {
        if (connection && identity.length && !NSConnectionRuleValues(connection[@"direction"]).count) {
            [alert addActionWithTitle:@"Review App Rule"
                                 rule:nil
                              handler:^{
                                  [self chooseActionForIdentity:identity defaultKey:nil];
                              }];
        }
        [alert addActionWithTitle:@"Add Custom Rule"
                             rule:nil
                          handler:^{
                              [self addCustomRuleForIdentity:identity connection:connection];
                          }];
    }
    [alert addActionWithTitle:(!key && !connection) ? @"Done" : @"Cancel" rule:nil handler:nil];
    [self presentViewController:alert animated:YES completion:nil];
}
- (NSString *)globalRuleConditionText:(NSDictionary *)condition forClipboard:(BOOL)forClipboard {
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    for (NSString *identity in condition[@"identities"]) {
        NSString *name = forClipboard || [identity isEqual:@".com"] ? NSIdentityFullDisplayName(identity)
                                                                    : NSIdentityDisplayName(identity);
        [names addObject:name.length ? name : identity];
    }
    NSMutableArray<NSString *> *labels =
        [NSMutableArray arrayWithObjects:names.count ? [names componentsJoinedByString:@", "] : @"All apps",
                                         [condition[@"destinations"] count]
                                             ? NSGlobalDestinationsText(condition[@"destinations"])
                                             : @"All domains / IPs",
                                         nil];
    NSArray *remotePorts = condition[@"remotePorts"];
    if (remotePorts.count || forClipboard) {
        NSString *ports = remotePorts.count ? NSGlobalPortsText(remotePorts) : @"Any port";
        [labels addObject:[@"Remote: " stringByAppendingString:ports]];
    }
    NSArray *localPorts = condition[@"localPorts"];
    if (localPorts.count || forClipboard) {
        NSString *ports = localPorts.count ? NSGlobalPortsText(localPorts) : @"Any port";
        [labels addObject:[@"Local: " stringByAppendingString:ports]];
    }
    NSArray *protocols = condition[@"protocols"];
    NSString *protocolText =
        protocols.count ? [protocols componentsJoinedByString:forClipboard ? @", " : @" & "].uppercaseString
                        : @"Any protocol";
    [labels addObject:forClipboard ? [@"Protocol: " stringByAppendingString:protocolText] : protocolText];
    return [labels componentsJoinedByString:@"\n"];
}
- (NSString *)globalRuleTitle:(NSString *)key {
    return [self globalRuleConditionText:NSGlobalRuleCondition(key) forClipboard:NO];
}
- (NSString *)globalRuleClipboardText:(NSString *)key action:(NSString *)action {
    NSDictionary *condition = NSGlobalRuleCondition(key);
    NSString *direction = [condition[@"direction"] isEqual:@"both"]
                              ? @"Incoming and outgoing"
                              : [condition[@"direction"] capitalizedString];
    return [NSString stringWithFormat:@"Global Rule\n%@\nAction: %@\nDirection: %@\nResolve domains: %@",
                                      [self globalRuleConditionText:condition forClipboard:YES],
                                      [self ruleTitle:action], direction,
                                      [condition[@"resolveDomains"] boolValue] ? @"Yes" : @"No"];
}
- (void)addCustomRuleForIdentity:(NSString *)identity connection:(NSDictionary *)connection {
    NSString *action =
        NSAppRuleSelections(self.policy.document[@"rules"][identity ?: @""]).firstObject ?: @"allow";
    NSDictionary *destination = @{};
    if (connection) {
        NSDictionary *peer = connection[@"destination"];
        NSMutableDictionary *draftDestination =
            [NSCanonicalConnectionDestination([peer isKindOfClass:NSDictionary.class] ? peer : @{})
                mutableCopy];
        BOOL incoming = [connection[@"direction"] isEqual:@"inbound"];
        BOOL outgoing = [connection[@"direction"] isEqual:@"outbound"];
        // Use the preferred endpoint and the directional port in the editor draft.
        if (draftDestination[@"domain"]) {
            [draftDestination removeObjectForKey:@"address"];
        }
        if (incoming) {
            [draftDestination removeObjectForKey:@"port"];
        } else if (outgoing) {
            [draftDestination removeObjectForKey:@"localPort"];
        }
        destination = draftDestination;
        if ([connection[@"connections"] unsignedIntegerValue] <= 1) {
            BOOL blocked = [@[ @"block", @"permission-block" ] containsObject:connection[@"action"] ?: @""];
            action = incoming   ? (blocked ? @"block-inbound" : @"allow-inbound")
                     : outgoing ? (blocked ? @"block-outbound" : @"allow-outbound")
                                : (blocked ? @"block" : @"allow");
        }
    }
    NSString *initialKey =
        NSExactGlobalRuleKey(identity.length ? @[ identity ] : @[], destination, NSGlobalCoverage(action));
    [self editGlobalRule:nil initialKey:initialKey action:action];
}
- (void)editGlobalRule:(NSString *)original {
    [self editGlobalRule:original initialKey:nil action:nil];
}
- (void)editGlobalRule:(NSString *)original
            initialKey:(NSString *)initialKey
                action:(NSString *)initialAction {
    if (original && (self.globalRulesAwaitingReadback || !self.policy.document[@"globalRules"][original])) {
        [self refreshTableKeepingPosition];
        [self reloadMonitor];
        return;
    }
    if (!self.policy || self.busy || self.importPending) {
        return;
    }
    NSGlobalRuleEditor *editor = [[NSGlobalRuleEditor alloc] initWithStyle:UITableViewStyleInsetGrouped];
    NSMutableSet *identities = [NSMutableSet setWithArray:self.identities ?: @[]];
    [identities addObjectsFromArray:self.systemIdentities ?: @[]];
    for (NSString *key in self.policy.document[@"globalRules"]) {
        [identities addObjectsFromArray:NSGlobalRuleCondition(key)[@"identities"] ?: @[]];
    }
    editor.identities =
        [identities.allObjects sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    editor.originalKey = original;
    editor.initialKey = initialKey;
    editor.originalAction = original ? self.policy.document[@"globalRules"][original] : initialAction;
    __weak typeof(self) weakSelf = self;
    editor.saveRule = ^(NSString *key, NSString *action, void (^finished)(NSError *)) {
        NSDashboard *owner = weakSelf;
        if (!owner) {
            finished([NSError errorWithDomain:@"NetShield2.Storage" code:1 userInfo:nil]);
            return;
        }
        [owner
            performStorageCommand:^BOOL(NSError **error) {
                return NSUpdatePolicy(
                    ^BOOL(NSMutableDictionary *document, NSError **mutationError) {
                        NSMutableDictionary *rules =
                            [document[@"globalRules"] mutableCopy] ?: [NSMutableDictionary new];
                        if (!NSValidateGlobalRuleChange(rules, key, action, original, mutationError)) {
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
            }
            completion:^(BOOL saved, NSError *error) {
                if (saved) {
                    NSRemoveAutomaticallyManagedNotifications();
                    owner.message = @"Global rule saved for new connections";
                }
                finished(error);
            }];
    };
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:editor];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:navigation animated:YES completion:nil];
}
- (NSString *)ruleTitle:(NSString *)rule {
    return NSDirectionRuleTitle(rule ?: @"") ?: @{@"ask" : @"Ask Me", @"remove" : @"Remove Rule"}[rule ?: @""] ?: @"Default Rule";
}
- (void)firewallChanged:(UISwitch *)sender {
    if (self.busy || self.importPending || !self.preferencesLoaded || !self.configurationReady) {
        return;
    }
    if (!sender.on) {
        [self changeConfiguration:NSConfigurationDisable];
        return;
    }
    if (!self.policy) {
        // This explicit On can recover an idle reservation left before policy
        // bootstrap. Passive refreshes cannot take another operation's token.
        [self
            performStorageCommand:^BOOL(NSError **error) {
                NSSharedDirectory *directory = [NSSharedDirectory openRoot:NSSharedURL(@"")
                                                                      leaf:NSPolicyFile
                                                                     error:error];
                return directory && NSEnsurePolicyIn(directory, error);
            }
            completion:^(BOOL saved, NSError *error) {
                if (saved) {
                    [self firewallChanged:sender];
                } else {
                    [self showError:error operation:@"Prepare Firewall rules"];
                    [self refreshSavedState];
                }
            }];
        return;
    }
    NSRemoveAutomaticallyManagedNotifications();
    self.attemptedProviderUpgrade = YES;
    self.configurationOperationError = nil;
    self.configurationOperationAction = NSConfigurationRecoveryNone;
    self.message = nil;
    self.configurationProgress = @"Waiting for notification permission…";
    self.busy = YES;
    [self refreshTableKeepingPosition];
    NSUInteger generation = ++self.enableIntentGeneration;
    NSTimeInterval expiresAt = NSProcessInfo.processInfo.systemUptime + 60;
    __weak typeof(self) weakSelf = self;
    dispatch_block_t expiry = dispatch_block_create(0, ^{
        NSDashboard *owner = weakSelf;
        if (!owner || owner.enableIntentGeneration != generation) {
            return;
        }
        owner.enableIntentGeneration++;
        owner.busy = NO;
        owner.configurationProgress = nil;
        owner.configurationOperationError =
            @"Notification authorization timed out before the Firewall change started.";
        owner.configurationOperationAction = NSConfigurationRecoveryRetryEnable;
        NSLog(@"NetShield2 notification-authorization timed out");
        [owner loadConfiguration];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), expiry);
    [self authorizeNotificationsThen:^{
        NSDashboard *owner = weakSelf;
        if (!owner || owner.enableIntentGeneration != generation) {
            return;
        }
        if (NSProcessInfo.processInfo.systemUptime >= expiresAt) {
            expiry();
            return;
        }
        dispatch_block_cancel(expiry);
        owner.busy = NO;
        [owner changeConfiguration:NSConfigurationEnable];
    }];
}
- (void)appleSystemProcessesChanged:(UISwitch *)sender {
    BOOL allow = sender.on;
    [sender setOn:NSAppleSystemTrafficEnabled(self.policy.document) animated:NO];
    if (!self.policy || self.busy || self.importPending ||
        ![self.policy.document[@"filterSockets"] boolValue]) {
        [self refreshTableKeepingPosition];
        return;
    }
    [self
        updatePolicy:^BOOL(NSMutableDictionary *document, NSError **error) {
            document[@"allowAppleSystemProcesses"] =
                allow && [document[@"filterSockets"] boolValue] ? @YES : @NO;
            document[@"blockAppleSystemTelemetry"] = @NO;
            return YES;
        }
        completion:^(BOOL saved) {
            [self refreshTableKeepingPosition];
        }];
    [self refreshTableKeepingPosition];
}
- (void)appleSystemTelemetryChanged:(UISwitch *)sender {
    BOOL block = sender.on;
    [sender setOn:NSAppleSystemTrafficEnabled(self.policy.document) &&
                  [self.policy.document[@"blockAppleSystemTelemetry"] boolValue]
         animated:NO];
    if (!self.policy || self.busy || self.importPending ||
        !NSAppleSystemTrafficEnabled(self.policy.document)) {
        [self refreshTableKeepingPosition];
        return;
    }
    [self
        updatePolicy:^BOOL(NSMutableDictionary *document, NSError **error) {
            document[@"blockAppleSystemTelemetry"] =
                block && NSAppleSystemTrafficEnabled(document) ? @YES : @NO;
            if ([document[@"blockAppleSystemTelemetry"] boolValue]) {
                document[@"appleSystemTelemetryIntroduced"] = @YES;
            }
            return YES;
        }
        completion:^(BOOL saved) {
            [self refreshTableKeepingPosition];
        }];
    [self refreshTableKeepingPosition];
}
- (void)thirdPartyProcessesChanged:(UISwitch *)sender {
    BOOL allow = sender.on;
    [sender setOn:NSThirdPartyTrafficEnabled(self.policy.document) animated:NO];
    if (!self.policy || self.busy || self.importPending ||
        ![self.policy.document[@"filterSockets"] boolValue]) {
        [self refreshTableKeepingPosition];
        return;
    }
    [self
        updatePolicy:^BOOL(NSMutableDictionary *document, NSError **error) {
            document[@"allowThirdPartyProcesses"] =
                allow && [document[@"filterSockets"] boolValue] ? @YES : @NO;
            return YES;
        }
        completion:^(BOOL saved) {
            [self refreshTableKeepingPosition];
        }];
    [self refreshTableKeepingPosition];
}
- (void)openSupportURL:(NSURL *)url {
    [self openSupportURL:url warningCancelled:nil];
}
- (void)openSupportURL:(NSURL *)url warningCancelled:(void (^)(void))warningCancelled {
    void (^presentOrOpen)(void) = ^{
        if (![NEFilterManager sharedManager].enabled) {
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
            return;
        }
        UIAlertController *notice = [UIAlertController
            alertControllerWithTitle:@"Firewall is ON so link may fail"
                             message:@"If the link fails to open or load, return to NetShield2 and tap "
                                     @"Allow before trying to open the link again. Banner notifications "
                                     @"are suppressed while in NetShield2 app."
                      preferredStyle:UIAlertControllerStyleAlert];
        [notice addAction:[UIAlertAction actionWithTitle:@"Open link"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *action) {
                                                     [UIApplication.sharedApplication openURL:url
                                                                                      options:@{}
                                                                            completionHandler:nil];
                                                 }]];
        __weak UIAlertController *weakNotice = notice;
        [notice
            addAction:
                [UIAlertAction
                    actionWithTitle:@"Cancel"
                              style:UIAlertActionStyleCancel
                            handler:^(UIAlertAction *action) {
                                if (!warningCancelled) {
                                    return;
                                }
                                void (^afterDismissal)(void) = ^{
                                    dispatch_async(dispatch_get_main_queue(), ^{
                                        if (self.navigationController.topViewController == self &&
                                            self.view.window && !self.presentedViewController &&
                                            !self.isBeingDismissed) {
                                            warningCancelled();
                                        }
                                    });
                                };
                                // UIAlertController starts its own dismissal after the action.
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    UIAlertController *warning = weakNotice;
                                    id<UIViewControllerTransitionCoordinator> transition =
                                        warning.transitionCoordinator;
                                    if (transition &&
                                        [transition
                                            animateAlongsideTransition:nil
                                                            completion:^(
                                                                id<UIViewControllerTransitionCoordinatorContext>
                                                                    context) {
                                                                afterDismissal();
                                                            }]) {
                                        return;
                                    }
                                    if (warning.presentingViewController) {
                                        [warning dismissViewControllerAnimated:YES completion:afterDismissal];
                                    } else {
                                        afterDismissal();
                                    }
                                });
                            }]];
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
                                  __weak typeof(self) weakSelf = self;
                                  [self openSupportURL:[NSURL URLWithString:@"https://venmo.com/u/EolnMsuk"]
                                      warningCancelled:^{
                                          [weakSelf supportDeveloper];
                                      }];
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
                         message:@"Touch and hold a NetShield2 notification, then choose Allow or "
                                 @"Block for the connection direction. Tapping the notification body opens "
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
