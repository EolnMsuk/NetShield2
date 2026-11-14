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

static NSArray *NSProtocolValues(void) {
    return @[ @"any", @"tcp", @"udp", @"tcp+udp", @"other", @"other+tcp", @"other+udp", @"other+tcp+udp" ];
}
static NSArray *NSProtocolTitles(void) {
    return @[
        @"Any protocol", @"TCP", @"UDP", @"TCP & UDP", @"Other", @"TCP & Other", @"UDP & Other",
        @"TCP, UDP & Other"
    ];
}

@class NSGlobalRuleAppButton;

@interface NSGlobalRuleEditor ()
@property(nonatomic, strong) NSMutableSet<NSString *> *selectedIdentities;
@property(nonatomic, weak) NSGlobalRuleAppButton *appButton;
@property(nonatomic, strong) UITextField *hostsField;
@property(nonatomic, strong) UITextField *portsField;
@property(nonatomic, strong) UITextField *localPortsField;
@property(nonatomic, copy) NSString *protocol;
@property(nonatomic) BOOL resolveDomains;
@property(nonatomic, copy) NSString *ruleAction;
- (void)appMenuWillDisplay:(NSGlobalRuleAppButton *)button;
- (void)appMenuDidClose:(NSGlobalRuleAppButton *)button;
@end

@interface NSGlobalRuleAppButton : UIButton
@property(nonatomic, weak) NSGlobalRuleEditor *editor;
@property(nonatomic, getter=isMenuActive) BOOL menuActive;
@property(nonatomic) BOOL refreshAfterDismissal;
@property(nonatomic) BOOL enterIdentityAfterDismissal;
@property(nonatomic, copy) NSDictionary<UIActionIdentifier, NSString *> *identitiesByActionIdentifier;
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

static UIActionIdentifier const NSAllAppsActionIdentifier = @"netshield.custom-rule.apps.all";

static NSArray<NSString *> *NSSortedAppIdentities(NSSet<NSString *> *identities) {
    return [identities.allObjects
        sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
            return NSCompareIdentityDisplayNames(left, right);
        }];
}

