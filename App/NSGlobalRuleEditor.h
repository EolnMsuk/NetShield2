#import <UIKit/UIKit.h>

@interface NSGlobalRuleEditor : UITableViewController
@property(nonatomic, copy) NSArray<NSString *> *identities;
@property(nonatomic, copy) NSString *originalKey;
@property(nonatomic, copy) NSString *originalAction;
@property(nonatomic, copy) BOOL (^saveRule)(NSString *key, NSString *action, NSError **error);
@end
