#import "NSDashboard.h"
#import <NetworkExtension/NetworkExtension.h>
#import "../Shared/NSStore.h"
#import "../Shared/NSNotifications.h"
#import "../Shared/NSDestination.h"
#import "../Shared/NSIdentityDisplay.h"
#import "../Shared/NSAppPreferences.h"
#import "NSFilterRestart.h"
#import "NSFilterBootPolicy.h"
#import "NSRuleActionController.h"
#import "NSRuleAppearance.h"
#import "NSReleaseFetch.h"
#import "NSAppStorage.h"

typedef NS_ENUM(NSInteger, NSConfigurationOperation) {
    NSConfigurationDisable,
    NSConfigurationEnable,
    NSConfigurationApplyScope,
};
typedef NS_ENUM(NSInteger, NSDashboardSection) {
    NSDashboardSectionFirewall,
    NSDashboardSectionRequests,
    NSDashboardSectionNotifications,
    NSDashboardSectionAdvanced,
    NSDashboardSectionSupport,
    NSDashboardSectionAddGlobalRule,
    NSDashboardSectionGlobalRules,
    NSDashboardSectionSystemRules,
    NSDashboardSectionRules,
    NSDashboardSectionActivity,
    NSDashboardSectionCount,
};

@interface NSDashboard () <UISearchBarDelegate, UIGestureRecognizerDelegate>
@property(nonatomic, strong) NSPolicy *policy;
@property(nonatomic, copy) NSString *policyReadError;
@property(nonatomic) BOOL policyMissing;
@property(nonatomic) BOOL policyBootstrapPending;
@property(nonatomic, copy) NSDictionary *monitor;
@property(nonatomic, copy) NSArray<NSDictionary *> *activityGroups;
@property(nonatomic, copy) NSArray<NSDictionary *> *filteredActivityGroups;
@property(nonatomic, copy) NSString *activityQuery;
@property(nonatomic, strong) UISearchBar *activitySearchBar;
@property(nonatomic, strong) UIView *activityHeader;
@property(nonatomic) BOOL activityHeaderHasClear;
@property(nonatomic, strong) UITapGestureRecognizer *navigationKeyboardDismissGesture;
@property(nonatomic, weak) UIButton *activityClearButton;
@property(nonatomic) BOOL clearingSection;
@property(nonatomic, copy) NSArray<NSString *> *identities;
@property(nonatomic, copy) NSArray<NSString *> *systemIdentities;
@property(nonatomic, weak) NSRuleActionController *ruleEditor;
@property(nonatomic, copy) NSString *editingRuleIdentity;
@property(nonatomic, copy) NSArray<NSString *> *globalRuleKeys;
@property(nonatomic, copy) NSString *message;
@property(nonatomic, copy) NSString *bootPolicyStatus;
@property(nonatomic) BOOL bootPolicyNeedsAttention;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSReleaseFetch *updateTask;
@property(nonatomic) BOOL updateCheckWasManual;
@property(nonatomic) NSUInteger updateGeneration;
@property(nonatomic) NSUInteger storageGeneration;
@property(nonatomic) BOOL snapshotPending;
@property(nonatomic) BOOL snapshotAgain;
@property(nonatomic) BOOL exportPending;
@property(nonatomic, copy) NSArray *activityEvents;
@property(nonatomic, copy) NSString *monitorReadError;
@property(nonatomic, copy) NSDictionary *pendingUpdateResult;
@property(nonatomic, strong) UITableViewCell *firewallCell;
@property(nonatomic, strong) UITableViewCell *appleCell;
@property(nonatomic, copy) NSArray *displayedRows;
@property(nonatomic, copy) NSArray *displaySignature;
@property(nonatomic, strong) NSMutableDictionary *rowHeights;
@property(nonatomic, weak) UIViewController *permissionAlert;
@property(nonatomic, copy) NSDictionary *presentedRequest;
@property(nonatomic) BOOL busy;
@property(nonatomic) NSUInteger enableIntentGeneration;
@property(nonatomic, copy) NSString *configurationProgress;
@property(nonatomic) BOOL preferencesLoaded;
@property(nonatomic) BOOL hasSavedPreferences;
@property(nonatomic) BOOL savedEnabled;
@property(nonatomic) BOOL savedSocketFiltering;
@property(nonatomic) BOOL savedBrowserFiltering;
@property(nonatomic, copy) NSString *savedActivation;
@property(nonatomic, copy) NSDictionary *savedConfigurationFingerprint;
@property(nonatomic) BOOL configurationReady;
@property(nonatomic, copy) NSString *preferenceReadError;
@property(nonatomic, copy) NSString *configurationRecoveryError;
@property(nonatomic, copy) NSString *configurationOperationError;
@property(nonatomic) NSConfigurationRecoveryAction configurationRecoveryAction;
@property(nonatomic) NSConfigurationRecoveryAction configurationOperationAction;
@property(nonatomic) BOOL attemptedProviderUpgrade;
@property(nonatomic) BOOL automaticMigrationRequested;
@property(nonatomic, strong) NSFilterRestart *restart;
@property(nonatomic, strong) NSConfigurationCoordinator *configuration;
@property(nonatomic) BOOL configurationRefreshPending;
@property(nonatomic) BOOL resetRequiresLegacyStop;
@property(nonatomic) BOOL removeFilterAfterReset;
@property(nonatomic) BOOL respringPromptPending;
@property(nonatomic, strong) NSMutableSet<NSString *> *deferredRequests;
@property(nonatomic, copy) NSString *notificationStatus;
- (void)performStorageCommand:(BOOL (^)(NSError **))work completion:(void (^)(BOOL, NSError *))completion;
- (void)updatePolicy:(BOOL (^)(NSMutableDictionary *, NSError **))mutation
          completion:(void (^)(BOOL))completion;
