#import "NSDashboard+Internal.h"
#import "../Shared/NSActivity.h"

@implementation NSDashboard (Table)
- (id)rowKey:(NSIndexPath *)path {
    if (path.section == NSDashboardSectionGlobalRules && self.globalRuleKeys.count) {
        return self.globalRuleKeys[path.row];
    }
    if (path.section == NSDashboardSectionRequests && [self.monitor[@"requests"] count]) {
        return self.monitor[@"requests"][path.row][@"token"];
    }
    if (path.section == NSDashboardSectionRules && self.identities.count) {
        return self.identities[path.row];
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
    NSArray *signature = @[
        self.policy.document ?: @{}, self.monitor[@"requests"] ?: @[], self.monitor[@"events"] ?: @[],
        self.monitor[@"policyError"] ?: @"", self.monitor[@"notificationDeliveryIssue"] ?: @"",
        @([self hasFreshMonitor]), @(self.loaded), @(self.busy), @(NEFilterManager.sharedManager.enabled),
        @(NEFilterManager.sharedManager.providerConfiguration.filterSockets), self.message ?: @"",
        self.notificationStatus ?: @"", self.policyReadError ?: @"", self.monitor[@"overflowCount"] ?: @0,
        self.monitor[@"evictedRequestCount"] ?: @0
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
    if (section == NSDashboardSectionNotifications) {
        return 2;
    }
    if (section == NSDashboardSectionGlobalRules) {
        return MAX((NSUInteger)1, self.globalRuleKeys.count);
    }
    if (section == NSDashboardSectionAdvanced) {
        return 5;
    }
    if (section == NSDashboardSectionSupport) {
        return 2;
    }
    return MAX((NSUInteger)1, self.activityGroups.count);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[
        @"Firewall", @"Waiting for your decision", @"Notifications", @"Advanced Settings", @"Support",
        @"Global rules", @"App rules", @"Recent activity"
    ][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == NSDashboardSectionGlobalRules) {
        return @"Overrides app rules and the iOS system traffic allowance. Matching order: "
               @"exact IP, domain, then remote port. Tap to edit or remove. Changes apply "
               @"to new connections.";
    }
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
        return @"Up to 300 recorded events grouped by process, IP, direction and outcome, newest "
               @"first. "
               @"Counts and totals cover retained events. Data totals arrive when a connection closes; "
               @"permission decisions show no data totals. Tap a process to change its rule.";
    }
    if (section == NSDashboardSectionSupport) {
        return @"Developed by EolnMsuk.";
    }
    return @"NetShield2 2.2.2 / iOS 15-18 rootless. Filters connections provided by iOS; system-exempt "
           @"traffic is not guaranteed covered.";
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
            cell.textLabel.text = request[@"identity"];
            cell.detailTextLabel.text = [request[@"expired"] boolValue]
                                            ? @"Blocked while waiting. Tap to decide."
                                            : @"Tap to allow or keep blocking";
            cell.detailTextLabel.text = [cell.detailTextLabel.text
                stringByAppendingFormat:@"\nFirst requested peer: %@",
                                        NSDestinationSummary(request[@"destination"])];
        }
    } else if (path.section == NSDashboardSectionGlobalRules) {
        if (!self.globalRuleKeys.count) {
            cell.textLabel.text = @"No global rules";
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else {
            NSString *key = self.globalRuleKeys[path.row];
            NSString *rule = self.policy.document[@"globalRules"][key];
            UIColor *color = [rule isEqual:@"allow"] ? UIColor.systemGreenColor
                             : [rule isEqual:@"block"] || [rule isEqual:@"block-outbound"]
                                 ? UIColor.systemRedColor
                             : [rule isEqual:@"block-inbound"] ? UIColor.systemOrangeColor
                                                               : nil;
            if (color) {
                cell.backgroundColor = [color colorWithAlphaComponent:0.14];
            }
            cell.textLabel.text = [self globalRuleTitle:key];
            cell.detailTextLabel.text = [self ruleTitle:rule];
        }
    } else if (path.section == NSDashboardSectionRules) {
        if (!self.identities.count) {
            cell.textLabel.text = @"Apps appear here when they connect";
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else {
            NSString *identity = self.identities[path.row];
            NSString *rule = self.policy.document[@"rules"][identity];
            UIColor *color = [rule isEqual:@"allow"] ? UIColor.systemGreenColor
                             : [rule isEqual:@"block"] || [rule isEqual:@"block-outbound"]
                                 ? UIColor.systemRedColor
                             : [rule isEqual:@"block-inbound"] ? UIColor.systemOrangeColor
                                                               : nil;
            if (color) {
                cell.backgroundColor = [color colorWithAlphaComponent:0.14];
            }
            cell.textLabel.text = identity;
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
            UIColor *color = allowed ? UIColor.systemGreenColor : blocked ? UIColor.systemRedColor : nil;
            if (color) {
                cell.backgroundColor = [color colorWithAlphaComponent:0.14];
            }
            if ([event[@"identity"] length]) {
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            cell.textLabel.text = [NSString
                stringWithFormat:@"%@ / %@", action,
                                 [event[@"identity"] length] ? event[@"identity"] : @"Unidentified app"];
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
        cell.textLabel.text = path.row == 0 ? @"GitHub Link" : @"Support Developer";
        cell.detailTextLabel.text =
            path.row == 0 ? @"Source code, releases and issues" : @"Choose Venmo or Bitcoin";
        cell.textLabel.textColor = UIColor.systemBlueColor;
    } else {
        cell.textLabel.text = @[
            @"Add a rule by app identity", @"Add a rule by IP / Domain", @"Add a rule by port number",
            @"Reset Rules & History", @"Reset ALL Settings"
        ][path.row];
        cell.detailTextLabel.text = @[
            @"For an exact identity supplied by iOS", @"For an IP or domain across all processes",
            @"For a remote port across all processes", @"Reset rules and history only",
            @"Removes all rules, permissions and filters. Runs automatically during uninstall."
        ][path.row];
        if (path.row > 2) {
            cell.textLabel.textColor = UIColor.systemRedColor;
        }
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
    } else if (path.section == NSDashboardSectionGlobalRules && self.globalRuleKeys.count) {
        [self chooseGlobalRule:self.globalRuleKeys[path.row]];
    } else if (path.section == NSDashboardSectionRules && self.identities.count) {
        [self chooseActionForIdentity:self.identities[path.row] defaultKey:nil];
    } else if (path.section == NSDashboardSectionActivity && self.activityGroups.count) {
        NSString *identity = self.activityGroups[path.row][@"identity"];
        if (identity.length) {
            [self chooseActionForIdentity:identity defaultKey:nil];
        }
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
        } else {
            [self supportDeveloper];
        }
    } else if (path.section == NSDashboardSectionAdvanced) {
        if (path.row == 0) {
            [self addIdentity];
        } else if (path.row == 1 || path.row == 2) {
            [self addGlobalRuleByPort:path.row == 2];
        } else if (path.row < 5) {
            BOOL reset = path.row == 3;
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:reset ? @"Reset Rules & History?" : @"Reset ALL Settings?"
                                 message:reset ? @"Deletes app and global rules, pending requests and "
                                                 @"history only. "
                                                 @"Keeps your settings and restores the firewall's previous "
                                                 @"on/off state after stopping it to reset."
                                               : @"Removes all NetShield2 rules, permissions and history, "
                                                 @"restores default settings, and removes the system filter. "
                                                 @"Package-manager uninstall removes the filter "
                                                 @"automatically. iOS notification authorization "
                                                 @"must be managed in Settings."
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction
                                 actionWithTitle:reset ? @"Reset rules and history" : @"Reset all settings"
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

@end
