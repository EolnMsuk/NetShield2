#import "NSDashboard+Internal.h"
#import "../Shared/NSActivity.h"

@implementation NSDashboard (Table)
- (BOOL)showsSystemRules {
    return self.policy && ![self.policy.document[@"allowAppleSystemProcesses"] boolValue];
}
- (NSArray<NSString *> *)identitiesForSection:(NSInteger)section {
    return section == NSDashboardSectionSystemRules ? self.systemIdentities : self.identities;
}
- (id)rowKey:(NSIndexPath *)path {
    if (path.section == NSDashboardSectionGlobalRules) {
        return self.globalRuleKeys[path.row];
    }
    if (path.section == NSDashboardSectionRequests && [self.monitor[@"requests"] count]) {
        return self.monitor[@"requests"][path.row][@"token"];
    }
    if ((path.section == NSDashboardSectionRules || path.section == NSDashboardSectionSystemRules) &&
        [self identitiesForSection:path.section].count) {
        return [self identitiesForSection:path.section][path.row];
    }
    if (path.section == NSDashboardSectionActivity && self.activityGroups.count) {
        return self.activityGroups[path.row][@"groupKey"];
    }
    return @(path.row);
}
- (id)heightKey:(NSIndexPath *)path {
    return @[
        @(path.section), [self rowKey:path],
        path.section == NSDashboardSectionActivity && self.activityGroups.count
            ? self.activityGroups[path.row]
            : @{},
        @(self.tableView.bounds.size.width), self.traitCollection.preferredContentSizeCategory
    ];
}
- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)path {
    NSNumber *height = self.rowHeights[[self heightKey:path]];
    return height ? height.doubleValue : 64;
}
- (void)tableView:(UITableView *)tableView
      willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)path {
    if (self.rowHeights.count > 5000) {
        [self.rowHeights removeAllObjects];
    }
    self.rowHeights[[self heightKey:path]] = @(cell.bounds.size.height);
}
- (void)refreshTableKeepingPosition {
    // Monitor refreshes must not interrupt the native swipe reveal animation.
    if (self.tableView.editing) {
        return;
    }
    NSArray *signature = @[
        self.policy.document ?: @{}, self.monitor[@"requests"] ?: @[], self.monitor[@"events"] ?: @[],
        self.monitor[@"policyError"] ?: @"", self.monitor[@"dnsIssue"] ?: @"",
        self.monitor[@"notificationDeliveryIssue"] ?: @"", @([self hasFreshMonitor]), @(self.loaded),
        @(self.busy), @(NEFilterManager.sharedManager.enabled),
        @(NEFilterManager.sharedManager.providerConfiguration.filterSockets), self.message ?: @"",
        self.notificationStatus ?: @"", self.policyReadError ?: @"", self.monitor[@"overflowCount"] ?: @0,
        self.monitor[@"evictedRequestCount"] ?: @0, self.identities ?: @[], self.systemIdentities ?: @[]
    ];
    if ([signature isEqual:self.displaySignature]) {
        return;
    }
    self.displaySignature = signature;
    __block CGPoint offset = self.tableView.contentOffset;
    BOOL atTop = offset.y <= -self.tableView.adjustedContentInset.top + 1;
    NSMutableArray *anchors = [NSMutableArray new];
    for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) {
        if ((NSUInteger)path.section < self.displayedRows.count &&
            (NSUInteger)path.row < [self.displayedRows[path.section] count]) {
            [anchors addObject:@[
                @(path.section), self.displayedRows[path.section][path.row],
                @([self.tableView rectForRowAtIndexPath:path].origin.y - offset.y)
            ]];
        }
    }
    self.activityGroups = NSGroupedActivity(self.monitor[@"events"] ?: @[]);
    NSMutableArray *rows = [NSMutableArray new];
    for (NSInteger section = 0; section < [self numberOfSectionsInTableView:self.tableView]; section++) {
        NSMutableArray *keys = [NSMutableArray new];
        for (NSInteger row = 0; row < [self tableView:self.tableView numberOfRowsInSection:section]; row++) {
            [keys addObject:[self rowKey:[NSIndexPath indexPathForRow:row inSection:section]]];
        }
        [rows addObject:keys];
    }
    self.displayedRows = rows;
    [UIView performWithoutAnimation:^{
        [self.tableView reloadData];
        [self.tableView layoutIfNeeded];
        if (!atTop) {
            for (NSArray *anchor in anchors) {
                NSInteger section = [anchor[0] integerValue];
                NSUInteger row = [rows[section] indexOfObject:anchor[1]];
                if (row == NSNotFound) {
                    continue;
                }
                offset.y = [self.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:row
                                                                                    inSection:section]]
                               .origin.y -
                           [anchor[2] doubleValue];
                break;
            }
        }
        CGFloat minimum = -self.tableView.adjustedContentInset.top;
        CGFloat maximum = MAX(minimum, self.tableView.contentSize.height - self.tableView.bounds.size.height +
                                           self.tableView.adjustedContentInset.bottom);
        [self.tableView
            setContentOffset:CGPointMake(offset.x, atTop ? minimum : MIN(maximum, MAX(minimum, offset.y)))
                    animated:NO];
    }];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return NSDashboardSectionCount;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == NSDashboardSectionFirewall) {
        return 6;
    }
    if (section == NSDashboardSectionRequests) {
        return MAX((NSUInteger)1, [self.monitor[@"requests"] count]);
    }
    if (section == NSDashboardSectionRules) {
        return MAX((NSUInteger)1, self.identities.count);
    }
    if (section == NSDashboardSectionSystemRules) {
        return [self showsSystemRules] ? MAX((NSUInteger)1, self.systemIdentities.count) : 0;
    }
    if (section == NSDashboardSectionNotifications) {
        return 2;
    }
    if (section == NSDashboardSectionAddGlobalRule) {
        return 1;
    }
    if (section == NSDashboardSectionGlobalRules) {
        return self.globalRuleKeys.count;
    }
    if (section == NSDashboardSectionAdvanced) {
        return 3;
    }
    if (section == NSDashboardSectionSupport) {
        return 3;
    }
    return MAX((NSUInteger)1, self.activityGroups.count);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == NSDashboardSectionSystemRules && ![self showsSystemRules]) {
        return nil;
    }
    return @[
        @"Firewall", @"Waiting for your decision", @"Notifications", @"Reset Settings", @"", @"Global Rules",
        @"", @"App Rules", @"System Rules", @"Recent activity"
    ][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == NSDashboardSectionSystemRules) {
        return [self showsSystemRules] ? @"Tap a system identity to change its rule." : nil;
    }
    if (section == NSDashboardSectionAddGlobalRule) {
        return @"Overrides app rules and the iOS system traffic allowance.";
    }
    if (section == NSDashboardSectionFirewall) {
        return @"Rules are saved when firewall is turned off.";
    }
    if (section == NSDashboardSectionRequests) {
        return [NSString stringWithFormat:@"During this filter session: %@ connections rejected at queue "
                                          @"capacity; %@ older requests removed. ",
                                          self.monitor[@"overflowCount"] ?: @0,
                                          self.monitor[@"evictedRequestCount"] ?: @0];
    }
    if (section == NSDashboardSectionRules) {
        return @"Tap an app identity to change its rule.";
    }
    if (section == NSDashboardSectionActivity) {
        return @"Up to 300 recorded events";
    }
    return nil;
}
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section != NSDashboardSectionSupport) {
        return nil;
    }
    UIView *header = [UIView new];
    header.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(20, 20, 8, 20);
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = UIColor.secondaryLabelColor;
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    label.text = [NSString stringWithFormat:@"NetShield2 v%@ by EolnMsuk (%@ %@)", version,
                                            UIDevice.currentDevice.systemVersion, @NS_JAILBREAK_TYPE];
    [header addSubview:label];
    UILayoutGuide *margins = header.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [label.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [label.topAnchor constraintEqualToAnchor:margins.topAnchor],
        [label.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor]
    ]];
    return header;
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (section == NSDashboardSectionGlobalRules) {
        return self.globalRuleKeys.count ? 16 : CGFLOAT_MIN;
    }
    return section == NSDashboardSectionSystemRules && ![self showsSystemRules]
               ? CGFLOAT_MIN
               : UITableViewAutomaticDimension;
}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    if (section == NSDashboardSectionGlobalRules && !self.globalRuleKeys.count) {
        return CGFLOAT_MIN;
    }
    // The links header already supplies the inter-section gap and keeps the
    // version label close to GitHub Link; don't stack an empty footer above it.
    if (section == NSDashboardSectionAdvanced) {
        return CGFLOAT_MIN;
    }
    return section == NSDashboardSectionSystemRules && ![self showsSystemRules]
               ? CGFLOAT_MIN
               : UITableViewAutomaticDimension;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cached = nil;
    if (path.section == NSDashboardSectionFirewall) {
        if (path.row == 0) {
            cached = self.firewallCell;
        } else if (path.row == 2) {
            cached = self.appleCell;
        }
    }
    if (cached) {
        UISwitch *toggle = (UISwitch *)cached.accessoryView;
        BOOL on = path.row == 0 ? self.loaded && NEFilterManager.sharedManager.enabled
                                : [self.policy.document[@"allowAppleSystemProcesses"] boolValue];
        BOOL enabled = (path.row == 0 ? self.loaded : self.policy != nil) && !self.busy;
        if (toggle.on != on) {
            [toggle setOn:on animated:NO];
        }
        if (toggle.enabled != enabled) {
            toggle.enabled = enabled;
        }
        return cached;
    }
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                   reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (path.section == NSDashboardSectionFirewall && path.row == 0) {
        cell.textLabel.text = @"Firewall";
        cell.detailTextLabel.text = @"Control internet access for your apps";
        cell.imageView.image = [UIImage systemImageNamed:@"shield.lefthalf.filled"];
        UISwitch *toggle = [UISwitch new];
        if (self.loaded && NEFilterManager.sharedManager.enabled) {
            [toggle setOn:YES animated:NO];
        }
        toggle.enabled = self.loaded && !self.busy;
        toggle.accessibilityLabel = @"Firewall";
        [toggle addTarget:self
                      action:@selector(firewallChanged:)
            forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == NSDashboardSectionFirewall && path.row == 3) {
        BOOL enabled = self.loaded && NEFilterManager.sharedManager.enabled;
        BOOL healthy =
            enabled && self.policy && [self hasFreshMonitor] && ![self.monitor[@"policyError"] length];
        if (self.busy) {
            cell.textLabel.text = @"Updating...";
        } else if (!self.loaded) {
            cell.textLabel.text = @"Unable to read firewall status";
        } else if (!enabled) {
            cell.textLabel.text = @"Off";
        } else {
            cell.textLabel.text = healthy ? @"Active" : @"Needs attention";
        }
        cell.textLabel.textColor = healthy ? UIColor.systemGreenColor : UIColor.labelColor;
        NSString *detail =
            @"The filter has not reported a healthy status. Turn Firewall off and on if this continues.";
        if (!enabled) {
            detail = @"Turn on Firewall to apply your rules.";
        } else if (healthy) {
            detail = NEFilterManager.sharedManager.providerConfiguration.filterSockets
                         ? @"Browser and socket filtering active."
                         : @"Browser filtering only. Enable Filter System Sockets below Firewall for "
                           @"other app connections.";
        }
        if (enabled && NEFilterManager.sharedManager.providerConfiguration.filterSockets !=
                           [self.policy.document[@"filterSockets"] boolValue]) {
            detail = [detail stringByAppendingString:
                                 @" Pending: toggle Firewall off and on to apply the saved socket setting."];
        }
        if ([self.monitor[@"policyError"] length]) {
            detail = self.monitor[@"policyError"];
        }
        if ([self.monitor[@"dnsIssue"] length]) {
            detail = [detail stringByAppendingFormat:@"\n%@", self.monitor[@"dnsIssue"]];
        }
        if (self.policyReadError.length) {
            detail = self.policyReadError;
        }
        cell.detailTextLabel.text =
            [self.message length] ? [NSString stringWithFormat:@"%@\n%@", detail, self.message] : detail;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == NSDashboardSectionFirewall && path.row == 2) {
        cell.textLabel.text = @"Allow all iOS system traffic";
        cell.detailTextLabel.text = @"Allow Apple identities unless a global rule matches";
        UISwitch *toggle = [UISwitch new];
        if ([self.policy.document[@"allowAppleSystemProcesses"] boolValue]) {
            [toggle setOn:YES animated:NO];
        }
        toggle.enabled = self.policy != nil && !self.busy;
        toggle.accessibilityLabel = cell.textLabel.text;
        [toggle addTarget:self
                      action:@selector(appleSystemProcessesChanged:)
            forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == NSDashboardSectionFirewall && path.row == 1) {
        cell.textLabel.text = @"Filter System Sockets";
        cell.detailTextLabel.text =
            @"Required to filter all app network. Only disable if an app crashes on launch";
        UISwitch *toggle = [UISwitch new];
        toggle.on = [self.policy.document[@"filterSockets"] boolValue];
        toggle.enabled = self.policy != nil && self.loaded && !self.busy;
        toggle.accessibilityLabel = cell.textLabel.text;
        [toggle addTarget:self
                      action:@selector(socketFilteringChanged:)
            forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == NSDashboardSectionFirewall) {
        cell.textLabel.text = path.row == 5 ? @"Default Rule" : @"Unidentified";
        cell.detailTextLabel.text =
            self.policy ? [self ruleTitle:self.policy.document[path.row == 5 ? @"default" : @"unattributed"]]
                        : @"Policy unavailable";
        if (!self.policy) {
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
    } else if (path.section == NSDashboardSectionRequests) {
        NSArray *requests = self.monitor[@"requests"];
        if (!requests.count) {
            cell.textLabel.text = @"No apps waiting";
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else {
            NSDictionary *request = requests[path.row];
            cell.textLabel.text = NSIdentityDisplayName(request[@"identity"]);
            cell.detailTextLabel.text = [request[@"expired"] boolValue]
                                            ? @"Blocked while waiting. Tap to decide."
                                            : @"Tap to allow or keep blocking";
            cell.detailTextLabel.text = [cell.detailTextLabel.text
                stringByAppendingFormat:@"\nFirst requested peer: %@",
                                        NSDestinationSummary(request[@"destination"])];
        }
    } else if (path.section == NSDashboardSectionAddGlobalRule) {
        cell.textLabel.text = @"Add a Custom Rule";
        cell.textLabel.textColor = UIColor.systemGreenColor;
        cell.detailTextLabel.text = @"Choose apps, destinations, ports and protocols";
    } else if (path.section == NSDashboardSectionGlobalRules) {
        NSString *key = self.globalRuleKeys[path.row];
        NSString *rule = self.policy.document[@"globalRules"][key];
        UIColor *color = NSRuleColor(rule);
        if (color) {
            cell.backgroundColor = [color colorWithAlphaComponent:0.14];
        }
        cell.textLabel.text = [self globalRuleTitle:key];
        cell.detailTextLabel.text = [self ruleTitle:rule];
    } else if (path.section == NSDashboardSectionRules || path.section == NSDashboardSectionSystemRules) {
        NSArray<NSString *> *identities = [self identitiesForSection:path.section];
        if (!identities.count) {
            cell.textLabel.text = path.section == NSDashboardSectionSystemRules
                                      ? @"System processes appear here when they connect"
                                      : @"Apps appear here when they connect";
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else {
            NSString *identity = identities[path.row];
            NSString *rule = self.policy.document[@"rules"][identity];
            UIColor *color = NSRuleColor(rule);
            if (color) {
                cell.backgroundColor = [color colorWithAlphaComponent:0.14];
            }
            cell.textLabel.text = NSIdentityDisplayName(identity);
            cell.detailTextLabel.text =
                [self.policy automaticallyAllowsIdentity:identity]
                    ? [NSString stringWithFormat:
                                    @"Allowed by iOS setting unless a global rule matches. Saved rule: %@",
                                    [self ruleTitle:self.policy.document[@"rules"][identity]]]
                    : [self ruleTitle:self.policy.document[@"rules"][identity]];
            NSDictionary *destination = self.policy.document[@"ruleDestinations"][identity];
            if (destination) {
                cell.detailTextLabel.text = [cell.detailTextLabel.text
                    stringByAppendingFormat:@"\nFirst requested peer: %@ (rule applies to the app)",
                                            NSDestinationSummary(destination)];
            }
        }
    } else if (path.section == NSDashboardSectionNotifications) {
        cell.textLabel.text = path.row == 0 ? @"Notification Settings" : @"Banners & Do Not Disturb";
        cell.detailTextLabel.text =
            path.row == 0 ? self.notificationStatus : @"How to answer while using another app";
        if (path.row == 0 && [self hasFreshMonitor] && [self.monitor[@"notificationDeliveryIssue"] length]) {
            cell.detailTextLabel.text = self.monitor[@"notificationDeliveryIssue"];
        }
    } else if (path.section == NSDashboardSectionActivity) {
        NSArray *events = self.activityGroups;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (!events.count) {
            cell.textLabel.text = @"No activity yet";
        } else {
            NSDictionary *event = events[path.row];
            BOOL allowed = [event[@"action"] isEqual:@"allow"];
            BOOL blocked = [event[@"action"] isEqual:@"block"];
            NSString *action = allowed ? @"Allowed" : blocked ? @"Blocked" : @"Connection";
            UIColor *color = allowed ? NSRuleColor(@"allow") : blocked ? NSRuleColor(@"block") : nil;
            if (color) {
                cell.backgroundColor = [color colorWithAlphaComponent:0.14];
            }
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text =
                [NSString stringWithFormat:@"%@ / %@", action, NSIdentityDisplayName(event[@"identity"])];
            NSString *time = [NSDateFormatter localizedStringFromDate:event[@"time"]
                                                            dateStyle:NSDateFormatterShortStyle
                                                            timeStyle:NSDateFormatterShortStyle];
            cell.detailTextLabel.text =
                [NSString stringWithFormat:@"%@ / %@\nConnections: %@\nReceived %.1f MB / Sent %.1f MB", time,
                                           event[@"direction"], event[@"connections"],
                                           [event[@"bytesIn"] unsignedLongLongValue] / 1000000.0,
                                           [event[@"bytesOut"] unsignedLongLongValue] / 1000000.0];
            cell.detailTextLabel.text = [cell.detailTextLabel.text
                stringByAppendingFormat:@"\n%@", NSDestinationSummary(event[@"destination"])];
        }
    } else if (path.section == NSDashboardSectionSupport) {
        cell.textLabel.text = @[ @"GitHub Link", @"Check for Update", @"Support the Developer" ][path.row];
        cell.detailTextLabel.text = @[
            @"Source code, releases and issues", @"Check GitHub for a newer version",
            @"Choose Venmo or Crypto"
        ][path.row];
        cell.textLabel.textColor = UIColor.systemBlueColor;
    } else {
        cell.textLabel.text =
            @[ @"Export Rules and Recent Activity", @"Reset Rules & History",
               @"Reset Settings & Filter" ][path.row];
        cell.detailTextLabel.text = @[
            @"Share rules and recent activity as a JSON file", @"Reset rules and history only",
            @"Removes all rules, permissions and filters."
        ][path.row];
        cell.textLabel.textColor = path.row == 0 ? UIColor.systemBlueColor : UIColor.systemRedColor;
    }
    if (path.section == NSDashboardSectionFirewall && path.row == 0) {
        self.firewallCell = cell;
    }
    if (path.section == NSDashboardSectionFirewall && path.row == 2) {
        self.appleCell = cell;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (self.busy) {
        return;
    }
    if (path.section == NSDashboardSectionFirewall && path.row == 5) {
        [self chooseActionForIdentity:nil defaultKey:@"default"];
    } else if (path.section == NSDashboardSectionRequests && [self.monitor[@"requests"] count]) {
        [self presentRequest:self.monitor[@"requests"][path.row]];
    } else if (path.section == NSDashboardSectionAddGlobalRule) {
        [self editGlobalRule:nil];
    } else if (path.section == NSDashboardSectionGlobalRules) {
        [self chooseGlobalRule:self.globalRuleKeys[path.row]];
    } else if ((path.section == NSDashboardSectionRules || path.section == NSDashboardSectionSystemRules) &&
               [self identitiesForSection:path.section].count) {
        [self chooseActionForIdentity:[self identitiesForSection:path.section][path.row] defaultKey:nil];
    } else if (path.section == NSDashboardSectionActivity && self.activityGroups.count) {
        NSDictionary *connection = self.activityGroups[path.row];
        [self chooseActionForIdentity:connection[@"identity"] defaultKey:nil connection:connection];
    } else if (path.section == NSDashboardSectionNotifications) {
        if (path.row == 0) {
            [self requestNotifications];
        } else {
            [self showNotificationHelp];
        }
    } else if (path.section == NSDashboardSectionFirewall && path.row == 4) {
        [self chooseActionForIdentity:nil defaultKey:@"unattributed"];
    } else if (path.section == NSDashboardSectionSupport) {
        if (path.row == 0) {
            [self openSupportURL:[NSURL URLWithString:@"https://github.com/EolnMsuk/NetShield2/"]];
        } else if (path.row == 1) {
            [self checkForUpdateManually:YES];
        } else if (path.row == 2) {
            [self supportDeveloper];
        }
    } else if (path.section == NSDashboardSectionAdvanced) {
        if (path.row == 0) {
            [self exportRulesAndRecentActivityFromRow:path];
        } else {
            BOOL reset = path.row == 1;
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:reset ? @"Reset Rules & History?" : @"Reset Settings & Filter?"
                                 message:reset ? @"Deletes app and global rules, pending requests and "
                                                 @"history only. "
                                                 @"Keeps your settings and restores the firewall's previous "
                                                 @"on/off state after stopping it to reset."
                                               : @"Removes all NetShield2 rules, permissions and history, "
                                                 @"restores default settings, and removes the system filter. "
                                                 @"iOS notification authorization "
                                                 @"must be managed in Settings."
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:reset ? @"Reset rules and history"
                                                                  : @"Reset Settings & Filter"
                                                      style:UIAlertActionStyleDestructive
                                                    handler:^(UIAlertAction *action) {
                                                        self.resetAllSettings = !reset;
                                                        [self resetNetShield2];
                                                    }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }
}

- (void)tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(NSIndexPath *)path {
    [self reloadMonitor];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)path {
    if (self.busy || !self.policy) {
        return nil;
    }
    BOOL global = path.section == NSDashboardSectionGlobalRules;
    BOOL app = path.section == NSDashboardSectionRules || path.section == NSDashboardSectionSystemRules;
    NSArray *keys = global ? self.globalRuleKeys : app ? [self identitiesForSection:path.section] : @[];
    NSUInteger index = path.row;
    if (index >= keys.count) {
        return nil;
    }
    NSString *key = keys[index];
    UIContextualAction *remove = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@"Remove"
                          handler:^(UIContextualAction *action, UIView *source, void (^completion)(BOOL)) {
                              BOOL saved = !global ? [self removeAppRuleForIdentity:key]
                                                   : [self updatePolicy:^BOOL(NSMutableDictionary *document,
                                                                              NSError **error) {
                                                         NSMutableDictionary *rules =
                                                             [document[@"globalRules"] mutableCopy];
                                                         [rules removeObjectForKey:key];
                                                         document[@"globalRules"] = rules;
                                                         return YES;
                                                     }];
                              completion(saved);
                              [tableView setEditing:NO animated:YES];
                              [self reloadMonitor];
                          }];
    remove.backgroundColor = UIColor.systemRedColor;
    UISwipeActionsConfiguration *configuration =
        [UISwipeActionsConfiguration configurationWithActions:@[ remove ]];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}
@end
