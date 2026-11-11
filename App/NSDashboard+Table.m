#import "../Shared/NSPermissionRequest.h"
#import "../Shared/NSRuleChoices.h"
#import "NSSectionTypography.h"
#import "NSDashboard+Internal.h"
#import "../Shared/NSActivity.h"

static UIBackgroundConfiguration *NSDashboardBackground(UICellConfigurationState *state, UIColor *tint) {
    UIBackgroundConfiguration *background =
        [[UIBackgroundConfiguration listGroupedCellConfiguration] updatedConfigurationForState:state];
    if (tint && !state.highlighted && !state.selected) {
        UIColor *base = UIColor.secondarySystemGroupedBackgroundColor;
        UIColor *resolvedBase = [base resolvedColorWithTraitCollection:state.traitCollection];
        UIColor *resolvedTint = [tint resolvedColorWithTraitCollection:state.traitCollection];
        CGFloat red, green, blue, tintRed, tintGreen, tintBlue;
        if ([resolvedBase getRed:&red green:&green blue:&blue alpha:NULL] && [resolvedTint getRed:&tintRed
                                                                                            green:&tintGreen
                                                                                             blue:&tintBlue
                                                                                            alpha:NULL]) {
            background.backgroundColor = [UIColor colorWithRed:red * 0.86 + tintRed * 0.14
                                                         green:green * 0.86 + tintGreen * 0.14
                                                          blue:blue * 0.86 + tintBlue * 0.14
                                                         alpha:1];
        }
    }
    return background;
}

static void NSConfigureDashboardBackground(UITableViewCell *cell, UIColor *tint) {
    cell.automaticallyUpdatesBackgroundConfiguration = NO;
    cell.backgroundConfiguration = NSDashboardBackground(cell.configurationState, tint);
    cell.configurationUpdateHandler = ^(UITableViewCell *updated, UICellConfigurationState *state) {
        updated.backgroundConfiguration = NSDashboardBackground(state, tint);
    };
}

static UIImage *NSDashboardGitHubIcon(void) {
    static UIImage *icon;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIImage *logo = [UIImage imageNamed:@"GitHubLogo"];
        if (!logo) {
            return;
        }
        CGRect bounds = CGRectMake(0, 0, 24, 24);
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:bounds];
        UIImage *rendered = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:bounds];
            [UIColor.whiteColor setFill];
            [circle fill];
            [circle addClip];
            [logo drawInRect:CGRectInset(bounds, 1, 1)];
        }];
        icon = [rendered imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    });
    return icon;
}

static UIImage *NSDashboardUpdateIcon(void) {
    static UIImage *icon;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSAttributedString *emoji =
            [[NSAttributedString alloc] initWithString:@"🔄"
                                            attributes:@{NSFontAttributeName : [UIFont systemFontOfSize:20]}];
        CGSize size = CGSizeMake(24, 24);
        CGSize emojiSize = emoji.size;
        CGPoint origin =
            CGPointMake((size.width - emojiSize.width) / 2, (size.height - emojiSize.height) / 2);
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
        UIImage *rendered = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [emoji drawAtPoint:origin];
        }];
        icon = [rendered imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    });
    return icon;
}

// Align the visible field, rather than the UISearchBar's padded outer bounds.
@interface NSActivitySearchBar : UISearchBar
@end
@implementation NSActivitySearchBar
- (void)layoutSubviews {
    [super layoutSubviews];
    UITextField *field = self.searchTextField;
    CGRect available = [self convertRect:self.bounds toView:field.superview];
    CGRect frame = field.frame;
    frame.origin.x = available.origin.x;
    frame.size.width = available.size.width;
    field.frame = frame;
}
@end

@interface NSDashboardClearButton : UIButton
@end
@implementation NSDashboardClearButton
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGFloat extra = MAX(0, (44 - self.bounds.size.height) / 2);
    return CGRectContainsPoint(CGRectInset(self.bounds, 0, -extra), point);
}
@end

// UIKit may inset the header itself. Measure cells in header coordinates so the
// Clear button ends at the group's edge, without adding a second trailing inset.
@interface NSDashboardSectionHeader : UIView
@property(nonatomic, weak) UITableView *table;
@property(nonatomic) NSInteger section;
@property(nonatomic, strong) UILayoutGuide *cardLayoutGuide;
@property(nonatomic, strong) NSLayoutConstraint *cardLeft;
@property(nonatomic, strong) NSLayoutConstraint *cardRight;
@end
@implementation NSDashboardSectionHeader
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _cardLayoutGuide = [UILayoutGuide new];
        [self addLayoutGuide:_cardLayoutGuide];
        _cardLeft = [_cardLayoutGuide.leftAnchor constraintEqualToAnchor:self.leftAnchor];
        _cardRight = [_cardLayoutGuide.rightAnchor constraintEqualToAnchor:self.rightAnchor];
        [NSLayoutConstraint activateConstraints:@[
            _cardLeft, _cardRight, [_cardLayoutGuide.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_cardLayoutGuide.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]
        ]];
    }
    return self;
}
- (void)layoutSubviews {
    UITableViewCell *cell = [self.table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0
                                                                                 inSection:self.section]];
    cell = cell ?: self.table.visibleCells.firstObject;
    CGRect group =
        cell ? [cell convertRect:cell.bounds toView:self]
             : [self.table convertRect:UIEdgeInsetsInsetRect(self.table.bounds, self.table.layoutMargins)
                                toView:self];
    CGFloat left = MAX(0, CGRectGetMinX(group));
    CGFloat right = MAX(0, self.bounds.size.width - CGRectGetMaxX(group));
    self.cardLeft.constant = left;
    self.cardRight.constant = -right;
    BOOL rtl = self.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    NSDirectionalEdgeInsets margins =
        NSDirectionalEdgeInsetsMake(12, (rtl ? right : left) + 20, 8, rtl ? left : right);
    if (!NSDirectionalEdgeInsetsEqualToDirectionalEdgeInsets(self.directionalLayoutMargins, margins)) {
        self.directionalLayoutMargins = margins;
    }
    [super layoutSubviews];
}
@end