- (void)removeAppRuleForIdentity:(NSString *)identity completion:(void (^)(BOOL))completion;
- (void)reloadMonitor;
- (void)clearSectionTapped:(UIButton *)sender;
- (BOOL)hasFreshMonitor;
- (void)chooseActionForIdentity:(NSString *)identity defaultKey:(NSString *)key;
- (void)chooseActionForIdentity:(NSString *)identity
                     defaultKey:(NSString *)key
                     connection:(NSDictionary *)connection;
- (void)addCustomRuleForIdentity:(NSString *)identity connection:(NSDictionary *)connection;
- (void)editGlobalRule:(NSString *)original
            initialKey:(NSString *)initialKey
                action:(NSString *)initialAction;
- (void)exportRulesAndRecentActivityFromRow:(NSIndexPath *)path;
- (void)editGlobalRule:(NSString *)original;
- (NSString *)globalRuleTitle:(NSString *)key;
- (NSString *)globalRuleTitle:(NSString *)key fullAppNames:(BOOL)fullAppNames;
- (NSString *)ruleTitle:(NSString *)rule;
- (void)firewallChanged:(UISwitch *)sender;
- (void)appleSystemProcessesChanged:(UISwitch *)sender;
- (void)openSupportURL:(NSURL *)url;
- (void)supportDeveloper;
- (void)showNotificationHelp;
- (void)showError:(NSError *)error;
- (void)showError:(NSError *)error operation:(NSString *)operation;
@end

@interface NSDashboard (Configuration)
- (void)loadConfiguration;
- (void)refreshSavedState;
- (void)loadConfigurationWithCompletion:(void (^)(void))completion;
- (void)changeConfiguration:(NSConfigurationOperation)operation;
- (void)changeConfiguration:(NSConfigurationOperation)operation completion:(void (^)(void))completion;
- (void)refreshThenOfferRespring:(UIBarButtonItem *)sender;
- (void)resetNetShield2;
- (void)socketFilteringChanged:(UISwitch *)sender;
@end

@interface NSDashboard (Notifications)
- (void)refreshNotificationSettings;
- (void)authorizeNotificationsThen:(void (^)(void))completion;
- (void)requestNotifications;
- (void)answerRequest:(NSDictionary *)request rule:(NSString *)rule;
- (void)presentRequest:(NSDictionary *)request;
@end

@interface NSDashboard (Table)
- (void)activityKeyboardFrameDidChange:(NSNotification *)notification;
- (void)dismissActivityKeyboard;
- (void)clearActivitySearch;
- (void)refreshTableKeepingPosition;
- (NSString *)firewallFooterText;
@end

@interface NSDashboard (Updates)
- (void)cancelUpdateCheck;
- (void)checkForUpdateManually:(BOOL)manual;
- (void)presentUpdateOptions;
- (NSString *)updateCheckSubtitle;
- (void)presentPendingUpdateResult;
@end
