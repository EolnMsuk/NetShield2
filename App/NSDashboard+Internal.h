#import "NSDashboard.h"
#import <NetworkExtension/NetworkExtension.h>
#import "../Shared/NSStore.h"
#import "../Shared/NSNotifications.h"
#import "../Shared/NSDestination.h"

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
    NSDashboardSectionRules,
    NSDashboardSectionActivity,
    NSDashboardSectionCount,
};

@interface NSDashboard ()
@property(nonatomic, strong) NSPolicy *policy;
@property(nonatomic, copy) NSString *policyReadError;
@property(nonatomic, copy) NSDictionary *monitor;
@property(nonatomic, copy) NSArray<NSString *> *identities;
@property(nonatomic, copy) NSString *message;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) UITableViewCell *firewallCell;
@property(nonatomic, strong) UITableViewCell *appleCell;
@property(nonatomic, copy) NSArray *displayedRows;
@property(nonatomic, copy) NSArray *displaySignature;
@property(nonatomic, strong) NSMutableDictionary *rowHeights;
@property(nonatomic, weak) UIAlertController *permissionAlert;
@property(nonatomic, copy) NSDictionary *presentedRequest;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL loaded;
@property(nonatomic) BOOL attemptedProviderUpgrade;
@property(nonatomic) BOOL resetRequiresLegacyStop;
@property(nonatomic) BOOL resetAllSettings;
@property(nonatomic) BOOL restoreFirewallAfterReset;
@property(nonatomic, strong) NSMutableSet<NSString *> *deferredRequests;
@property(nonatomic, copy) NSString *notificationStatus;
- (void)reloadMonitor;
- (BOOL)hasFreshMonitor;
- (void)chooseActionForIdentity:(NSString *)identity defaultKey:(NSString *)key;
- (void)addIdentity;
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
- (void)answerRequest:(NSDictionary *)request allow:(BOOL)allow;
- (void)presentRequest:(NSDictionary *)request;
@end

@interface NSDashboard (Table)
- (void)refreshTableKeepingPosition;
@end
