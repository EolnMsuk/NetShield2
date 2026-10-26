#import "NSDashboard.h"
#import <NetworkExtension/NetworkExtension.h>
#import "../Shared/NSStore.h"
#import "../Shared/NSNotifications.h"
#import "../Shared/NSDestination.h"
#import "../Shared/NSIdentityDisplay.h"
#import "NSFilterRestart.h"
#import "NSRuleActionController.h"
#import "NSRuleAppearance.h"

typedef NS_ENUM(NSInteger, NSConfigurationOperation) {
    NSConfigurationDisable,
    NSConfigurationEnable,
    NSConfigurationRemove,
};
typedef NS_ENUM(NSInteger, NSDashboardSection) {
    NSDashboardSectionFirewall,
    NSDashboardSectionRequests,
    NSDashboardSectionNotifications,
    NSDashboardSectionAdvanced,
    NSDashboardSectionSupport,
    NSDashboardSectionGlobalRules,
    NSDashboardSectionRules,
    NSDashboardSectionSystemRules,
    NSDashboardSectionActivity,
    NSDashboardSectionCount,
};

@interface NSDashboard ()
@property(nonatomic, strong) NSPolicy *policy;
@property(nonatomic, copy) NSString *policyReadError;
@property(nonatomic, copy) NSDictionary *monitor;
@property(nonatomic, copy) NSArray<NSDictionary *> *activityGroups;
@property(nonatomic, copy) NSArray<NSString *> *identities;
@property(nonatomic, copy) NSArray<NSString *> *systemIdentities;
@property(nonatomic, copy) NSArray<NSString *> *globalRuleKeys;
@property(nonatomic, copy) NSString *message;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSURLSessionDataTask *updateTask;
@property(nonatomic) BOOL checkedForUpdateOnLaunch;
@property(nonatomic) BOOL updateCheckWasManual;
@property(nonatomic, copy) NSDictionary *pendingUpdateResult;
@property(nonatomic, strong) UITableViewCell *firewallCell;
@property(nonatomic, strong) UITableViewCell *appleCell;
@property(nonatomic, copy) NSArray *displayedRows;
@property(nonatomic, copy) NSArray *displaySignature;
@property(nonatomic, strong) NSMutableDictionary *rowHeights;
@property(nonatomic, weak) UIViewController *permissionAlert;
@property(nonatomic, copy) NSDictionary *presentedRequest;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL loaded;
@property(nonatomic) BOOL attemptedProviderUpgrade;
@property(nonatomic, strong) NSFilterRestart *restart;
@property(nonatomic) BOOL resetRequiresLegacyStop;
@property(nonatomic) BOOL resetAllSettings;
@property(nonatomic) BOOL restoreFirewallAfterReset;
@property(nonatomic, strong) NSMutableSet<NSString *> *deferredRequests;
@property(nonatomic, copy) NSString *notificationStatus;
- (BOOL)updatePolicy:(BOOL (^)(NSMutableDictionary *, NSError **))mutation;
- (BOOL)removeAppRuleForIdentity:(NSString *)identity;
- (void)reloadMonitor;
- (BOOL)hasFreshMonitor;
- (void)chooseActionForIdentity:(NSString *)identity defaultKey:(NSString *)key;
- (void)exportRulesAndRecentActivityFromRow:(NSIndexPath *)path;
- (void)editGlobalRule:(NSString *)original;
- (void)chooseGlobalRule:(NSString *)key;
- (void)chooseGlobalRule:(NSString *)key editingKey:(NSString *)original;
- (NSString *)globalRuleTitle:(NSString *)key;
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
- (void)changeConfiguration:(NSConfigurationOperation)operation;
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
- (void)refreshTableKeepingPosition;
@end

@interface NSDashboard (Updates)
- (void)checkForUpdateManually:(BOOL)manual;
- (void)presentPendingUpdateResult;
@end
