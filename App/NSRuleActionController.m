#import "NSRuleActionController.h"
#import "NSRuleAppearance.h"
#import "../Shared/NSRuleChoices.h"

@interface NSRuleActionController ()
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *choices;
@end

@implementation NSRuleActionController
+ (instancetype)controllerWithTitle:(NSString *)title message:(NSString *)message {
    NSRuleActionController *controller = [[self alloc] initWithStyle:UITableViewStyleInsetGrouped];
    controller.title = title;
    controller.message = message;
    controller.choices = [NSMutableArray new];
    controller.centersActions = YES;
    controller.modalPresentationStyle = UIModalPresentationPageSheet;
    return controller;
}
- (void)addActionWithTitle:(NSString *)title rule:(NSString *)rule handler:(void (^)(void))handler {
    [self.choices addObject:@{@"title": title, @"rule": rule ?: @"",
                              @"handler": [handler ?: ^{} copy]}];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 63;
    self.tableView.sectionHeaderHeight = 12;
    self.tableView.sectionFooterHeight = 12;
    if (self.modalPresentationStyle == UIModalPresentationPageSheet) {
        self.sheetPresentationController.detents = @[
            UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent
        ];
        if (self.opensExpanded) {
            self.sheetPresentationController.selectedDetentIdentifier =
                UISheetPresentationControllerDetentIdentifierLarge;
        }
        self.sheetPresentationController.prefersGrabberVisible = YES;
    }
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.modalPresentationStyle == UIModalPresentationPopover) {
        CGSize bounds = self.presentingViewController.view.bounds.size;
        CGSize size = CGSizeMake(MIN(360, bounds.width - 32),
                                 MIN(self.tableView.contentSize.height, bounds.height * 0.8));
        if (!CGSizeEqualToSize(size, self.preferredContentSize)) {
            self.preferredContentSize = size;
        }
    }
}
- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:
    (UIPresentationController *)controller {
    return UIModalPresentationNone;
}
- (NSInteger)logicalSection:(NSInteger)section {
    return self.connectionLayout ? [@[ @1, @0, @3, @2 ][section] integerValue] : section;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.clipboardText ? 4 : self.detailRows.count ? 3 : 2;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    section = [self logicalSection:section];
    return section == 0 || section == 3 ? 1 : section == 1 ? self.choices.count : self.detailRows.count;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    section = [self logicalSection:section];
    return section == 2 || (section == 0 && self.centersTitle && !self.detailRows.count) ? self.message : nil;
}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    section = [self logicalSection:section];
    return section == 2 || (section == 0 && self.centersTitle && !self.detailRows.count)
               ? UITableViewAutomaticDimension
               : 12;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    path = [NSIndexPath indexPathForRow:path.row inSection:[self logicalSection:path.section]];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                   reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    if (path.section == 3) {
        cell.textLabel.text = @"Copy details";
        cell.textLabel.textColor = UIColor.systemBlueColor;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.accessibilityTraits |= UIAccessibilityTraitButton;
    } else if (path.section != 1) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (path.section == 0) {
            cell.textLabel.text = self.title;
            cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
            cell.detailTextLabel.text = self.detailRows.count ? nil : self.message;
            if (self.centersTitle) {
                cell.textLabel.text = nil;
                UILabel *label = [UILabel new];
                label.translatesAutoresizingMaskIntoConstraints = NO;
                label.text = self.title;
                label.textAlignment = NSTextAlignmentCenter;
                label.numberOfLines = 0;
                label.lineBreakMode = NSLineBreakByCharWrapping;
                label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
                label.adjustsFontForContentSizeCategory = YES;
                [cell.contentView addSubview:label];
                [NSLayoutConstraint activateConstraints:@[
                    [label.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:20],
                    [label.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor
                                                         constant:-20],
                    [label.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:16],
                    [label.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-16]
                ]];
                // Keep the explanation in a footer when a custom title label owns the cell.
                cell.detailTextLabel.text = nil;
                cell.isAccessibilityElement = YES;
                cell.accessibilityLabel = self.title;
            }
            cell.accessibilityTraits |= UIAccessibilityTraitHeader;
        } else {
            NSArray *detail = self.detailRows[path.row];
            cell.textLabel.text = detail[0];
            cell.textLabel.textColor = UIColor.secondaryLabelColor;
            cell.detailTextLabel.text = detail[1];
            cell.detailTextLabel.textColor = UIColor.labelColor;
        }
    } else {
        NSDictionary *choice = self.choices[path.row];
        UIColor *color = NSRuleColor(choice[@"rule"]);
        BOOL selected = [choice[@"rule"] length] && ([choice[@"rule"] isEqual:self.selectedRule] ||
                                                     [self.selectedRules containsObject:choice[@"rule"]]);
        UIColor *textColor = selected ? UIColor.labelColor : (color ?: UIColor.systemBlueColor);
        UIFont *bodyFont = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        UIFont *actionFont = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
            scaledFontForFont:[UIFont systemFontOfSize:17 * 1.5 * 0.75]];
        if (self.centersActions) {
            // Subtitle cells size their built-in label to its text. Keep equal
            // margins around this label, even when a selection checkmark is shown.
            UILabel *label = [UILabel new];
            label.translatesAutoresizingMaskIntoConstraints = NO;
            label.text = choice[@"title"];
            label.textAlignment = NSTextAlignmentCenter;
            label.textColor = textColor;
            label.font = actionFont;
            label.adjustsFontForContentSizeCategory = YES;
            label.numberOfLines = 0;
            // Keep the compact row height independent of the action font size,
            // centering the text with equal padding above and below.
            CGFloat rowHeight = MAX(44, bodyFont.lineHeight + 24) * 1.5 * 0.75;
            CGFloat verticalPadding = (rowHeight - label.font.lineHeight) / 2;
            [cell.contentView addSubview:label];
            [NSLayoutConstraint activateConstraints:@[
                [label.centerXAnchor constraintEqualToAnchor:cell.centerXAnchor],
                [label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:48],
                [label.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:verticalPadding],
                [label.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor
                                                   constant:-verticalPadding],
                [cell.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:rowHeight]
            ]];
            cell.isAccessibilityElement = YES;
            cell.accessibilityLabel = choice[@"title"];
        } else {
            cell.textLabel.text = choice[@"title"];
            cell.textLabel.textColor = textColor;
            cell.textLabel.font = actionFont;
        }
        cell.tintColor = selected ? UIColor.labelColor : (color ?: UIColor.systemBlueColor);
        if (selected && color) {
            cell.backgroundColor = [color colorWithAlphaComponent:0.14];
        }
        cell.accessibilityTraits |= UIAccessibilityTraitButton;
        if (selected) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
            cell.accessibilityTraits |= UIAccessibilityTraitSelected;
        }
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    NSIndexPath *visiblePath = path;
    path = [NSIndexPath indexPathForRow:path.row inSection:[self logicalSection:path.section]];
    if (path.section == 3) {
        UIPasteboard.generalPasteboard.string = self.clipboardText;
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:visiblePath];
        cell.textLabel.text = @"Copied";
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"Copied to clipboard");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            cell.textLabel.text = @"Copy details";
        });
        return;
    }
    if (path.section != 1) {
        return;
    }
    NSString *rule = self.choices[path.row][@"rule"];
    if (self.keepsRuleSelectionsOpen && [NSDirectionRuleValues() containsObject:rule]) {
        if ([self.selectedRules containsObject:rule]) {
            return;
        }
        void (^save)(void) = self.choices[path.row][@"handler"];
        tableView.userInteractionEnabled = NO;
        save();
        tableView.userInteractionEnabled = YES;
        [tableView reloadData];
        return;
    }
    tableView.userInteractionEnabled = NO;
    void (^handler)(void) = self.choices[path.row][@"handler"];
    // Finish dismissing before saving or opening the editor, so neither the
    // permission-refresh timer nor a subsequent presentation races this sheet.
    [self dismissViewControllerAnimated:YES completion:handler];
}
@end
