#import <UIKit/UIKit.h>

@interface NSDashboard : UITableViewController
- (void)reloadMonitor;
- (void)trackOneTimePermissionRequest:(NSDictionary *)request action:(NSString *)action;
@end
