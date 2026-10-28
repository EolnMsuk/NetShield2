#import <UIKit/UIKit.h>

// Public UIKit controls allow each action to keep its own adaptive text color.
@interface NSRuleActionController : UITableViewController <UIPopoverPresentationControllerDelegate>
@property(nonatomic, copy) NSString *selectedRule;
@property(nonatomic, copy) NSArray<NSArray<NSString *> *> *detailRows;
@property(nonatomic) BOOL opensExpanded;
@property(nonatomic) BOOL centersActions;
@property(nonatomic) BOOL centersTitle;
@property(nonatomic, copy) NSString *clipboardText;
+ (instancetype)controllerWithTitle:(NSString *)title message:(NSString *)message;
- (void)addActionWithTitle:(NSString *)title rule:(NSString *)rule handler:(void (^)(void))handler;
@end
