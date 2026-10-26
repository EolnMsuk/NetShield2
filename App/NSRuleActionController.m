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
    self.tableView.estimatedRowHeight = 56;
    self.tableView.sectionHeaderHeight = 12;
    self.tableView.sectionFooterHeight = 12;
    if (self.modalPresentationStyle == UIModalPresentationPageSheet) {
        self.sheetPresentationController.detents = @[
            UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent
        ];
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
    return section == 0 ? 1 : self.choices.count;
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
        cell.textLabel.text = self.title;
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        cell.detailTextLabel.text = self.message;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessibilityTraits |= UIAccessibilityTraitHeader;
    } else {
        NSDictionary *choice = self.choices[path.row];
        UIColor *color = NSRuleColor(choice[@"rule"]);
        cell.textLabel.text = choice[@"title"];
        cell.textLabel.textColor = color ?: UIColor.systemBlueColor;
        cell.tintColor = color ?: UIColor.systemBlueColor;
        if (color) {
            cell.backgroundColor = [color colorWithAlphaComponent:0.14];
        }
        cell.accessibilityTraits |= UIAccessibilityTraitButton;
        if ([choice[@"rule"] length] && [choice[@"rule"] isEqual:self.selectedRule]) {
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
