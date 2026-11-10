#import "NSGlobalRuleEditor.h"
#import "NSSectionTypography.h"
#import "NSRuleActionController.h"
#import "NSRuleAppearance.h"
#import "../Shared/NSGlobalRule.h"
#import "../Shared/NSIdentityDisplay.h"
#import "../Shared/NSRuleChoices.h"

typedef NS_ENUM(NSInteger, NSGlobalEditorSection) {
    NSGlobalEditorAction,
    NSGlobalEditorApps,
    NSGlobalEditorHosts,
    NSGlobalEditorPorts,
    NSGlobalEditorProtocol,
};

@class NSGlobalRuleAppButton;

@interface NSGlobalRuleEditor ()
@property(nonatomic, strong) NSMutableSet<NSString *> *selectedIdentities;
@property(nonatomic, weak) NSGlobalRuleAppButton *appButton;
@property(nonatomic, strong) UITextField *hostsField;
@property(nonatomic, strong) UITextField *portsField;
@property(nonatomic) BOOL localPort;
@property(nonatomic, copy) NSString *protocol;
@property(nonatomic, copy) NSString *ruleAction;
- (void)appMenuWillDisplay:(NSGlobalRuleAppButton *)button;
- (void)appMenuDidClose:(NSGlobalRuleAppButton *)button;
- (void)ns_toggleAppCommand:(UICommand *)command;
- (void)ns_selectAllAppsCommand:(UICommand *)command;
@end

@interface NSGlobalRuleAppButton : UIButton
@property(nonatomic, weak) NSGlobalRuleEditor *editor;
@property(nonatomic, getter=isMenuActive) BOOL menuActive;
@property(nonatomic) BOOL refreshAfterDismissal;
@property(nonatomic) BOOL enterIdentityAfterDismissal;
@property(nonatomic, copy) NSString *commandOwnerToken;
@property(nonatomic, copy) NSSet<NSString *> *menuIdentities;
@end

@implementation NSGlobalRuleAppButton {
    NSUInteger _menuPresentation;
}
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction
    willDisplayMenuForConfiguration:(UIContextMenuConfiguration *)configuration
                           animator:(id<UIContextMenuInteractionAnimating>)animator {
    [super contextMenuInteraction:interaction
        willDisplayMenuForConfiguration:configuration
                               animator:animator];
    _menuPresentation++;
    [self.editor appMenuWillDisplay:self];
}
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction
       willEndForConfiguration:(UIContextMenuConfiguration *)configuration
                      animator:(id<UIContextMenuInteractionAnimating>)animator {
    NSUInteger presentation = _menuPresentation;
    [super contextMenuInteraction:interaction willEndForConfiguration:configuration animator:animator];
    __weak typeof(self) weakSelf = self;
    void (^finish)(void) = ^{
        NSGlobalRuleAppButton *button = weakSelf;
        if (button && button->_menuPresentation == presentation) {
            [button.editor appMenuDidClose:button];
        }
    };
    if (animator) {
        [animator addCompletion:finish];
    } else {
        dispatch_async(dispatch_get_main_queue(), finish);
    }
}
@end

static NSString *const NSAppCommandOwnerKey = @"owner";
static NSString *const NSAppCommandIdentityKey = @"identity";

static NSArray<NSString *> *NSSortedAppIdentities(NSSet<NSString *> *identities) {
    return [identities.allObjects
        sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
            return NSCompareIdentityDisplayNames(left, right);
        }];
}

static UIMenuElementState NSAppCommandState(NSSet<NSString *> *selectedIdentities, NSString *identity) {
    BOOL selected = identity ? [selectedIdentities containsObject:identity] : selectedIdentities.count == 0;
    return selected ? UIMenuElementStateOn : UIMenuElementStateOff;
}

static BOOL NSIsAppSelectionAction(SEL action) {
    return action == @selector(ns_toggleAppCommand:) || action == @selector(ns_selectAllAppsCommand:);
}

