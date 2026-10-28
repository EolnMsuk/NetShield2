#import "NSRuleActionController.h"
#import "NSRuleAppearance.h"

@interface NSRuleActionController ()
@property(nonatomic, copy) NSString *message;
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
    self.tableView.estimatedRowHeight = 84;
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
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 + self.detailRows.count : self.choices.count;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 0 && self.detailRows.count ? self.message : nil;
}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return section == 0 && self.detailRows.count ? UITableViewAutomaticDimension : 12;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                   reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    if (path.section == 0) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (path.row == 0) {
            cell.textLabel.text = self.title;
            cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
            cell.detailTextLabel.text = self.detailRows.count ? nil : self.message;
            cell.accessibilityTraits |= UIAccessibilityTraitHeader;
        } else {
            NSArray *detail = self.detailRows[path.row - 1];
            cell.textLabel.text = detail[0];
            cell.textLabel.textColor = UIColor.secondaryLabelColor;
            cell.detailTextLabel.text = detail[1];
            cell.detailTextLabel.textColor = UIColor.labelColor;
        }
    } else {
        NSDictionary *choice = self.choices[path.row];
        UIColor *color = NSRuleColor(choice[@"rule"]);
        BOOL selected = [choice[@"rule"] length] && [choice[@"rule"] isEqual:self.selectedRule];
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
            // Keep the enlarged row height independent of the action font size,
            // centering the text with equal padding above and below.
            CGFloat rowHeight = MAX(44, bodyFont.lineHeight + 24) * 1.5;
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
    if (path.section == 0) {
        return;
    }
    tableView.userInteractionEnabled = NO;
    void (^handler)(void) = self.choices[path.row][@"handler"];
    // Finish dismissing before saving or opening the editor, so neither the
    // permission-refresh timer nor a subsequent presentation races this sheet.
    [self dismissViewControllerAnimated:YES completion:handler];
}
@end
