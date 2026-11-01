#import "NSRespring.h"
#include <errno.h>
#include <spawn.h>
#include <string.h>
#include <unistd.h>

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
    NSMutableArray<NSString *> *attempts = [NSMutableArray new];
    for (NSString *path in paths) {
        if (access(path.fileSystemRepresentation, X_OK) != 0) {
            int code = errno;
            NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
            [attempts addObject:[NSString stringWithFormat:@"Access %@: %@", path,
                                                           underlying.localizedDescription]];
            // Fall back only for an absent path, never for a present but
            // inaccessible executable.
            if ((code == ENOENT || code == ENOTDIR) && ![path isEqual:paths.lastObject]) {
                continue;
            }
            if (error) {
                *error = NSRespringError(attempts, code);
            }
            return NO;
        }
        const char *executable = path.fileSystemRepresentation;
        char *const arguments[] = {(char *)executable, NULL};
        pid_t process = 0;
        int result = posix_spawn(&process, executable, NULL, NULL, arguments, environ);
        if (result != 0) {
            NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain code:result userInfo:nil];
            [attempts addObject:[NSString stringWithFormat:@"Launch %@: %@", path,
                                                           underlying.localizedDescription]];
            if (error) {
                *error = NSRespringError(attempts, result);
            }
            return NO;
        }
        return YES;
    }
    return NO;
}