static NSDictionary<NSString *, NSString *> *NSAppCommandPayload(UICommand *command, SEL action,
                                                                 NSGlobalRuleAppButton *button) {
    if (![command isKindOfClass:UICommand.class] || command.action != action ||
        ![command.propertyList isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    NSDictionary<NSString *, NSString *> *payload = command.propertyList;
    NSString *owner = payload[NSAppCommandOwnerKey];
    if (![owner isKindOfClass:NSString.class] || ![button.commandOwnerToken isEqualToString:owner]) {
        return nil;
    }
    if (action == @selector(ns_selectAllAppsCommand:)) {
        return payload.count == 1 ? payload : nil;
    }
    NSString *identity = payload[NSAppCommandIdentityKey];
    BOOL valid = action == @selector(ns_toggleAppCommand:) && payload.count == 2 &&
                 [identity isKindOfClass:NSString.class] && [button.menuIdentities containsObject:identity];
    return valid ? payload : nil;
}

@implementation NSGlobalRuleEditor
- (UITextField *)fieldWithPlaceholder:(NSString *)placeholder label:(NSString *)label {
    UITextField *field = [UITextField new];
    field.placeholder = placeholder;
    field.accessibilityLabel = label;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    field.keyboardType = UIKeyboardTypeASCIICapable;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    field.adjustsFontForContentSizeCategory = YES;
    return field;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.originalKey ? @"Edit Custom Rule" : @"Add a Custom Rule";
    self.modalInPresentation = YES;
    self.navigationController.modalInPresentation = YES;
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self
                                                      action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                      target:self
                                                      action:@selector(save)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.selectedIdentities = [NSMutableSet new];
    self.hostsField = [self fieldWithPlaceholder:@"All domains and IPs" label:@"Domains or IP ranges"];
    self.portsField = [self fieldWithPlaceholder:@"All ports" label:@"Port numbers"];
    self.protocol = @"any";
    self.ruleAction = self.originalAction ?: @"allow";
    NSArray *parts = NSCustomGlobalRuleComponents(self.originalKey ?: self.initialKey);
    NSString *hosts = @"", *ports = @"";
    if (parts) {
        [self.selectedIdentities addObjectsFromArray:NSCustomGlobalRuleIdentities(parts)];
        hosts = parts[1];
        ports = parts[2];
        self.protocol = parts[3];
    } else if (self.originalKey) {
        NSString *first = NSGlobalRuleMembers(self.originalKey).firstObject;
        if ([first hasPrefix:@"port:"] || [first hasPrefix:@"localPort:"]) {
            ports = self.originalKey;
        } else {
            hosts = self.originalKey;
        }
    }
    self.hostsField.text = hosts.length ? NSGlobalRuleInputText(hosts) : @"";
    self.portsField.text = ports.length ? NSGlobalRuleInputText(ports) : @"";
    self.localPort = ports.length ? [NSGlobalRuleMembers(ports).firstObject hasPrefix:@"localPort:"]
                                  : self.initialKey && [@[ @"allow-inbound", @"block-inbound" ]
                                                           containsObject:self.ruleAction];
}
- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)showMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Unable to save rule"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)save {
    [self.view endEditing:YES];
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSString *hostText = [self.hostsField.text stringByTrimmingCharactersInSet:whitespace] ?: @"";
    NSString *portText = [self.portsField.text stringByTrimmingCharactersInSet:whitespace] ?: @"";
    NSString *hosts = hostText.length ? NSGlobalInputRuleKey(hostText, NO, NO) : @"";
    NSString *ports = portText.length ? NSGlobalInputRuleKey(portText, YES, self.localPort) : @"";
    if (!hosts) {
        [self showMessage:
                  @"Enter exact domains, IPv4/IPv6 addresses, or ascending IP ranges separated by commas. Do "
                  @"not include URLs or empty entries. Maximum 4096 entries across all rules."];
        return;
    }
    if (!ports) {
        [self showMessage:
                  @"Enter port numbers from 1 to 65535 separated by commas, or leave blank for all ports."];
        return;
    }
    NSString *key = NSDirectionalGlobalRuleKey(self.selectedIdentities.allObjects, hosts, ports,
                                               self.protocol, self.ruleAction);
    if (!NSValidGlobalRuleKey(key)) {
        [self showMessage:@"The app identity is too long or this rule contains too many entries."];
        return;
    }
    if (!self.saveRule || !self.navigationItem.rightBarButtonItem.enabled) {
        return;
    }
    self.navigationItem.rightBarButtonItem.enabled = NO;
    self.navigationItem.leftBarButtonItem.enabled = NO;
    __weak typeof(self) weakSelf = self;
    self.saveRule(key, self.ruleAction, ^(NSError *error) {
        NSGlobalRuleEditor *owner = weakSelf;
        if (!owner) {
            return;
        }
        owner.navigationItem.rightBarButtonItem.enabled = YES;
        owner.navigationItem.leftBarButtonItem.enabled = YES;
        if (error) {
            [owner
                showMessage:error.localizedDescription ?: @"The rule could not be saved. Please try again."];
        } else {
            [owner dismissViewControllerAnimated:YES completion:nil];
        }
    });
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 5;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == NSGlobalEditorPorts ? 2 : 1;
}
- (void)tableView:(UITableView *)tableView
    willDisplayHeaderView:(UIView *)view
               forSection:(NSInteger)section {
    NSStyleSectionHeader(view);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[ @"Direction", @"App", @"Domains / IP ranges", @"Port", @"Protocol" ][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @[
        @"Saved in Global Rules, overriding app rules and the iOS system allowance.",
        @"Select one or more apps. Tap a checked app to remove it, or choose All apps to clear the selection.",
        @"Separate entries with commas, e.g. example.com, 192.168.1.10-192.168.1.20. Blank means all destinations.",
        @"Choose remote or local, then enter port numbers separated by commas. Blank means all ports.",
        @"UDP & TCP covers all protocols available."
    ][section];
}
- (UIMenu *)menuForValues:(NSArray<NSString *> *)values
                   titles:(NSArray<NSString *> *)titles
                 selected:(NSString *)selected
                   change:(void (^)(NSString *))change {
    NSMutableArray *actions = [NSMutableArray new];
    for (NSUInteger index = 0; index < values.count; index++) {
        NSString *value = values[index];
        UIAction *action = [UIAction actionWithTitle:titles[index]
                                               image:nil
                                          identifier:nil
                                             handler:^(UIAction *action) {
                                                 change(value);
                                             }];
        action.state = [value isEqual:selected] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    return [UIMenu menuWithChildren:actions];
}
- (void)showActionChoices:(UIButton *)sender {
    [self.view endEditing:YES];
    NSRuleActionController *picker = [NSRuleActionController controllerWithTitle:@"Direction" message:nil];
    picker.selectedRule = self.ruleAction;
    NSArray *values = NSDirectionRuleValues();
    __weak typeof(self) weakSelf = self;
    for (NSUInteger index = 0; index < values.count; index++) {
        NSString *value = values[index];
        [picker addActionWithTitle:NSDirectionRuleTitle(value)
                              rule:value
                           handler:^{
                               weakSelf.ruleAction = value;
                               [weakSelf.tableView reloadData];
                           }];
    }
    [picker addActionWithTitle:@"Cancel" rule:nil handler:nil];
    picker.modalPresentationStyle = UIModalPresentationPopover;
    picker.preferredContentSize = CGSizeMake(360, 360);
    picker.popoverPresentationController.sourceView = sender;
    picker.popoverPresentationController.sourceRect = sender.bounds;
    picker.popoverPresentationController.permittedArrowDirections =
        UIPopoverArrowDirectionUp | UIPopoverArrowDirectionDown;
    picker.popoverPresentationController.delegate = picker;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)addAppIdentity {
    if (!self.viewIfLoaded.window || self.isBeingDismissed || self.navigationController.isBeingDismissed) {
        return;
    }
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Add app by identity"
                                            message:@"Enter the exact iOS app identity. A shortened name "
                                                    @"will appear in the selection."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Exact iOS identity";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.keyboardType = UIKeyboardTypeASCIICapable;
    }];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert
        addAction:[UIAlertAction
                      actionWithTitle:@"Add"
                                style:UIAlertActionStyleDefault
                              handler:^(UIAlertAction *action) {
                                  NSString *identity = [weakAlert.textFields.firstObject.text
                                      stringByTrimmingCharactersInSet:NSCharacterSet
                                                                          .whitespaceAndNewlineCharacterSet];
                                  if (!identity.length || identity.length > NSMaximumIdentityLength) {
                                      dispatch_async(dispatch_get_main_queue(), ^{
                                          [weakSelf showMessage:@"Enter a nonempty app identity of no more "
                                                                @"than 1024 characters."];
                                      });
                                      return;
                                  }
                                  NSGlobalRuleEditor *owner = weakSelf;
                                  if (!owner) {
                                      return;
                                  }
                                  [owner.selectedIdentities addObject:identity];
                                  NSMutableSet<NSString *> *available =
                                      [NSMutableSet setWithArray:owner.identities ?: @[]];
                                  [available addObject:identity];
                                  owner.identities = available.allObjects;
                                  [owner appSelectionChanged];
                              }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)requestAppIdentityFromButton:(NSGlobalRuleAppButton *)button {
    if (!button || button != self.appButton) {
        return;
    }
    if (button.isMenuActive) {
        button.enterIdentityAfterDismissal = YES;
    } else {
        [self addAppIdentity];
    }
}
- (void)toggleAppIdentity:(NSString *)identity fromButton:(NSGlobalRuleAppButton *)button {
    if (!button || button != self.appButton) {
        return;
    }
    if (!identity) {
        [self.selectedIdentities removeAllObjects];
    } else if ([self.selectedIdentities containsObject:identity]) {
        [self.selectedIdentities removeObject:identity];
    } else {
        [self.selectedIdentities addObject:identity];
    }
    [self appSelectionChanged];
}
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (!NSIsAppSelectionAction(action)) {
        return [super canPerformAction:action withSender:sender];
    }
    NSGlobalRuleAppButton *button = self.appButton;
    if ([sender isKindOfClass:UICommand.class]) {
        return NSAppCommandPayload(sender, action, button) != nil;
    }
    // UIKit can ask about the selector before supplying the command.
    return button != nil;
}
- (void)validateCommand:(UICommand *)command {
    SEL action = command.action;
    if (!NSIsAppSelectionAction(action)) {
        [super validateCommand:command];
        return;
    }
    NSDictionary<NSString *, NSString *> *payload = NSAppCommandPayload(command, action, self.appButton);
    if (payload) {
        command.state = NSAppCommandState(self.selectedIdentities, payload[NSAppCommandIdentityKey]);
    }
}
- (void)ns_toggleAppCommand:(UICommand *)command {
    NSGlobalRuleAppButton *button = self.appButton;
    NSDictionary<NSString *, NSString *> *payload = NSAppCommandPayload(command, _cmd, button);
    if (payload) {
        [self toggleAppIdentity:payload[NSAppCommandIdentityKey] fromButton:button];
    }
}
- (void)ns_selectAllAppsCommand:(UICommand *)command {
    NSGlobalRuleAppButton *button = self.appButton;
    if (NSAppCommandPayload(command, _cmd, button)) {
        [self toggleAppIdentity:nil fromButton:button];
    }
}
- (UIMenu *)appMenuForButton:(NSGlobalRuleAppButton *)button {
    NSMutableSet<NSString *> *available = [NSMutableSet setWithArray:self.identities ?: @[]];
    [available unionSet:self.selectedIdentities];
    button.menuIdentities = available;
    NSMutableArray<UICommand *> *apps = [NSMutableArray new];
    UIMenuElementAttributes selectionAttributes = 0;
    if (@available(iOS 16.0, *)) {
        selectionAttributes = UIMenuElementAttributesKeepsMenuPresented;
    }
    UICommand *all = [UICommand commandWithTitle:@"All apps"
                                           image:nil
                                          action:@selector(ns_selectAllAppsCommand:)
                                    propertyList:@{NSAppCommandOwnerKey : button.commandOwnerToken}];
    all.attributes = selectionAttributes;
    all.state = NSAppCommandState(self.selectedIdentities, nil);
    [apps addObject:all];
    for (NSString *identity in NSSortedAppIdentities(button.menuIdentities)) {
        UICommand *option = [UICommand commandWithTitle:NSIdentityDisplayName(identity)
                                                  image:nil
                                                 action:@selector(ns_toggleAppCommand:)
                                           propertyList:@{
                                               NSAppCommandOwnerKey : button.commandOwnerToken,
                                               NSAppCommandIdentityKey : identity,
                                           }];
        option.attributes = selectionAttributes;
        option.state = NSAppCommandState(self.selectedIdentities, identity);
        [apps addObject:option];
    }
    __weak typeof(self) weakSelf = self;
    __weak NSGlobalRuleAppButton *weakButton = button;
    UIAction *manual = [UIAction actionWithTitle:@"Add app by identity..."
                                           image:[UIImage systemImageNamed:@"plus"]
                                      identifier:@"netshield.custom-rule.apps.manual"
                                         handler:^(UIAction *action) {
                                             [weakSelf requestAppIdentityFromButton:weakButton];
                                         }];
    UIMenu *choices = [UIMenu menuWithTitle:@""
                                      image:nil
                                 identifier:@"netshield.custom-rule.apps.choices"
                                    options:UIMenuOptionsDisplayInline
                                   children:apps];
    return [UIMenu menuWithTitle:@""
                           image:nil
                      identifier:@"netshield.custom-rule.apps.root"
                         options:0
                        children:@[ choices, manual ]];
}
- (void)updateClosedAppButton:(NSGlobalRuleAppButton *)button resizeRow:(BOOL)resizeRow {
    button.menu = [self appMenuForButton:button];
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    for (NSString *identity in NSSortedAppIdentities(self.selectedIdentities)) {
        [names addObject:NSIdentityDisplayName(identity)];
    }
    NSString *label = names.count ? [names componentsJoinedByString:@", "] : @"All apps";
    UIButtonConfiguration *configuration = button.configuration;
    configuration.title = label;
    configuration.subtitle =
        names.count > 1 ? [NSString stringWithFormat:@"%lu apps selected", (unsigned long)names.count] : nil;
    button.configuration = configuration;
    button.accessibilityLabel = @"Apps";
    button.accessibilityValue = label;
    button.accessibilityHint = @"Select one or more apps";
    if (resizeRow) {
        [self.tableView performBatchUpdates:nil completion:nil];
    }
}
- (void)appSelectionChanged {
    NSGlobalRuleAppButton *button = self.appButton;
    if (!button) {
        return;
    }
    if (!button.isMenuActive) {
        [self updateClosedAppButton:button resizeRow:YES];
        return;
    }
    // Keep the menu's anchor and row membership stable until dismissal completes.
    button.refreshAfterDismissal = YES;
    if (@available(iOS 16.0, *)) {
        [UIMenuSystem.contextSystem setNeedsRevalidate];
    }
}
- (void)appMenuWillDisplay:(NSGlobalRuleAppButton *)button {
    if (button == self.appButton) {
        button.menuActive = YES;
    }
}
- (void)appMenuDidClose:(NSGlobalRuleAppButton *)button {
    if (button != self.appButton || !button.isMenuActive) {
        return;
    }
    button.menuActive = NO;
    if (button.refreshAfterDismissal) {
        button.refreshAfterDismissal = NO;
        [self updateClosedAppButton:button resizeRow:YES];
    }
    if (button.enterIdentityAfterDismissal) {
        button.enterIdentityAfterDismissal = NO;
        [self addAppIdentity];
    }
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                   reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIView *control;
    if (path.section == NSGlobalEditorHosts || (path.section == NSGlobalEditorPorts && path.row == 1)) {
        control = path.section == NSGlobalEditorHosts ? self.hostsField : self.portsField;
    } else {
        NSGlobalRuleAppButton *appButton = path.section == NSGlobalEditorApps
                                               ? [NSGlobalRuleAppButton buttonWithType:UIButtonTypeSystem]
                                               : nil;
        UIButton *button = appButton ?: [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *configuration = [UIButtonConfiguration grayButtonConfiguration];
        configuration.baseForegroundColor = UIColor.labelColor;
        configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(12, 14, 12, 14);
        configuration.image = [UIImage systemImageNamed:@"chevron.up.chevron.down"];
        configuration.preferredSymbolConfigurationForImage =
            [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
        configuration.imagePlacement = NSDirectionalRectEdgeTrailing;
        configuration.imagePadding = 12;
        configuration.titleAlignment = UIButtonConfigurationTitleAlignmentLeading;
        configuration.titleLineBreakMode = NSLineBreakByWordWrapping;
        configuration.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
            NSMutableDictionary *result = [attributes mutableCopy];
            result[NSFontAttributeName] = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
            return result;
        };
        button.configuration = configuration;
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
        button.titleLabel.adjustsFontForContentSizeCategory = YES;
        button.showsMenuAsPrimaryAction = YES;
        __weak typeof(self) weakSelf = self;
        NSString *title;
        if (appButton) {
            appButton.commandOwnerToken = NSUUID.UUID.UUIDString;
            self.appButton = appButton;
            appButton.editor = self;
            [self updateClosedAppButton:appButton resizeRow:NO];
        } else {
            if (path.section == NSGlobalEditorPorts) {
                title = self.localPort ? @"Local port" : @"Remote port";
                button.menu = [self menuForValues:@[ @"remote", @"local" ]
                                           titles:@[ @"Remote", @"Local" ]
                                         selected:self.localPort ? @"local" : @"remote"
                                           change:^(NSString *value) {
                                               weakSelf.localPort = [value isEqual:@"local"];
                                               [weakSelf.tableView reloadData];
                                           }];
            } else if (path.section == NSGlobalEditorProtocol) {
                title = [self.protocol isEqual:@"any"] ? @"UDP & TCP" : self.protocol.uppercaseString;
                button.menu = [self menuForValues:@[ @"any", @"udp", @"tcp" ]
                                           titles:@[ @"UDP & TCP", @"UDP", @"TCP" ]
                                         selected:self.protocol
                                           change:^(NSString *value) {
                                               weakSelf.protocol = value;
                                               [weakSelf.tableView reloadData];
                                           }];
            } else {
                title = NSDirectionRuleTitle(self.ruleAction);
                button.showsMenuAsPrimaryAction = NO;
                [button addTarget:self
                              action:@selector(showActionChoices:)
                    forControlEvents:UIControlEventTouchUpInside];
                configuration.baseForegroundColor = NSRuleColor(self.ruleAction);
            }
            configuration.title = title;
            button.configuration = configuration;
            button.accessibilityLabel = [self tableView:tableView titleForHeaderInSection:path.section];
            button.accessibilityValue = title;
            button.accessibilityHint = @"Opens a selection menu";
        }
        control = button;
    }
    control.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:control];
    UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [control.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [control.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [control.topAnchor constraintEqualToAnchor:margins.topAnchor],
        [control.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
        [control.heightAnchor constraintGreaterThanOrEqualToConstant:44]
    ]];
    return cell;
}
@end
