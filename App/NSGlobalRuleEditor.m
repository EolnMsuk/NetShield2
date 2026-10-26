#import "NSGlobalRuleEditor.h"
#import "../Shared/NSGlobalRule.h"
#import "../Shared/NSIdentityDisplay.h"

typedef NS_ENUM(NSInteger, NSGlobalEditorSection) {
    NSGlobalEditorAction,
    NSGlobalEditorApps,
    NSGlobalEditorHosts,
    NSGlobalEditorPorts,
    NSGlobalEditorProtocol,
};

@interface NSGlobalRuleEditor ()
@property(nonatomic, strong) NSMutableSet<NSString *> *selectedIdentities;
@property(nonatomic, weak) UIButton *appButton;
@property(nonatomic, strong) UITextField *hostsField;
@property(nonatomic, strong) UITextField *portsField;
@property(nonatomic) BOOL localPort;
@property(nonatomic, copy) NSString *protocol;
@property(nonatomic, copy) NSString *ruleAction;
@end

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
    self.title = self.originalKey ? @"Edit Global Rule" : @"Add a Global Rule";
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
    NSArray *parts = NSCustomGlobalRuleComponents(self.originalKey);
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
    self.localPort = ports.length && [NSGlobalRuleMembers(ports).firstObject hasPrefix:@"localPort:"];
}
- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)showMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Unable to save rule"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
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
    NSString *key = NSCustomGlobalRuleKey(self.selectedIdentities.allObjects, hosts, ports, self.protocol);
    if (!NSValidGlobalRuleKey(key)) {
        [self showMessage:@"The app identity is too long or this rule contains too many entries."];
        return;
    }
    NSError *error = nil;
    if (!self.saveRule || !self.saveRule(key, self.ruleAction, &error)) {
        [self showMessage:error.localizedDescription ?: @"The rule could not be saved. Please try again."];
        return;
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 5;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == NSGlobalEditorPorts ? 2 : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[ @"Action", @"App", @"Domains / IP ranges", @"Port", @"Protocol" ][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @[
        @"Every selected condition must match. Saved in Global Rules, overriding app rules and the iOS system traffic allowance. If global rules overlap, blocking takes priority.",
        @"Select one or more apps. Tap a checked app to remove it, or choose All apps to clear the selection.",
        @"Separate entries with commas, e.g. example.com, 192.168.1.10-192.168.1.20. Blank means all destinations. Bare and www domains are separate.",
        @"Choose remote or local, then enter port numbers separated by commas. Blank means all ports.",
        @"TCP or UDP applies only when iOS reports that protocol. UDP & TCP also covers browser flows whose protocol is unavailable."
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
- (void)addAppIdentity {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Add app by identity"
                                            message:@"Enter the exact iOS app identity. Its shortened name "
                                                    @"will appear in the selection."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Exact iOS identity";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.keyboardType = UIKeyboardTypeASCIICapable;
    }];
    __weak typeof(self) weakSelf = self;
    [alert
        addAction:[UIAlertAction
                      actionWithTitle:@"Add"
                                style:UIAlertActionStyleDefault
                              handler:^(UIAlertAction *action) {
                                  NSString *identity = [alert.textFields.firstObject.text
                                      stringByTrimmingCharactersInSet:NSCharacterSet
                                                                          .whitespaceAndNewlineCharacterSet];
                                  if (!identity.length || identity.length > NSMaximumIdentityLength) {
                                      dispatch_async(dispatch_get_main_queue(), ^{
                                          [weakSelf showMessage:@"Enter a nonempty app identity of no more "
                                                                @"than 1024 characters."];
                                      });
                                      return;
                                  }
                                  [weakSelf.selectedIdentities addObject:identity];
                                  NSMutableSet *available =
                                      [NSMutableSet setWithArray:weakSelf.identities ?: @[]];
                                  [available addObject:identity];
                                  weakSelf.identities = available.allObjects;
                                  [weakSelf appSelectionChanged];
                              }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)appSelectionChanged {
    [self updateAppButton];
    [self.tableView performBatchUpdates:nil completion:nil];
}
- (void)updateAppButton {
    UIButton *button = self.appButton;
    if (!button) {
        return;
    }
    NSMutableSet *available = [NSMutableSet setWithArray:self.identities ?: @[]];
    [available unionSet:self.selectedIdentities];
    NSArray *identities = [available.allObjects
        sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
            NSComparisonResult order =
                [NSIdentityDisplayName(left) localizedCaseInsensitiveCompare:NSIdentityDisplayName(right)];
            return order == NSOrderedSame ? [left compare:right] : order;
        }];
    NSMutableArray *names = [NSMutableArray new];
    NSMutableArray *apps = [NSMutableArray new];
    __weak typeof(self) weakSelf = self;
    UIAction *all = [UIAction actionWithTitle:@"All apps"
                                        image:nil
                                   identifier:nil
                                      handler:^(UIAction *action) {
                                          [weakSelf.selectedIdentities removeAllObjects];
                                          [weakSelf appSelectionChanged];
                                      }];
    all.state = self.selectedIdentities.count ? UIMenuElementStateOff : UIMenuElementStateOn;
    if (@available(iOS 16.0, *)) {
        all.attributes = UIMenuElementAttributesKeepsMenuPresented;
    }
    [apps addObject:all];
    for (NSString *identity in identities) {
        NSString *name = NSIdentityDisplayName(identity);
        BOOL selected = [self.selectedIdentities containsObject:identity];
        if (selected) {
            [names addObject:name];
        }
        UIAction *option = [UIAction actionWithTitle:name
                                               image:nil
                                          identifier:nil
                                             handler:^(UIAction *action) {
                                                 if ([weakSelf.selectedIdentities containsObject:identity]) {
                                                     [weakSelf.selectedIdentities removeObject:identity];
                                                 } else {
                                                     [weakSelf.selectedIdentities addObject:identity];
                                                 }
                                                 [weakSelf appSelectionChanged];
                                             }];
        option.state = selected ? UIMenuElementStateOn : UIMenuElementStateOff;
        if (@available(iOS 16.0, *)) {
            option.attributes = UIMenuElementAttributesKeepsMenuPresented;
        }
        [apps addObject:option];
    }
    UIAction *manual = [UIAction actionWithTitle:@"Add app by identity..."
                                           image:[UIImage systemImageNamed:@"plus"]
                                      identifier:nil
                                         handler:^(UIAction *action) {
                                             [weakSelf addAppIdentity];
                                         }];
    UIMenu *choices = [UIMenu menuWithTitle:@""
                                      image:nil
                                 identifier:nil
                                    options:UIMenuOptionsDisplayInline
                                   children:apps];
    button.menu = [UIMenu menuWithChildren:@[ choices, manual ]];
    NSString *label = names.count ? [names componentsJoinedByString:@", "] : @"All apps";
    UIButtonConfiguration *configuration = button.configuration;
    configuration.title = label;
    configuration.subtitle =
        names.count > 1 ? [NSString stringWithFormat:@"%lu apps selected", (unsigned long)names.count] : nil;
    button.configuration = configuration;
    button.accessibilityLabel = @"Apps";
    button.accessibilityValue = label;
    button.accessibilityHint = @"Select one or more apps";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                   reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIView *control;
    if (path.section == NSGlobalEditorHosts || (path.section == NSGlobalEditorPorts && path.row == 1)) {
        control = path.section == NSGlobalEditorHosts ? self.hostsField : self.portsField;
    } else {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
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
        if (path.section == NSGlobalEditorApps) {
            self.appButton = button;
            [self updateAppButton];
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
                NSArray *values = @[ @"allow", @"block-inbound", @"block-outbound", @"block" ];
                NSArray *titles = @[ @"Allow", @"Block Incoming", @"Block Outgoing", @"Block In & Out" ];
                title = titles[[values indexOfObject:self.ruleAction]];
                button.menu = [self menuForValues:values
                                           titles:titles
                                         selected:self.ruleAction
                                           change:^(NSString *value) {
                                               weakSelf.ruleAction = value;
                                               [weakSelf.tableView reloadData];
                                           }];
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
