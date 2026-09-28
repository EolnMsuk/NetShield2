#import "NSDashboard+Internal.h"

@implementation NSDashboard (Table)
- (id)rowKey:(NSIndexPath *)path {
    if (path.section == NSDashboardSectionRequests && [self.monitor[@"requests"] count]) {
        return self.monitor[@"requests"][path.row][@"token"];
    }
    if (path.section == NSDashboardSectionRules && self.identities.count) {
        return self.identities[path.row];
    }
    if (path.section == NSDashboardSectionActivity && [self.monitor[@"events"] count]) {
        NSArray *events = self.monitor[@"events"];
        return events[events.count - 1 - path.row];
    }
    return @(path.row);
}
- (id)heightKey:(NSIndexPath *)path {
    return @[
        @(path.section), [self rowKey:path], @(self.tableView.bounds.size.width),
        self.traitCollection.preferredContentSizeCategory
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
    NSArray *signature = @[
        self.policy.document ?: @{}, self.monitor[@"requests"] ?: @[], self.monitor[@"events"] ?: @[],
        self.monitor[@"policyError"] ?: @"", self.monitor[@"notificationDeliveryIssue"] ?: @"",
        @([self hasFreshMonitor]), @(self.loaded), @(self.busy), @(NEFilterManager.sharedManager.enabled),
        self.message ?: @"", self.notificationStatus ?: @"", self.policyReadError ?: @"",
        self.monitor[@"overflowCount"] ?: @0, self.monitor[@"evictedRequestCount"] ?: @0
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
        return 5;
    }
    if (section == NSDashboardSectionRequests) {
        return MAX((NSUInteger)1, [self.monitor[@"requests"] count]);
    }
    if (section == NSDashboardSectionRules) {
        return MAX((NSUInteger)1, self.identities.count);
    }
    if (section == NSDashboardSectionNotifications) {
        return 2;
    }
    if (section == NSDashboardSectionAdvanced) {
        return 3;
    }
    if (section == NSDashboardSectionSupport) {
        return 2;
    }
    return MAX((NSUInteger)1, MIN((NSUInteger)20, [self.monitor[@"events"] count]));
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[
        @"Firewall", @"Waiting for your decision", @"Notifications", @"Advanced Settings", @"Support",
        @"App rules", @"Recent activity"
    ][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == NSDashboardSectionFirewall) {
        return @"Your rules are kept when you turn the firewall off. Ask me prompts only for apps without a "
               @"saved rule.";
    }
    if (section == NSDashboardSectionRequests) {
        return [NSString
            stringWithFormat:
                @"Unanswered connections are blocked after 30 seconds. The latest %d expired requests stay "
                @"available. During this filter session: %@ connections rejected at queue capacity; %@ older "
                @"requests removed. Retry an app if its request is no longer listed.",
                NSMaximumRequestHistory, self.monitor[@"overflowCount"] ?: @0,
                self.monitor[@"evictedRequestCount"] ?: @0];
    }
    if (section == NSDashboardSectionRules) {
        return @"Tap an app identity to change its rule. Changes affect new connections; close and reopen "
               @"the app to end existing connections.";
    }
    if (section == NSDashboardSectionNotifications) {
        return @"Do Not Disturb silences banners unless you allow NetShield2 in Settings > Focus > Do Not "
               @"Disturb > Apps.";
    }
    if (section == NSDashboardSectionActivity) {
        return @"Latest 20 of up to 300 recorded events. Data totals arrive when a connection closes; "
               @"permission decisions show no data totals.";
    }
    if (section == NSDashboardSectionSupport) {
        return @"Developed by EolnMsuk.";
    }
    return @"NetShield2 2.0.2 / iOS 15-18 rootless. Filters connections provided by iOS; system-exempt "
           @"traffic is not guaranteed covered.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cached = nil;
    if (path.section == NSDashboardSectionFirewall) {
        if (path.row == 1) {
            cached = self.firewallCell;
        } else if (path.row == 2) {
            cached = self.appleCell;
        }
    }
    if (cached) {
        UISwitch *toggle = (UISwitch *)cached.accessoryView;
        BOOL on = path.row == 1 ? self.loaded && NEFilterManager.sharedManager.enabled
                                : [self.policy.document[@"allowAppleSystemProcesses"] boolValue];
        BOOL enabled = (path.row == 1 ? self.loaded : self.policy != nil) && !self.busy;
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
    if (path.section == NSDashboardSectionFirewall && path.row == 1) {
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
    } else if (path.section == NSDashboardSectionFirewall && path.row == 0) {
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
            detail = @"Your rules are being applied to new connections.";
        }
        if ([self.monitor[@"policyError"] length]) {
            detail = self.monitor[@"policyError"];
        }
        if (self.policyReadError.length) {
            detail = self.policyReadError;
        }
        cell.detailTextLabel.text =
            [self.message length] ? [NSString stringWithFormat:@"%@\n%@", detail, self.message] : detail;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == NSDashboardSectionFirewall && path.row == 2) {
        cell.textLabel.text = @"Allow all iOS system processes";
        cell.detailTextLabel.text = @"Allow identities starting with com.apple., .com.apple. or "
                                    @"Apple.com.apple. Saved rules are ignored until this is off.";
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
    } else if (path.section == NSDashboardSectionFirewall) {
        cell.textLabel.text = path.row == 4 ? @"Default Rule" : @"Unidentified";
        cell.detailTextLabel.text =
            self.policy ? [self ruleTitle:self.policy.document[path.row == 4 ? @"default" : @"unattributed"]]
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
            cell.textLabel.text = request[@"identity"];
            cell.detailTextLabel.text = [request[@"expired"] boolValue]
                                            ? @"Blocked while waiting. Tap to decide."
                                            : @"Tap to allow or keep blocking";
        }
    } else if (path.section == NSDashboardSectionRules) {
        if (!self.identities.count) {
            cell.textLabel.text = @"Apps appear here when they connect";
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else {
            NSString *identity = self.identities[path.row];
            cell.textLabel.text = identity;
            cell.detailTextLabel.text =
                [self.policy automaticallyAllowsIdentity:identity]
                    ? [NSString stringWithFormat:@"Allowed by iOS system processes setting. Saved rule: %@",
                                                 [self ruleTitle:self.policy.document[@"rules"][identity]]]
                    : [self ruleTitle:self.policy.document[@"rules"][identity]];
        }
    } else if (path.section == NSDashboardSectionNotifications) {
        cell.textLabel.text = path.row == 0 ? @"Notification settings" : @"Banners & Do Not Disturb";
        cell.detailTextLabel.text =
            path.row == 0 ? self.notificationStatus : @"How to answer while using another app";
        if (path.row == 0 && [self hasFreshMonitor] && [self.monitor[@"notificationDeliveryIssue"] length]) {
            cell.detailTextLabel.text = self.monitor[@"notificationDeliveryIssue"];
        }
    } else if (path.section == NSDashboardSectionActivity) {
        NSArray *events = self.monitor[@"events"];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (!events.count) {
            cell.textLabel.text = @"No activity yet";
        } else {
            NSDictionary *event = events[events.count - 1 - path.row];
            NSString *action = @{
                @"allow" : @"Allowed",
                @"block" : @"Blocked",
                @"permission-allow" : @"Allowed by rule",
                @"permission-block" : @"Blocked"
            }[event[@"action"]]
                                   ?: @"Connection";
            cell.textLabel.text = [NSString
                stringWithFormat:@"%@ / %@", action,
                                 [event[@"identity"] length] ? event[@"identity"] : @"Unidentified app"];
            NSString *time = [NSDateFormatter localizedStringFromDate:event[@"time"]
                                                            dateStyle:NSDateFormatterShortStyle
                                                            timeStyle:NSDateFormatterShortStyle];
            cell.detailTextLabel.text =
                [NSString stringWithFormat:@"%@ / %@\nReceived %@ B / Sent %@ B", time, event[@"direction"],
                                           event[@"bytesIn"], event[@"bytesOut"]];
        }
    } else if (path.section == NSDashboardSectionSupport) {
        cell.textLabel.text = path.row == 0 ? @"GitHub Link" : @"Support Developer";
        cell.detailTextLabel.text =
            path.row == 0 ? @"Source code, releases and issues" : @"Choose Venmo or Bitcoin";
        cell.textLabel.textColor = UIColor.systemBlueColor;
    } else {
        cell.textLabel.text =
            @[ @"Add a rule by app identity", @"Reset NetShield2...", @"Prepare for uninstall..." ][path.row];
        cell.detailTextLabel.text = @[
            @"For an exact identity supplied by iOS", @"Clear rules and history; leave the firewall off",
            @"Remove the system filter before deleting NetShield2"
        ][path.row];
        if (path.row > 0) {
            cell.textLabel.textColor = UIColor.systemRedColor;
        }
    }
    if (path.section == NSDashboardSectionFirewall && path.row == 1) {
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
    if (path.section == NSDashboardSectionFirewall && path.row == 4) {
        [self chooseActionForIdentity:nil defaultKey:@"default"];
    } else if (path.section == NSDashboardSectionRequests && [self.monitor[@"requests"] count]) {
        [self presentRequest:self.monitor[@"requests"][path.row]];
    } else if (path.section == NSDashboardSectionRules && self.identities.count) {
        [self chooseActionForIdentity:self.identities[path.row] defaultKey:nil];
    } else if (path.section == NSDashboardSectionNotifications) {
        if (path.row == 0) {
            [self requestNotifications];
        } else {
            [self showNotificationHelp];
        }
    } else if (path.section == NSDashboardSectionFirewall && path.row == 3) {
        [self chooseActionForIdentity:nil defaultKey:@"unattributed"];
    } else if (path.section == NSDashboardSectionSupport) {
        if (path.row == 0) {
            [self openSupportURL:[NSURL URLWithString:@"https://github.com/EolnMsuk/NetShield2/"]];
        } else {
            [self supportDeveloper];
        }
    } else if (path.section == NSDashboardSectionAdvanced) {
        if (path.row == 0) {
            [self addIdentity];
        } else {
            BOOL reset = path.row == 1;
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:reset ? @"Reset NetShield2?" : @"Prepare for uninstall?"
                                 message:
                                     reset ? @"Deletes app rules, pending requests and history. Restores "
                                             @"Default Rule to Ask me, allows unidentified connections and "
                                             @"leaves Firewall off. iOS notification settings are kept."
                                           : @"Removes NetShield2's system filter and stops filtering. After "
                                             @"this succeeds, uninstall NetShield2 in your package manager."
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:reset ? @"Reset" : @"Remove system filter"
                                                      style:UIAlertActionStyleDestructive
                                                    handler:^(UIAlertAction *action) {
                                                        if (reset) {
                                                            [self resetNetShield2];
                                                        } else {
                                                            [self changeConfiguration:NSConfigurationRemove];
                                                        }
                                                    }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }
}

@end
