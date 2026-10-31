#import "NSDashboard+Internal.h"
#import "../Shared/NSReleaseVersion.h"

@implementation NSDashboard (Updates)
- (void)checkForUpdateManually:(BOOL)manual {
    self.checkedForUpdateOnLaunch = YES;
    self.updateCheckWasManual |= manual;
    if (manual) {
        self.message = @"Checking for updates...";
        [self refreshTableKeepingPosition];
    }
    if (self.updateTask) {
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest
         requestWithURL:[NSURL
                            URLWithString:@"https://api.github.com/repos/EolnMsuk/NetShield2/releases/latest"]
            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
        timeoutInterval:20];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"NetShield2" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    __weak typeof(self) weakSelf = self;
    self.updateTask = [NSURLSession.sharedSession
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
              NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
              id release = !error && http.statusCode == 200 && data.length && data.length <= 1024 * 1024
                               ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]
                               : nil;
              NSString *latest = NSPublishedReleaseVersion(release);
              NSString *installed =
                  [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
              NSNumber *comparison = NSCompareReleaseVersions(latest, installed);
              dispatch_async(dispatch_get_main_queue(), ^{
                  NSDashboard *owner = weakSelf;
                  if (!owner) {
                      return;
                  }
                  BOOL report = owner.updateCheckWasManual;
                  owner.updateTask = nil;
                  owner.updateCheckWasManual = NO;
                  NSString *title = nil, *message = nil;
                  BOOL newer = comparison && comparison.integerValue == NSOrderedDescending;
                  if (newer) {
                      title = @"Update available";
                      message =
                          [NSString stringWithFormat:@"NetShield2 %@ is available. You have v%@ installed.",
                                                     latest, installed];
                  } else if (report && comparison) {
                      title = @"You're up to date";
                      message =
                          comparison.integerValue == NSOrderedSame
                              ? [NSString
                                    stringWithFormat:@"NetShield2 v%@ is the latest version.", installed]
                              : [NSString
                                    stringWithFormat:@"NetShield2 v%@ is installed, newer than the latest "
                                                     @"published release (%@). No update is needed.",
                                                     installed, latest];
                  } else if (report) {
                      title = @"Unable to check for updates";
                      message = http.statusCode == 403 || http.statusCode == 429
                                    ? @"GitHub is limiting update checks. Please try again later."
                                    : @"Could not verify the latest GitHub release. Check your internet "
                                      @"connection and NetShield2's network rule, then try again.";
                  }
                  if (title) {
                      owner.pendingUpdateResult =
                          @{@"title" : title,
                            @"message" : message,
                            @"newer" : @(newer)};
                  }
                  if (report) {
                      owner.message = message;
                      [owner refreshTableKeepingPosition];
                  }
                  [owner presentPendingUpdateResult];
              });
          }];
    [self.updateTask resume];
}
- (void)presentPendingUpdateResult {
    // Keep permission dialogs and rule editors intact; the monitor timer retries
    // presentation after they close or the app returns to the foreground.
    if (!self.pendingUpdateResult || self.presentedViewController || self.busy || !self.view.window ||
        self.tableView.editing ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        return;
    }
    NSDictionary *result = self.pendingUpdateResult;
    self.pendingUpdateResult = nil;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:result[@"title"]
                                                                   message:result[@"message"]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    if ([result[@"newer"] boolValue]) {
        [alert
            addAction:[UIAlertAction
                          actionWithTitle:@"Open GitHub Release"
                                    style:UIAlertActionStyleDefault
                                  handler:^(UIAlertAction *action) {
                                      [self
                                          openSupportURL:[NSURL URLWithString:@"https://github.com/EolnMsuk/"
                                                                              @"NetShield2/releases/latest"]];
                                  }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
    } else {
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    }
    [self presentViewController:alert animated:YES completion:nil];
}
@end
