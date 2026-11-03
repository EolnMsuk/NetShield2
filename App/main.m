#import <UIKit/UIKit.h>
#import "NSAppDelegate.h"
#import "NSFilterRemoval.h"
#import "../Shared/NSStore.h"
#import <NetworkExtension/NetworkExtension.h>
#import <UserNotifications/UserNotifications.h>
#include <grp.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static BOOL NSUseMobileAccount(void) {
    struct passwd *account = getpwnam("mobile");
    if (!account) {
        fprintf(stderr, "NetShield2: cannot find the mobile account.\n");
        return NO;
    }
    if (geteuid() == 0 && (initgroups(account->pw_name, account->pw_gid) != 0 ||
                           setgid(account->pw_gid) != 0 || setuid(account->pw_uid) != 0)) {
        perror("NetShield2: cannot switch to the mobile account");
        return NO;
    }
    if (getuid() != account->pw_uid || geteuid() != account->pw_uid) {
        fprintf(stderr, "NetShield2: filter removal must run as mobile.\n");
        return NO;
    }
    if (setenv("HOME", account->pw_dir, 1) || setenv("CFFIXED_USER_HOME", account->pw_dir, 1) ||
        setenv("USER", account->pw_name, 1) || setenv("LOGNAME", account->pw_name, 1)) {
        perror("NetShield2: cannot set the mobile user environment");
        return NO;
    }
    return YES;
}

static int NSUninstallFilter(void) {
    NSTimeInterval operationDeadline = NSProcessInfo.processInfo.systemUptime + 30;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                       const char message[] = "NetShield2: filter removal timed out; uninstall cancelled.\n";
                       write(STDERR_FILENO, message, sizeof(message) - 1);
                       _exit(EXIT_FAILURE);
                   });
    __block BOOL finished = NO;
    __block int status = EXIT_FAILURE;
    NSRemoveInstalledFilterAndSharedState(
        (id<NSFilterRemovalManager>)NEFilterManager.sharedManager, operationDeadline - 1,
        ^{
            [NSUserDefaults.standardUserDefaults
                removePersistentDomainForName:NSBundle.mainBundle.bundleIdentifier];
            [UNUserNotificationCenter.currentNotificationCenter removeAllPendingNotificationRequests];
            [UNUserNotificationCenter.currentNotificationCenter removeAllDeliveredNotifications];
        },
        ^(NSError *error) {
            if (error) {
                const char *stage = [error.userInfo[NSUninstallCleanupPendingKey] boolValue]
                                        ? "saved-state cleanup failed"
                                        : "filter removal failed";
                fprintf(stderr, "NetShield2: %s: %s (%s %ld).\n", stage,
                        error.localizedDescription.UTF8String, error.domain.UTF8String, (long)error.code);
            } else {
                fprintf(stdout, "NetShield2: verified system filter and saved state are removed.\n");
                status = EXIT_SUCCESS;
            }
            finished = YES;
        });
    while (!finished) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    return status;
}

int main(int argc, char **argv) {
    BOOL uninstall = argc == 2 && strcmp(argv[1], "--remove-filter") == 0;
    if (uninstall && !NSUseMobileAccount()) {
        return EXIT_FAILURE;
    }
    @autoreleasepool {
        if (uninstall) {
            return NSUninstallFilter();
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(NSAppDelegate.class));
    }
}
