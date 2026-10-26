#import <UIKit/UIKit.h>

// Public UIKit controls allow each action to keep its own adaptive text color.
@interface NSRuleActionController : UITableViewController <UIPopoverPresentationControllerDelegate>
@property(nonatomic, copy) NSString *selectedRule;
+ (instancetype)controllerWithTitle:(NSString *)title message:(NSString *)message;
- (void)addActionWithTitle:(NSString *)title rule:(NSString *)rule handler:(void (^)(void))handler;
@end
