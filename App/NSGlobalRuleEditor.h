#import <UIKit/UIKit.h>

@interface NSGlobalRuleEditor : UITableViewController
@property(nonatomic, copy) NSArray<NSString *> *identities;
@property(nonatomic, copy) NSString *originalKey;
// Initial values for a new rule; never treated as a rule to replace.
@property(nonatomic, copy) NSString *initialKey;
@property(nonatomic, copy) NSString *originalAction;
@property(nonatomic, copy) BOOL (^saveRule)(NSString *key, NSString *action, NSError **error);
@end
