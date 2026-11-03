#import "NSDashboard+Internal.h"
#import "../Shared/NSReleaseVersion.h"

@implementation NSDashboard (Updates)
- (NSString *)updateCheckSubtitle {
    NSString *mode = NSUpdateCheckMode(NSUserDefaults.standardUserDefaults);
    if ([mode isEqual:NSUpdateCheckEveryLaunch]) {
        return @"Checks GitHub stable releases on every launch";
    }
    if ([mode isEqual:NSUpdateCheckOff]) {
        return @"Automatic stable-release checks are off";
    }
    return @"Checks GitHub stable releases daily on launch";
}
- (void)setUpdateCheckMode:(NSString *)mode {
    if ([mode isEqual:NSUpdateCheckOff]) {
        [self cancelUpdateCheck];
    }
    [NSUserDefaults.standardUserDefaults setObject:mode forKey:NSUpdateCheckModeKey];
    [self refreshTableKeepingPosition];
}
- (void)presentUpdateOptions {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Check for Updates"
                                                                   message:[self updateCheckSubtitle]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Check Now"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                                [self checkForUpdateManually:YES];
                                            }]];
    NSArray<NSArray<NSString *> *> *modes = @[
        @[ @"Check at Launch", NSUpdateCheckEveryLaunch ], @[ @"Check Daily", NSUpdateCheckDaily ],
        @[ @"Disable Updates", NSUpdateCheckOff ]
    ];
    NSString *mode = NSUpdateCheckMode(NSUserDefaults.standardUserDefaults);
    for (NSArray<NSString *> *choice in modes) {
        NSString *title = [choice[1] isEqual:mode] ? [choice[0] stringByAppendingString:@" ✓"] : choice[0];
        UIAlertActionStyle style =
            [choice[1] isEqual:NSUpdateCheckOff] ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault;
        [alert addAction:[UIAlertAction actionWithTitle:title
                                                  style:style
                                                handler:^(UIAlertAction *action) {
                                                    [self setUpdateCheckMode:choice[1]];
                                                }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)cancelUpdateCheck {
    self.updateGeneration++;
    [self.updateTask cancel];
    self.updateTask = nil;
    self.updateCheckWasManual = NO;
    self.pendingUpdateResult = nil;
}
- (void)checkForUpdateManually:(BOOL)manual {
    if (self.updateTask) {
        self.updateCheckWasManual |= manual;
        return;
    }
    NSDate *now = NSDate.date;
    if (!manual && !NSAutomaticUpdateCheckDue(NSUserDefaults.standardUserDefaults, now)) {
        return;
    }
    // Record before the request so failures and repeated launches cannot bypass
    // the rolling daily automatic-check limit.
    [NSUserDefaults.standardUserDefaults setObject:now forKey:NSUpdateCheckLastAttemptKey];
    self.updateCheckWasManual |= manual;
    if (manual) {
        self.message = @"Checking for stable releases...";
        [self refreshTableKeepingPosition];
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
    NSUInteger generation = ++self.updateGeneration;
    self.updateTask = [[NSReleaseFetch alloc]
        initWithRequest:request
             completion:^(NSData *data, NSURLResponse *response, NSError *error) {
                 NSHTTPURLResponse *http =
                     [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
                 id release = !error && http.statusCode == 200 && data.length && data.length <= 1024 * 1024
                                  ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]
                                  : nil;
                 NSString *latest = NSPublishedReleaseVersion(release);
                 NSString *installed =
                     [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
                 NSNumber *comparison = NSCompareReleaseVersions(latest, installed);
                 dispatch_async(dispatch_get_main_queue(), ^{
                     NSDashboard *owner = weakSelf;
                     if (!owner || owner.updateGeneration != generation) {
                         return;
                     }
                     BOOL report = owner.updateCheckWasManual;
                     owner.updateTask = nil;
                     owner.updateCheckWasManual = NO;
                     NSString *title = nil, *message = nil;
                     BOOL newer = comparison && comparison.integerValue == NSOrderedDescending;
                     if (newer) {
                         title = @"Update available";
                         NSString *version = [latest
                             stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                         if ([version hasPrefix:@"v"] || [version hasPrefix:@"V"]) {
                             version = [version substringFromIndex:1];
                         }
                         message =
                             [NSString stringWithFormat:
                                           @"NetShield2 v%@ is available!\n\n"
                                           @"After downloading the update, turn off Firewall and uninstall "
                                           @"this version before installing the new one. Uninstall removes "
                                           @"saved rules and history; export them first.",
                                           version];
                     } else if (report && comparison) {
                         title = @"Release check complete";
                         message =
                             comparison.integerValue == NSOrderedSame
                                 ? [NSString
                                       stringWithFormat:@"NetShield2 v%@ matches the latest stable release.",
                                                        installed]
                                 : [NSString
                                       stringWithFormat:@"NetShield2 v%@ is installed, newer than the latest "
                                                        @"stable release (%@).",
                                                        installed, latest];
                     } else if (report) {
                         title = @"Unable to check stable releases";
                         message =
                             http.statusCode == 403 || http.statusCode == 429
                                 ? @"GitHub is limiting update checks. Please try again later."
                                 : @"Could not verify the latest GitHub stable release. Check your internet "
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