@implementation NSDashboard (Table)
- (void)keepActivitySearchVisible {
    UITextField *field = self.activitySearchBar.searchTextField;
    if (!field.isFirstResponder || !field.window || ![field isDescendantOfView:self.tableView]) {
        return;
    }
    [self.tableView layoutIfNeeded];
    CGRect fieldRect = [field convertRect:field.bounds toView:self.tableView];
    [self.tableView scrollRectToVisible:CGRectInset(fieldRect, 0, -12) animated:NO];
}
- (void)activityKeyboardFrameDidChange:(NSNotification *)notification {
    // Let UITableViewController finish updating its keyboard insets, including
    // changes to the predictive text bar, before revealing the header's field.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self keepActivitySearchVisible];
    });
}
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    self.activityQuery = searchText ?: @"";
    searchBar.searchTextField.rightViewMode =
        self.activityQuery.length ? UITextFieldViewModeAlways : UITextFieldViewModeNever;
    [self refreshTableKeepingPosition];
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [self dismissActivityKeyboard];
}
- (void)dismissActivityKeyboard {
    [self.activitySearchBar.searchTextField resignFirstResponder];
}
- (void)clearActivitySearch {
    // This control owns clearing, so UISearchBar never implicitly starts editing.
    self.activitySearchBar.text = @"";
    [self searchBar:self.activitySearchBar textDidChange:@""];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (self.navigationController.topViewController == self && !self.presentedViewController &&
        ![touch.view isDescendantOfView:self.activitySearchBar.searchTextField]) {
        // Observe the touch without competing with rows, switches, or scrolling.
        [self dismissActivityKeyboard];
    }
    return NO;
}
- (BOOL)showsAppRules {
    return self.identities.count > 0;
}
- (BOOL)showsSystemRules {
    return self.policy && ![self.policy.document[@"allowAppleSystemProcesses"] boolValue] &&
           self.systemIdentities.count > 0;
}
- (BOOL)isRuleSectionHidden:(NSInteger)section {
    return (section == NSDashboardSectionRules && ![self showsAppRules]) ||
           (section == NSDashboardSectionSystemRules && ![self showsSystemRules]);
}
- (NSArray<NSString *> *)identitiesForSection:(NSInteger)section {
    return section == NSDashboardSectionSystemRules ? self.systemIdentities : self.identities;
}
- (NSUInteger)itemCountForClearSection:(NSInteger)section {
    if (section == NSDashboardSectionActivity) {
        return [self.monitor[@"events"] count];
    }
    if (section == NSDashboardSectionGlobalRules) {
        return self.globalRuleKeys.count;
    }
    if (section == NSDashboardSectionRules || section == NSDashboardSectionSystemRules) {
        return [self identitiesForSection:section].count;
    }
    return 0;
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
    if (path.section == NSDashboardSectionActivity && self.filteredActivityGroups.count) {
        return self.filteredActivityGroups[path.row][@"groupKey"];
    }
    return @(path.row);
}
- (id)heightKey:(NSIndexPath *)path {
    return @[
        @(path.section), [self rowKey:path],
        path.section == NSDashboardSectionActivity && self.filteredActivityGroups.count
            ? self.filteredActivityGroups[path.row][@"time"]
            : @0,
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
    if (self.rowHeights.count >= 512) {
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
        [self.policy.document dictionaryWithValuesForKeys:@[
            @"rules", @"globalRules", @"default", @"unattributed", @"filterSockets",
            @"allowAppleSystemProcesses", @"ruleDestinations"
        ]]
            ?: @{},
        self.monitor[@"requests"] ?: @[],
        self.monitor[@"events"] ?: @[],
        self.monitor[@"policyError"] ?: @"",
        self.monitor[@"dnsIssue"] ?: @"",
        self.monitor[@"notificationDeliveryIssue"] ?: @"",
        @([self hasFreshMonitor]),
        @(self.preferencesLoaded),
        @(self.hasSavedPreferences),
        @(self.configurationReady),
        @(self.busy),
        self.configurationProgress ?: @"",
        @(self.savedEnabled),
        @(self.savedSocketFiltering),
        @(self.savedBrowserFiltering),
        self.preferenceReadError ?: @"",
        self.configurationRecoveryError ?: @"",
        self.configurationOperationError ?: @"",
        @(self.configurationRecoveryAction),
        @(self.configurationOperationAction),
        self.message ?: @"",
        self.bootPolicyStatus ?: @"",
        @(self.bootPolicyNeedsAttention),
        self.notificationStatus ?: @"",
        self.policyReadError ?: @"",
        @(self.policyMissing),
        self.monitorReadError ?: @"",
        self.monitor[@"overflowCount"] ?: @0,
        self.monitor[@"droppedWorkCount"] ?: @0,
        self.monitor[@"evictedRequestCount"] ?: @0,
        self.identities ?: @[],
        self.systemIdentities ?: @[],
        self.activityQuery ?: @"",
        NSUpdateCheckMode(NSUserDefaults.standardUserDefaults),
        @(self.clearingSection)
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
    // Grouping is prepared on the app storage worker with its monitor snapshot.
    self.filteredActivityGroups = [self.activityGroups
        filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *connection,
                                                                          NSDictionary *bindings) {
            return NSActivityMatchesQuery(connection, self.activityQuery);
        }]];
    UITextField *searchField = self.activitySearchBar.searchTextField;
    BOOL searching = searchField.isFirstResponder;
    UITextRange *selection = searchField.selectedTextRange;
    NSInteger selectionStart = selection ? [searchField offsetFromPosition:searchField.beginningOfDocument
                                                                toPosition:selection.start]
                                         : 0;
    NSInteger selectionEnd = selection ? [searchField offsetFromPosition:searchField.beginningOfDocument
                                                              toPosition:selection.end]
                                       : 0;
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
        if (searching) {
            [searchField becomeFirstResponder];
            UITextPosition *start = [searchField positionFromPosition:searchField.beginningOfDocument
                                                               offset:selectionStart];
            UITextPosition *end = [searchField positionFromPosition:searchField.beginningOfDocument
                                                             offset:selectionEnd];
            if (start && end) {
                searchField.selectedTextRange = [searchField textRangeFromPosition:start toPosition:end];
            }
        }
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
        // Restoring row anchors after filtering must not hide the active search.
        [self keepActivitySearchVisible];
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
        return [self.monitor[@"requests"] count];
    }
    if (section == NSDashboardSectionRules) {
        return self.identities.count;
    }
    if (section == NSDashboardSectionSystemRules) {
        return [self showsSystemRules] ? self.systemIdentities.count : 0;
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
    return MAX((NSUInteger)1, self.filteredActivityGroups.count);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == NSDashboardSectionRequests && ![self.monitor[@"requests"] count]) {
        return nil;
    }
    if (section == NSDashboardSectionGlobalRules && !self.globalRuleKeys.count) {
        return nil;
    }
    if ([self isRuleSectionHidden:section]) {
        return nil;
    }
    return @[
        @"FIREWALL", @"WAITING FOR YOUR DECISION", @"NOTIFICATIONS", @"CONFIGURATION", @"", @"GLOBAL RULES",
        @"", @"SYSTEM RULES", @"APP RULES", @"RECENT ACTIVITY"
    ][section];
}
- (NSString *)firewallFooterText {
    BOOL enabled = self.preferencesLoaded && self.savedEnabled;
    BOOL fresh = [self hasFreshMonitor];
    BOOL configurationIssue =
        !self.preferencesLoaded || !self.configurationReady || self.preferenceReadError.length ||
        self.configurationRecoveryError.length || self.configurationOperationError.length ||
        self.configurationRecoveryAction != NSConfigurationRecoveryNone ||
        self.configurationOperationAction != NSConfigurationRecoveryNone || self.bootPolicyNeedsAttention;
    // A removed policy while normally off does not imply a provider failure.
    BOOL policyIssue = (self.policyReadError.length && !self.policyMissing) ||
                       (enabled && (!self.policy || self.policyMissing));
    BOOL providerIssue =
        enabled && (!fresh || self.monitorReadError.length ||
                    (fresh && ([self.monitor[@"policyError"] length] || [self.monitor[@"dnsIssue"] length] ||
                               [self.monitor[@"droppedWorkCount"] unsignedLongLongValue])));
    BOOL scopeIssue =
        enabled &&
        ((!self.savedBrowserFiltering && !self.savedSocketFiltering) ||
         (self.policy && self.savedSocketFiltering != [self.policy.document[@"filterSockets"] boolValue]));
    return configurationIssue || policyIssue || providerIssue || scopeIssue
               ? (self.bootPolicyStatus ?: @"Fallback policy state unavailable.")
               : nil;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == NSDashboardSectionSystemRules) {
        return [self showsSystemRules] ? @"Tap a system identity to change its rule." : nil;
    }
    if ((section == NSDashboardSectionAddGlobalRule && !self.globalRuleKeys.count) ||
        (section == NSDashboardSectionGlobalRules && self.globalRuleKeys.count)) {
        return @"Overrides app & system rules.";
    }
    if (section == NSDashboardSectionFirewall) {
        return [self firewallFooterText];
    }
    if (section == NSDashboardSectionRequests) {
        if (![self.monitor[@"requests"] count]) {
            return nil;
        }
        return [NSString stringWithFormat:@"During this filter session: %@ connections rejected at queue "
                                          @"capacity; %@ older requests removed. ",
                                          self.monitor[@"overflowCount"] ?: @0,
                                          self.monitor[@"evictedRequestCount"] ?: @0];
    }
    if (section == NSDashboardSectionRules) {
        return [self showsAppRules] ? @"Tap an app identity to change its rule." : nil;
    }
    if (section == NSDashboardSectionActivity) {
        return @"Up to 300 recorded events";
    }
    return nil;
}
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if ([self isRuleSectionHidden:section]) {
        return nil;
    }
    BOOL scoped = section == NSDashboardSectionActivity || section == NSDashboardSectionRules ||
                  section == NSDashboardSectionGlobalRules || section == NSDashboardSectionSystemRules;
    NSString *heading = [self tableView:tableView titleForHeaderInSection:section];
    BOOL globalRulesHeader = section == NSDashboardSectionGlobalRules && self.globalRuleKeys.count;
    if (heading.length || globalRulesHeader) {
        NSUInteger count = [self itemCountForClearSection:section];
        BOOL hasItems = count > 0;
        BOOL canClear = hasItems && !self.busy && !self.clearingSection &&
                        (section == NSDashboardSectionActivity || self.policy != nil);
        if (section == NSDashboardSectionActivity && self.activityHeader) {
            if (self.activityHeaderHasClear == hasItems) {
                self.activityClearButton.enabled = canClear;
                return self.activityHeader;
            }
            self.activityHeader = nil;
            self.activityClearButton = nil;
        }
        NSDashboardSectionHeader *header = [NSDashboardSectionHeader new];
        header.insetsLayoutMarginsFromSafeArea = NO;
        header.table = tableView;
        header.section = section;
        header.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(12, 20, 8, 0);
        UILabel *title = [UILabel new];
        title.translatesAutoresizingMaskIntoConstraints = NO;
        title.text = [self tableView:tableView titleForHeaderInSection:section];
        title.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
            scaledFontForFont:[UIFont systemFontOfSize:16]];
        title.adjustsFontForContentSizeCategory = YES;
        title.textColor = UIColor.secondaryLabelColor;
        title.numberOfLines = 0;
        title.accessibilityTraits |= UIAccessibilityTraitHeader;
        [header addSubview:title];
        UILayoutGuide *margins = header.layoutMarginsGuide;
        if (!scoped) {
            [NSLayoutConstraint activateConstraints:@[
                [title.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
                [title.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
                [title.topAnchor constraintEqualToAnchor:margins.topAnchor],
                [title.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor]
            ]];
            return header;
        }
        UIButton *clear = nil;
        if (hasItems) {
            clear = [NSDashboardClearButton buttonWithType:UIButtonTypeSystem];
            clear.translatesAutoresizingMaskIntoConstraints = NO;
            [clear setTitle:@"Clear" forState:UIControlStateNormal];
            UIColor *clearTextColor =
                [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
                    return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? UIColor.blackColor
                                                                                 : UIColor.darkGrayColor;
                }];
            [clear setTitleColor:clearTextColor forState:UIControlStateNormal];
            [clear setTitleColor:clearTextColor forState:UIControlStateDisabled];
            clear.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
                return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? UIColor.grayColor
                                                                             : UIColor.whiteColor;
            }];
            clear.layer.cornerRadius = 8;
            clear.titleLabel.adjustsFontForContentSizeCategory = YES;
            UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
            configuration.contentInsets = NSDirectionalEdgeInsetsMake(4, 12, 4, 12);
            configuration.baseForegroundColor = clearTextColor;
            configuration.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *incoming) {
                NSMutableDictionary *attributes = [incoming mutableCopy];
                UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
                attributes[NSFontAttributeName] = [font fontWithSize:font.pointSize * 1.25];
                attributes[NSForegroundColorAttributeName] = clearTextColor;
                return attributes;
            };
            clear.configuration = configuration;
            clear.tag = section;
            clear.accessibilityLabel =
                globalRulesHeader ? @"Clear Global Rules" : [@"Clear " stringByAppendingString:title.text];
            clear.enabled = canClear;
            [clear addTarget:self
                          action:@selector(clearSectionTapped:)
                forControlEvents:UIControlEventTouchUpInside];
            [header addSubview:clear];
            [NSLayoutConstraint activateConstraints:@[
                [title.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
                [title.trailingAnchor constraintLessThanOrEqualToAnchor:clear.leadingAnchor constant:-12],
                [title.topAnchor constraintGreaterThanOrEqualToAnchor:margins.topAnchor],

                [clear.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
                [clear.topAnchor constraintEqualToAnchor:margins.topAnchor],
                [title.bottomAnchor constraintEqualToAnchor:clear.bottomAnchor],
                [clear.heightAnchor constraintGreaterThanOrEqualToConstant:33],
                [clear.widthAnchor constraintGreaterThanOrEqualToConstant:64]
            ]];
        } else {
            [NSLayoutConstraint activateConstraints:@[
                [title.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
                [title.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
                [title.topAnchor constraintEqualToAnchor:margins.topAnchor]
            ]];
        }
        if (section == NSDashboardSectionActivity) {
            self.activityHeader = header;
            self.activityHeaderHasClear = hasItems;
            self.activityClearButton = clear;
            if (!self.activitySearchBar) {
                self.activitySearchBar = [NSActivitySearchBar new];
                self.activitySearchBar.searchBarStyle = UISearchBarStyleMinimal;
                self.activitySearchBar.placeholder = @"Search recent connections";
                self.activitySearchBar.accessibilityLabel = @"Search Recent Activity";
                self.activitySearchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
                self.activitySearchBar.autocorrectionType = UITextAutocorrectionTypeNo;
                self.activitySearchBar.delegate = self;
                self.activitySearchBar.text = self.activityQuery;
                UITextField *field = self.activitySearchBar.searchTextField;
                field.clearButtonMode = UITextFieldViewModeNever;
                UIButton *clearSearch = [UIButton buttonWithType:UIButtonTypeSystem];
                clearSearch.frame = CGRectMake(0, 0, 36, 36);
                [clearSearch setImage:[UIImage systemImageNamed:@"xmark.circle.fill"]
                             forState:UIControlStateNormal];
                clearSearch.tintColor = UIColor.tertiaryLabelColor;
                clearSearch.accessibilityLabel = @"Clear search";
                [clearSearch addTarget:self
                                action:@selector(clearActivitySearch)
                      forControlEvents:UIControlEventTouchUpInside];
                field.rightView = clearSearch;
                field.rightViewMode =
                    self.activityQuery.length ? UITextFieldViewModeAlways : UITextFieldViewModeNever;
            }
            UISearchBar *search = self.activitySearchBar;
            search.translatesAutoresizingMaskIntoConstraints = NO;
            [header addSubview:search];
            [NSLayoutConstraint activateConstraints:@[
                [search.topAnchor constraintEqualToAnchor:(clear ? clear.bottomAnchor : title.bottomAnchor)
                                                 constant:4],
                [search.leadingAnchor constraintEqualToAnchor:header.cardLayoutGuide.leadingAnchor],
                [search.trailingAnchor constraintEqualToAnchor:header.cardLayoutGuide.trailingAnchor],
                [search.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor]
            ]];
        } else if (clear) {
            [clear.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor].active = YES;
        } else {
            [title.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor].active = YES;
        }
        return header;
    }
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
- (void)tableView:(UITableView *)tableView
    willDisplayHeaderView:(UIView *)view
               forSection:(NSInteger)section {
    NSStyleSectionHeader(view);
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (section == NSDashboardSectionRequests && ![self.monitor[@"requests"] count]) {
        return CGFLOAT_MIN;
    }
    if (section == NSDashboardSectionGlobalRules) {
        return self.globalRuleKeys.count ? UITableViewAutomaticDimension : CGFLOAT_MIN;
    }
    return [self isRuleSectionHidden:section] ? CGFLOAT_MIN : UITableViewAutomaticDimension;
}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    if ((section == NSDashboardSectionFirewall && ![self firewallFooterText].length) ||
        (section == NSDashboardSectionRequests && ![self.monitor[@"requests"] count])) {
        return CGFLOAT_MIN;
    }
    if (section == NSDashboardSectionAddGlobalRule && self.globalRuleKeys.count) {
        return CGFLOAT_MIN;
    }
    if (section == NSDashboardSectionGlobalRules && !self.globalRuleKeys.count) {
        return CGFLOAT_MIN;
    }
    // The links header already supplies the inter-section gap and keeps the
    // version label close to the support rows; don't stack an empty footer above it.
    if (section == NSDashboardSectionAdvanced) {
        return CGFLOAT_MIN;
    }
    return [self isRuleSectionHidden:section] ? CGFLOAT_MIN : UITableViewAutomaticDimension;
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
        BOOL firewall = path.row == 0;
        BOOL on =
            firewall ? self.savedEnabled : [self.policy.document[@"allowAppleSystemProcesses"] boolValue];
        BOOL ready = firewall ? (self.preferencesLoaded && self.configurationReady &&
                                 (self.savedEnabled || self.policy != nil || self.policyMissing))
                              : self.policy != nil;
        BOOL enabled = ready && !self.busy;
        toggle.hidden = firewall && !self.hasSavedPreferences;
        if (toggle.on != on) {
            [toggle setOn:on animated:NO];
        }
        if (toggle.enabled != enabled) {
            toggle.enabled = enabled;
        }
        NSConfigureDashboardBackground(cached, nil);
        return cached;
    }
    BOOL persistent = path.section == NSDashboardSectionFirewall && (path.row == 0 || path.row == 2);
    NSString *reuse = persistent ? nil : @"DashboardSubtitle";
    UITableViewCell *cell = reuse ? [tableView dequeueReusableCellWithIdentifier:reuse] : nil;
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    }
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.image = nil;
    UIColor *rowTint = nil;
    cell.accessoryView = nil;
    cell.accessibilityHint = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (path.section == NSDashboardSectionFirewall && path.row == 0) {
        cell.textLabel.text = @"Firewall";
        cell.detailTextLabel.text = @"Enable firewall and monitor";
        cell.imageView.image = [UIImage systemImageNamed:@"shield.lefthalf.filled"];
        UISwitch *toggle = [UISwitch new];
        toggle.on = self.savedEnabled;
        toggle.hidden = !self.hasSavedPreferences;
        toggle.enabled = self.preferencesLoaded && self.configurationReady &&
                         (self.savedEnabled || self.policy != nil || self.policyMissing) && !self.busy;
        toggle.accessibilityLabel = @"Firewall";
        [toggle addTarget:self
                      action:@selector(firewallChanged:)
            forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == NSDashboardSectionFirewall && path.row == 3) {
        BOOL enabled = self.preferencesLoaded && self.savedEnabled;
        BOOL healthy =
            enabled && self.policy && [self hasFreshMonitor] && ![self.monitor[@"policyError"] length];
        NSString *detail = nil;
        if (self.busy) {
            cell.textLabel.text = self.configurationProgress ?: @"Updating…";
        } else if (!self.preferencesLoaded) {
            cell.textLabel.text = @"Saved preferences unavailable";
            if (self.hasSavedPreferences) {
                detail = self.savedEnabled ? @"Last successful read showed Firewall on."
                                           : @"Last successful read showed Firewall off.";
            }
        } else if (!self.configurationReady) {
            cell.textLabel.text =
                self.savedEnabled ? @"Saved On. Changes paused." : @"Saved Off. Changes paused.";
        } else if (!enabled) {
            cell.textLabel.text =
                self.configurationOperationError.length ? @"Firewall off. Setup needs attention." : @"Off";
            if (self.policy) {
                detail = @"Turn on Firewall to apply your rules.";
            }
        } else {
            cell.textLabel.text = healthy ? @"Control provider responding" : @"Needs attention";
            if (!healthy) {
                detail = @"Saved On. Waiting for a healthy report from the current control provider.";
            } else if (self.savedBrowserFiltering && self.savedSocketFiltering) {
                detail = @"Browser and socket filtering configured.";
            } else if (self.savedBrowserFiltering) {
                detail = @"Browser filtering configured. Socket filtering is off.";
            } else if (self.savedSocketFiltering) {
                detail = @"Socket filtering configured. Browser filtering is off.";
            } else {
                detail = @"Both filtering scopes are off. Restart Firewall to apply scope.";
            }
        }
        cell.textLabel.textColor =
            healthy && self.configurationReady && !self.busy ? UIColor.systemGreenColor : UIColor.labelColor;
        NSMutableArray<NSString *> *details = [NSMutableArray new];
        if (detail) {
            [details addObject:detail];
        }
        if (self.preferenceReadError.length) {
            [details addObject:[@"Saved preferences: " stringByAppendingString:self.preferenceReadError]];
        }
        if (self.configurationRecoveryError.length) {
            [details addObject:self.configurationRecoveryError];
        }
        if (self.configurationOperationError.length) {
            [details addObject:self.configurationOperationError];
        }
        if (!self.busy) {
            NSConfigurationRecoveryAction action = self.configurationRecoveryAction;
            if (action == NSConfigurationRecoveryNone) {
                action = self.configurationOperationAction;
            }
            NSString *guidance = [NSConfigurationCoordinator guidanceForRecovery:action];
            if (guidance) {
                [details addObject:guidance];
            }
        }
        if (self.policyMissing && !self.configurationReady) {
            [details addObject:@"The policy file is missing. Recover the pending preference operation to "
                               @"initialize rules."];
        } else if (self.policyReadError.length) {
            [details addObject:[@"Policy storage: " stringByAppendingString:self.policyReadError]];
        }
        if (enabled && self.monitorReadError.length) {
            [details addObject:[@"Provider report: " stringByAppendingString:self.monitorReadError]];
        } else if (enabled && [self.monitor[@"policyError"] length] && [self hasFreshMonitor]) {
            [details addObject:[@"Provider policy: " stringByAppendingString:self.monitor[@"policyError"]]];
        }
        if (enabled && self.policy &&
            self.savedSocketFiltering != [self.policy.document[@"filterSockets"] boolValue]) {
            [details addObject:@"Toggle Firewall off and on to apply the saved socket setting."];
        }
        if (healthy && [self.monitor[@"dnsIssue"] length]) {
            [details addObject:self.monitor[@"dnsIssue"]];
        }
        if (healthy && [self.monitor[@"droppedWorkCount"] unsignedLongLongValue]) {
            [details addObject:[NSString stringWithFormat:@"Control work skipped under load: %@.",
                                                          self.monitor[@"droppedWorkCount"]]];
        }
        if (self.message.length && !self.configurationRecoveryError.length) {
            [details addObject:self.message];
        }
        if (self.busy) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.accessibilityHint = @"Refreshes saved preferences and policy.";
            if ([self firewallFooterText].length) {
                [details addObject:@"Tap to refresh saved preferences and policy."];
            }
        }
        cell.detailTextLabel.text = [details componentsJoinedByString:@"\n"];
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
        cell.detailTextLabel.text = @"Required to filter all app network.";
        UISwitch *toggle = [UISwitch new];
        toggle.on = [self.policy.document[@"filterSockets"] boolValue];
        toggle.enabled =
            self.policy != nil && self.preferencesLoaded && self.configurationReady && !self.busy;
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
        NSDictionary *request = self.monitor[@"requests"][path.row];
        BOOL unidentified = NSUnidentifiedRequest(request);
        BOOL expired = [request[@"expired"] boolValue];
        cell.textLabel.text =
            unidentified ? @"Unidentified connection" : NSIdentityDisplayName(request[@"identity"]);
        if (unidentified) {
            NSString *direction = [request[@"direction"] isEqual:@"inbound"]    ? @"Incoming"
                                  : [request[@"direction"] isEqual:@"outbound"] ? @"Outgoing"
                                                                                : @"Direction unavailable";
            NSString *status = expired
                                   ? ([request[@"mode"] isEqual:@"once"]
                                          ? @"Timed out and blocked. Retry to connect."
                                          : @"Timed out and blocked. Tap to decide for future connections.")
                               : [request[@"deferred"] boolValue] ? @"Deferred. Tap to decide."
                                                                  : @"Tap to decide";
            cell.detailTextLabel.text =
                [NSString stringWithFormat:@"%@\n%@ / %@", status, direction,
                                           NSDestinationSummary(request[@"destination"])];
        } else {
            cell.detailTextLabel.text =
                [NSString stringWithFormat:@"%@\nFirst requested peer: %@",
                                           expired ? @"Blocked while waiting. Tap to decide."
                                                   : @"Tap to allow or keep blocking",
                                           NSDestinationSummary(request[@"destination"])];
        }
    } else if (path.section == NSDashboardSectionAddGlobalRule) {
        cell.textLabel.text = @"Add a Custom Rule";
        cell.textLabel.textColor = UIColor.systemGreenColor;
        cell.detailTextLabel.text = @"Choose apps, destinations, ports and protocols";
    } else if (path.section == NSDashboardSectionGlobalRules) {
        NSString *key = self.globalRuleKeys[path.row];
        NSString *rule = self.policy.document[@"globalRules"][key];
        rowTint =
            [rule isKindOfClass:NSDictionary.class]
                ? (NSAppRuleSelections(rule).count == 1 ? NSRuleColor(NSAppRuleSelections(rule).firstObject)
                                                        : nil)
                : NSRuleColor(rule);
        cell.textLabel.text = [self globalRuleTitle:key];
        cell.detailTextLabel.text = [self ruleTitle:rule];
    } else if (path.section == NSDashboardSectionRules || path.section == NSDashboardSectionSystemRules) {
        NSString *identity = [self identitiesForSection:path.section][path.row];
        id rule = self.policy.document[@"rules"][identity];
        rowTint = NSAppRuleColor(rule);
        cell.textLabel.text = NSIdentityDisplayName(identity);
        cell.detailTextLabel.text =
            [self.policy automaticallyAllowsIdentity:identity]
                ? [NSString
                      stringWithFormat:@"Allowed by iOS setting unless a global rule matches. Saved rule: %@",
                                       NSAppRuleSummary(self.policy.document[@"rules"][identity])]
                : NSAppRuleSummary(self.policy.document[@"rules"][identity]);
    } else if (path.section == NSDashboardSectionNotifications) {
        cell.textLabel.text = path.row == 0 ? @"Notification Settings" : @"Banners & Do Not Disturb";
        cell.detailTextLabel.text =
            path.row == 0 ? self.notificationStatus : @"How to answer while using another app";
        if (path.row == 0 && [self hasFreshMonitor] && [self.monitor[@"notificationDeliveryIssue"] length]) {
            cell.detailTextLabel.text = self.monitor[@"notificationDeliveryIssue"];
        }
    } else if (path.section == NSDashboardSectionActivity) {
        NSArray *events = self.filteredActivityGroups;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (!events.count) {
            cell.textLabel.text = self.activityGroups.count ? @"No matching activity" : @"No activity yet";
        } else {
            NSDictionary *event = events[path.row];
            BOOL allowed = [event[@"action"] isEqual:@"allow"];
            BOOL blocked = [event[@"action"] isEqual:@"block"];
            NSString *action =
                allowed   ? @"Allowed"
                : blocked ? @"Blocked"
                          : ([event[@"action"] isEqual:@"mixed"] ? @"Mixed outcomes" : @"Connection");
            rowTint = allowed ? NSRuleColor(@"allow") : blocked ? NSRuleColor(@"block") : nil;
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
            NSDictionary *counts = event[@"outcomeCounts"];
            cell.detailTextLabel.text = [cell.detailTextLabel.text
                stringByAppendingFormat:
                    @"\n%@ allowed / %@ blocked / %@ other\n%@ hosts; most recent peer: %@",
                    counts[@"allow"] ?: @0, counts[@"block"] ?: @0, counts[@"other"] ?: @0,
                    event[@"hostCount"] ?: @1, NSDestinationSummary(event[@"destination"])];
        }
    } else if (path.section == NSDashboardSectionSupport) {
        cell.textLabel.text = @[ @"Check for Updates", @"GitHub Link", @"Donate" ][path.row];
        if (path.row == 0) {
            cell.imageView.image = NSDashboardUpdateIcon();
        } else if (path.row == 2) {
            UIImageSymbolConfiguration *configuration =
                [UIImageSymbolConfiguration configurationWithPointSize:22];
            UIImage *coin = [UIImage systemImageNamed:@"dollarsign.circle.fill"
                                    withConfiguration:configuration];
            cell.imageView.image = [coin imageWithTintColor:UIColor.systemOrangeColor
                                              renderingMode:UIImageRenderingModeAlwaysOriginal];
        } else {
            cell.imageView.image = NSDashboardGitHubIcon();
        }
        cell.detailTextLabel.text =
            @[ [self updateCheckSubtitle], @"Source code, releases and issues",
               @"Choose Venmo or Crypto" ][path.row];
        cell.textLabel.textColor = UIColor.systemBlueColor;
    } else {
        cell.textLabel.text =
            @[ @"Export Rules and Recent Activity", @"Reset Settings",
               @"Remove Filter & Settings" ][path.row];
        cell.detailTextLabel.text = @[
            @"Share rules and recent activity as a JSON file", @"Removes rules, history and resets settings.",
            @"Removes content filter, rules, history and resets settings."
        ][path.row];
        cell.textLabel.textColor = path.row == 0 ? UIColor.systemBlueColor : UIColor.systemRedColor;
    }
    NSConfigureDashboardBackground(cell, rowTint);
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
    if (path.section == NSDashboardSectionFirewall && path.row == 3) {
        [self refreshSavedState];
    } else if (path.section == NSDashboardSectionFirewall && path.row == 5) {
        [self chooseActionForIdentity:nil defaultKey:@"default"];
    } else if (path.section == NSDashboardSectionRequests && [self.monitor[@"requests"] count]) {
        [self presentRequest:self.monitor[@"requests"][path.row]];
    } else if (path.section == NSDashboardSectionAddGlobalRule) {
        [self editGlobalRule:nil];
    } else if (path.section == NSDashboardSectionGlobalRules) {
        [self editGlobalRule:self.globalRuleKeys[path.row]];
    } else if ((path.section == NSDashboardSectionRules || path.section == NSDashboardSectionSystemRules) &&
               [self identitiesForSection:path.section].count) {
        [self chooseActionForIdentity:[self identitiesForSection:path.section][path.row] defaultKey:nil];
    } else if (path.section == NSDashboardSectionActivity && self.filteredActivityGroups.count) {
        NSDictionary *connection = self.filteredActivityGroups[path.row];
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
            [self presentUpdateOptions];
        } else if (path.row == 1) {
            [self openSupportURL:[NSURL URLWithString:@"https://github.com/EolnMsuk/NetShield2/"]];
        } else if (path.row == 2) {
            [self supportDeveloper];
        }
    } else if (path.section == NSDashboardSectionAdvanced) {
        if (path.row == 0) {
            [self exportRulesAndRecentActivityFromRow:path];
        } else {
            BOOL removeFilter = path.row == 2;
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:removeFilter ? @"Remove Filter & Settings?" : @"Reset Settings?"
                                 message:removeFilter ? @"Removes the content filter, rules and "
                                                        @"history, then resets settings."
                                                      : @"Removes rules and history, resets settings, "
                                                        @"and disables the installed content filter."
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:removeFilter ? @"Remove Filter & Settings"
                                                                         : @"Reset Settings"
                                                      style:UIAlertActionStyleDestructive
                                                    handler:^(UIAlertAction *action) {
                                                        self.removeFilterAfterReset = removeFilter;
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
                              void (^finished)(BOOL) = ^(BOOL saved) {
                                  completion(saved);
                                  [tableView setEditing:NO animated:YES];
                                  [self reloadMonitor];
                              };
                              if (!global) {
                                  [self removeAppRuleForIdentity:key completion:finished];
                              } else {
                                  [self
                                      updatePolicy:^BOOL(NSMutableDictionary *document, NSError **error) {
                                          NSMutableDictionary *rules = [document[@"globalRules"] mutableCopy];
                                          [rules removeObjectForKey:key];
                                          document[@"globalRules"] = rules;
                                          return YES;
                                      }
                                        completion:finished];
                              }
                          }];
    remove.backgroundColor = UIColor.systemRedColor;
    UISwipeActionsConfiguration *configuration =
        [UISwipeActionsConfiguration configurationWithActions:@[ remove ]];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}
@end
