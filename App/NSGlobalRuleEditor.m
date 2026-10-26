#import "NSGlobalRuleEditor.h"
#import "../Shared/NSGlobalRule.h"
#import "../Shared/NSIdentityDisplay.h"

@interface NSGlobalRuleEditor ()
@property(nonatomic, strong) UITextField *appField;
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
    self.appField = [self fieldWithPlaceholder:@"All apps" label:@"App identity; blank means all apps"];
    self.hostsField = [self fieldWithPlaceholder:@"All domains and IPs" label:@"Domains or IP ranges"];
    self.portsField = [self fieldWithPlaceholder:@"All ports" label:@"Port numbers"];
    self.protocol = @"any";
    self.ruleAction = self.originalAction ?: @"block";
    NSArray<NSString *> *parts = NSCustomGlobalRuleComponents(self.originalKey);
    NSString *hosts = @"", *ports = @"";
    if (parts) {
        self.appField.text = parts[0];
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
    NSString *identity = [self.appField.text stringByTrimmingCharactersInSet:whitespace] ?: @"";
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
    NSString *key = NSCustomGlobalRuleKey(identity, hosts, ports, self.protocol);
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
    return section == 0 || section == 2 ? 2 : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[ @"App", @"Domains / IP ranges", @"Port", @"Protocol", @"Action" ][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @[
        @"Choose an observed app or enter its exact iOS identity. Leave blank for all apps.",
        @"Separate entries with commas, e.g. example.com, 192.168.1.10-192.168.1.20. Blank means all destinations. Bare and www domains are separate.",
        @"Choose remote or local, then enter port numbers separated by commas. Blank means all ports.",
        @"TCP or UDP applies only when iOS reports that protocol. UDP & TCP also covers browser flows whose protocol is unavailable.",
        @"Every selected condition must match. This rule is saved in Global Rules and overrides app rules and the iOS system traffic allowance. If global rules overlap, blocking takes priority."
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
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                   reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIView *control;
    if (path.section == 1 || (path.section == 0 && path.row == 1) || (path.section == 2 && path.row == 1)) {
        control = path.section == 0 ? self.appField : path.section == 1 ? self.hostsField : self.portsField;
    } else {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
        button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        button.titleLabel.adjustsFontForContentSizeCategory = YES;
        button.titleLabel.numberOfLines = 0;
        button.showsMenuAsPrimaryAction = YES;
        __weak typeof(self) weakSelf = self;
        NSString *title;
        if (path.section == 0) {
            title = @"Choose an app";
            NSMutableArray *values = [NSMutableArray arrayWithObject:@""];
            NSMutableArray *titles = [NSMutableArray arrayWithObject:@"All apps"];
            for (NSString *identity in self.identities) {
                [values addObject:identity];
                [titles addObject:[NSString stringWithFormat:@"%@ (%@)", NSIdentityDisplayName(identity),
                                                             identity]];
            }
            button.menu = [self menuForValues:values
                                       titles:titles
                                     selected:self.appField.text ?: @""
                                       change:^(NSString *value) {
                                           weakSelf.appField.text = value;
                                           [weakSelf.tableView reloadData];
                                       }];
        } else if (path.section == 2) {
            title = self.localPort ? @"Local port" : @"Remote port";
            button.menu = [self menuForValues:@[ @"remote", @"local" ]
                                       titles:@[ @"Remote", @"Local" ]
                                     selected:self.localPort ? @"local" : @"remote"
                                       change:^(NSString *value) {
                                           weakSelf.localPort = [value isEqual:@"local"];
                                           [weakSelf.tableView reloadData];
                                       }];
        } else if (path.section == 3) {
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
        [button setTitle:[title stringByAppendingString:@"  ▾"] forState:UIControlStateNormal];
        button.accessibilityHint = @"Opens a selection menu";
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
        [control.heightAnchor constraintGreaterThanOrEqualToConstant:36]
    ]];
    return cell;
}
@end
