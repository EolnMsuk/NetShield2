#import "NSRespring.h"
#include <errno.h>
#include <spawn.h>
#include <string.h>

extern char **environ;

static NSError *NSRespringError(NSArray<NSString *> *attempts, int code) {
    NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
    return [NSError errorWithDomain:@"NetShield2.Respring"
                               code:code
                           userInfo:@{
                               NSLocalizedDescriptionKey : [@"Could not respring. "
                                   stringByAppendingString:[attempts componentsJoinedByString:@"; "]],
                               NSUnderlyingErrorKey : underlying
                           }];
}

static BOOL NSRespringTryPaths(NSArray<NSString *> *paths, int (^launcher)(NSString *), NSError **error) {
    NSMutableArray<NSString *> *attempts = [NSMutableArray new];
    for (NSString *path in paths) {
        // access(X_OK) can be denied separately by the app's sandbox/RootHide
        // policy. Let the actual spawn decide whether this executable can run.
        int result = launcher(path);
        if (result == 0) {
            return YES;
        }
        NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain code:result userInfo:nil];
        [attempts
            addObject:[NSString stringWithFormat:@"Launch %@: %@", path, underlying.localizedDescription]];
        // A missing executable (or parent directory) permits the compatible
        // fallback. A policy/permission denial must remain visible to the user.
        if ((result == ENOENT || result == ENOTDIR) && ![path isEqual:paths.lastObject]) {
            continue;
        }
        if (error) {
            *error = NSRespringError(attempts, result);
        }
        return NO;
    }
    if (error) {
        *error = NSRespringError(@[ @"No sbreload executable paths were configured." ], ENOENT);
    }
    return NO;
}

#ifdef NS_TESTING
BOOL NSRespringUsingLauncher(NSArray<NSString *> *paths, int (^launcher)(NSString *), NSError **error) {
    return NSRespringTryPaths(paths, launcher, error);
}
#endif

BOOL NSRespring(NSError **error) {
    NSString *preferred = @"/usr/bin/sbreload";
    NSString *fallback = nil;
    if (strcmp(NS_JAILBREAK_TYPE, "rootless") == 0) {
        preferred = @"/var/jb/usr/bin/sbreload";
        fallback = @"/usr/bin/sbreload";
    } else if (strcmp(NS_JAILBREAK_TYPE, "roothide") == 0) {
        // Maintainer scripts run inside RootHide's relocated root. The app must
        // resolve that same root from its installed bundle, not the stock /usr.
        NSString *bundle = NSBundle.mainBundle.bundlePath.stringByResolvingSymlinksInPath;
        if ([bundle hasSuffix:@"/Applications/NetShield2.app"]) {
            NSString *root = bundle.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
            preferred = [root stringByAppendingPathComponent:@"usr/bin/sbreload"];
        }
        fallback = @"/usr/bin/sbreload";
    }
    NSArray<NSString *> *paths =
        fallback && ![fallback isEqual:preferred] ? @[ preferred, fallback ] : @[ preferred ];
    return NSRespringTryPaths(
        paths,
        ^int(NSString *path) {
            const char *executable = path.fileSystemRepresentation;
            char *const arguments[] = {(char *)executable, NULL};
            pid_t process = 0;
            return posix_spawn(&process, executable, NULL, NULL, arguments, environ);
        },
        error);
}