static UIMenu *
NSAppMenuWithSelection(UIMenu *menu,
                       NSDictionary<UIActionIdentifier, NSString *> *identitiesByActionIdentifier,
                       NSSet<NSString *> *selectedIdentities) {
    NSArray<UIMenuElement *> *children = menu.children;
    NSMutableArray<UIMenuElement *> *updatedChildren = nil;
    for (NSUInteger index = 0; index < children.count; index++) {
        UIMenuElement *element = children[index];
        UIMenuElement *updatedElement = element;
        if ([element isKindOfClass:UIMenu.class]) {
            updatedElement =
                NSAppMenuWithSelection((UIMenu *)element, identitiesByActionIdentifier, selectedIdentities);
        } else if ([element isKindOfClass:UIAction.class]) {
            UIAction *action = (UIAction *)element;
            NSString *identity = identitiesByActionIdentifier[action.identifier];
            if (!identity && ![action.identifier isEqualToString:NSAllAppsActionIdentifier]) {
                continue;
            }
            BOOL selected =
                identity ? [selectedIdentities containsObject:identity] : selectedIdentities.count == 0;
            UIMenuElementState state = selected ? UIMenuElementStateOn : UIMenuElementStateOff;
            if (action.state != state) {
                UIAction *updatedAction = [action copy];
                updatedAction.state = state;
                updatedElement = updatedAction;
            }
        }
        if (updatedElement != element) {
            if (!updatedChildren) {
                updatedChildren = [children mutableCopy];
            }
            updatedChildren[index] = updatedElement;
        }
    }
    return updatedChildren ? [menu menuByReplacingChildren:updatedChildren] : menu;
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
    self.hostsField = [self fieldWithPlaceholder:@"All domains and IPs" label:@"Domains, IP ranges or CIDRs"];
    self.portsField = [self fieldWithPlaceholder:@"All remote ports" label:@"Remote ports or ranges"];
    self.localPortsField = [self fieldWithPlaceholder:@"All local ports" label:@"Local ports or ranges"];
    self.ruleAction = self.originalAction ?: @"allow";
    NSDictionary *condition = NSGlobalRuleCondition(self.originalKey ?: self.initialKey);
    self.resolveDomains = condition ? [condition[@"resolveDomains"] boolValue] : YES;
    [self.selectedIdentities addObjectsFromArray:condition[@"identities"] ?: @[]];
    self.hostsField.text = NSGlobalDestinationsText(condition[@"destinations"] ?: @[]);
    self.portsField.text = NSGlobalPortsText(condition[@"remotePorts"] ?: @[]);
    self.localPortsField.text = NSGlobalPortsText(condition[@"localPorts"] ?: @[]);
    self.protocol =
        [condition[@"protocols"] count] ? [condition[@"protocols"] componentsJoinedByString:@"+"] : @"any";
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
- (NSString *)conditionRuleKey {
    NSArray *hosts = NSGlobalParseDestinations(self.hostsField.text ?: @"");
    NSArray *remote = NSGlobalParsePorts(self.portsField.text ?: @"");
    NSArray *local = NSGlobalParsePorts(self.localPortsField.text ?: @"");
    if (!hosts) {
        [self showMessage:
                  @"Enter domains, IPv4/IPv6 addresses, ascending ranges or CIDRs separated by commas. Use & "
                  @"between a domain and an address to require both. Do not include URLs or empty entries."];
        return nil;
    }
    if (!remote || !local) {
        [self showMessage:@"Enter ports or ascending ranges from 1 to 65535, separated by commas (80, 443, "
                          @"8000-8080). Blank means any port in that field."];
        return nil;
    }
    NSArray *protocols =
        [self.protocol isEqual:@"any"] ? @[] : [self.protocol componentsSeparatedByString:@"+"];
    NSString *key =
        NSGlobalRuleKey(NSGlobalCondition(self.selectedIdentities.allObjects, hosts, remote, local, protocols,
                                          NSGlobalCoverage(self.ruleAction), self.resolveDomains));
    if (!key) {
        [self showMessage:
                  @"This rule exceeds the identity or predicate capacity. Reduce its entries and try again."];
    }
    return key;
}
- (void)save {
    [self.view endEditing:YES];
    NSString *key = [self conditionRuleKey];
    if (!key) {
        return;
    }
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
            NSMutableString *message = [(
                error.localizedDescription ?: @"The rule could not be saved. Please try again.") mutableCopy];
            NSDictionary *conflict = NSGlobalRuleCondition(error.userInfo[@"conflictingRule"]);
            if (conflict) {
                NSMutableArray *names = [NSMutableArray new];
                for (NSString *identity in conflict[@"identities"]) {
                    [names addObject:NSIdentityDisplayName(identity)];
                }
                NSString *context = [NSString
                    stringWithFormat:@"%@ / %@ / %@ / remote %@ / local %@",
                                     names.count ? [names componentsJoinedByString:@", "] : @"All apps",
                                     conflict[@"direction"],
                                     [conflict[@"destinations"] count]
                                         ? NSGlobalDestinationsText(conflict[@"destinations"])
                                         : @"All destinations",
                                     [conflict[@"remotePorts"] count]
                                         ? NSGlobalPortsText(conflict[@"remotePorts"])
                                         : @"Any",
                                     [conflict[@"localPorts"] count]
                                         ? NSGlobalPortsText(conflict[@"localPorts"])
                                         : @"Any"];
                if (context.length > 500) {
                    context = [[context substringToIndex:500] stringByAppendingString:@"…"];
                }
                [message appendFormat:@"\n\nExisting rule: %@", context];
            }
            [owner showMessage:message];
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
    return @[ @"Direction", @"App", @"Domains / IPs / CIDRs", @"Ports", @"Protocol" ][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == NSGlobalEditorHosts && !self.resolveDomains) {
        return @"Every endpoint condition must match. Commas separate alternatives; & requires both a domain "
               @"and an address. Domains require reported hostname metadata and do not use cached DNS "
               @"addresses.";
    }
    return @[
        @"Saved in Global Rules, overriding app rules and the iOS system allowance",
        @"Select one or more apps. Tap a checked app to remove it, or choose All apps to clear the selection.",
        @"Separate alternatives with commas, e.g. example.com, 192.0.2.0/24, 2001:db8::/32. Use example.com & 192.0.2.1 to require both endpoints. Blank means all destinations. Blocking may use cached DNS addresses when hostname metadata is unavailable.",
        @"Remote and local ports are independent conditions. Use numbers, ranges or lists (80, 443, 8000-8080). Blank means any port in that field.",
        @"Any protocol includes unavailable metadata. TCP & UDP covers only TCP and UDP. Other covers reported protocols outside those categories."
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
- (UIMenu *)appMenuForButton:(NSGlobalRuleAppButton *)button {
    NSMutableSet<NSString *> *available = [NSMutableSet setWithArray:self.identities ?: @[]];
    [available unionSet:self.selectedIdentities];
    NSMutableArray<UIAction *> *apps = [NSMutableArray new];
    NSMutableDictionary<UIActionIdentifier, NSString *> *identitiesByActionIdentifier =
        [NSMutableDictionary new];
    UIMenuElementAttributes selectionAttributes = 0;
    if (@available(iOS 16.0, *)) {
        selectionAttributes = UIMenuElementAttributesKeepsMenuPresented;
    }
    __weak typeof(self) weakSelf = self;
    __weak NSGlobalRuleAppButton *weakButton = button;
    UIAction *all = [UIAction actionWithTitle:@"All apps"
                                        image:nil
                                   identifier:NSAllAppsActionIdentifier
                                      handler:^(UIAction *action) {
                                          NSGlobalRuleEditor *owner = weakSelf;
                                          [owner toggleAppIdentity:nil fromButton:weakButton];
                                      }];
    all.attributes = selectionAttributes;
    [apps addObject:all];
    for (NSString *identity in NSSortedAppIdentities(available)) {
        UIActionIdentifier identifier =
            [@"netshield.custom-rule.apps.identity:" stringByAppendingString:identity];
        identitiesByActionIdentifier[identifier] = identity;
        UIAction *option = [UIAction actionWithTitle:NSIdentityDisplayName(identity)
                                               image:nil
                                          identifier:identifier
                                             handler:^(UIAction *action) {
                                                 NSGlobalRuleEditor *owner = weakSelf;
                                                 [owner toggleAppIdentity:identity fromButton:weakButton];
                                             }];
        option.attributes = selectionAttributes;
        [apps addObject:option];
    }
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
    UIMenu *menu = [UIMenu menuWithTitle:@""
                                   image:nil
                              identifier:@"netshield.custom-rule.apps.root"
                                 options:0
                                children:@[ choices, manual ]];
    button.identitiesByActionIdentifier = identitiesByActionIdentifier;
    return NSAppMenuWithSelection(menu, button.identitiesByActionIdentifier, self.selectedIdentities);
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
        NSSet<NSString *> *selection = [self.selectedIdentities copy];
        NSDictionary<UIActionIdentifier, NSString *> *identitiesByActionIdentifier =
            button.identitiesByActionIdentifier;
        [button.contextMenuInteraction updateVisibleMenuWithBlock:^UIMenu *(UIMenu *visibleMenu) {
            // Supply replacement children so UIKit redraws the changed checkmarks.
            return NSAppMenuWithSelection(visibleMenu, identitiesByActionIdentifier, selection);
        }];
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
    if (path.section == NSGlobalEditorHosts) {
        control = self.hostsField;
    } else if (path.section == NSGlobalEditorPorts) {
        UILabel *label = [UILabel new];
        label.text = path.row == 0 ? @"Remote ports" : @"Local ports";
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        label.adjustsFontForContentSizeCategory = YES;
        label.isAccessibilityElement = NO;
        UIStackView *stack = [[UIStackView alloc]
            initWithArrangedSubviews:@[ label, path.row == 0 ? self.portsField : self.localPortsField ]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 2;
        control = stack;
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
            self.appButton = appButton;
            appButton.editor = self;
            [self updateClosedAppButton:appButton resizeRow:NO];
        } else {
            if (path.section == NSGlobalEditorProtocol) {
                NSArray *values = NSProtocolValues(), *titles = NSProtocolTitles();
                NSUInteger index = [values indexOfObject:self.protocol];
                title = index == NSNotFound ? @"Any protocol" : titles[index];
                button.menu = [self menuForValues:values
                                           titles:titles
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
