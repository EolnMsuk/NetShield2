#import <UIKit/UIKit.h>
#import "NSAppDelegate.h"
#import "NSFilterRemoval.h"
#import "NSRecoveryDiagnostics.h"
#import <NetworkExtension/NetworkExtension.h>
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                       const char message[] = "NetShield2: filter removal timed out; uninstall cancelled.\n";
                       write(STDERR_FILENO, message, sizeof(message) - 1);
                       _exit(EXIT_FAILURE);
                   });
    __block BOOL finished = NO;
    __block int status = EXIT_FAILURE;
    NSRemoveInstalledFilter((id<NSFilterRemovalManager>)NEFilterManager.sharedManager, ^(NSError *error) {
        if (error) {
            fprintf(stderr, "NetShield2: filter removal failed: %s (%s %ld).\n",
                    error.localizedDescription.UTF8String, error.domain.UTF8String, (long)error.code);
        } else {
            fprintf(stdout, "NetShield2: verified system filter is removed.\n");
            status = EXIT_SUCCESS;
        }
        finished = YES;
    });
    while (!finished) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    return status;
}

static int NSRecoveryCommand(NSString *operation, BOOL capture) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                       const char message[] = "NetShield2: recovery process timed out; result unverified. "
                                              "The system request may still complete.\n";
                       write(STDERR_FILENO, message, sizeof(message) - 1);
                       _exit(EXIT_FAILURE);
                   });
    __block BOOL finished = NO;
    __block int status = EXIT_FAILURE;
    NSRecoveryPerform(operation, ^(NSDictionary *result) {
        NSError *error = nil;
        BOOL loaded =
            [@[ @"ownershipUnverified", @"foundRecordedConfiguration" ] containsObject:result[@"status"]];
        BOOL captured = capture && loaded && NSRecoveryCaptureEvidence(result[@"before"], &error);
        NSMutableDictionary *report = [NSRecoveryReport() mutableCopy];
        report[@"requestResult"] = result;
        if (capture) {
            report[@"evidenceCaptured"] = @(captured);
            report[@"captureError"] = error.localizedDescription ?: @"";
        }
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:report
                                                                  format:NSPropertyListXMLFormat_v1_0
                                                                 options:0
                                                                   error:&error];
        if (data) {
            fwrite(data.bytes, 1, data.length, stdout);
        }
        BOOL verified = [@[
            @"disabledVerified", @"alreadyDisabledVerified", @"removedVerified", @"foundRecordedConfiguration"
        ] containsObject:result[@"status"]];
        status = data && (capture ? captured : verified) ? EXIT_SUCCESS : EXIT_FAILURE;
        finished = YES;
    });
    while (!finished) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    return status;
}

int main(int argc, char **argv) {
    BOOL uninstall = argc == 2 && strcmp(argv[1], "--remove-filter") == 0;
    BOOL inspect = argc == 2 && strcmp(argv[1], "--recovery-status") == 0;
    BOOL disable = argc == 2 && strcmp(argv[1], "--disable-filter") == 0;
    BOOL remove = argc == 2 && strcmp(argv[1], "--recover-remove-filter") == 0;
    BOOL capture = argc == 2 && strcmp(argv[1], "--capture-recovery-evidence") == 0;
    if ((uninstall || inspect || disable || remove || capture) && !NSUseMobileAccount()) {
        return EXIT_FAILURE;
    }
    @autoreleasepool {
        if (uninstall && !NSRecoveryIsPlainPoC()) {
            return NSUninstallFilter();
        }
        if (inspect || disable || remove || capture || uninstall) {
            return NSRecoveryCommand(disable                 ? @"disable"
                                     : (remove || uninstall) ? @"remove"
                                                             : @"status",
                                     capture);
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(NSAppDelegate.class));
    }
}
