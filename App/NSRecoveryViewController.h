#import <UIKit/UIKit.h>

@interface NSRecoveryViewController : UITableViewController <UIDocumentPickerDelegate>
@property(nonatomic, copy) void (^openDashboard)(void);
@end
