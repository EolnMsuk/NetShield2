#import "NSRespring.h"
#include <errno.h>
#include <spawn.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

static NSError *NSRespringError(NSString *message, NSInteger code) {
    return [NSError errorWithDomain:@"NetShield2.Respring"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

BOOL NSRespring(NSError **error) {
    // RootHide packages are relocated during staging, so their native tool path
    // matches rootful. Keep its choice explicit: grouping it with rootful hid the
    // fact that RootHide needs its own supported layout.
    const char *preferred = strcmp(NS_JAILBREAK_TYPE, "rootless") == 0
                                ? "/var/jb/usr/bin/sbreload"
                                : strcmp(NS_JAILBREAK_TYPE, "roothide") == 0
                                      ? "/usr/bin/sbreload"
                                      : "/usr/bin/sbreload";
    const char *fallback = strcmp(NS_JAILBREAK_TYPE, "rootless") == 0
                               ? "/usr/bin/sbreload"
                               : "/var/jb/usr/bin/sbreload";
    const char *path = preferred;
    int preferredError = 0;
    if (access(path, X_OK) != 0) {
        preferredError = errno;
        if (access(fallback, X_OK) == 0) {
            path = fallback;
        } else {
            int fallbackError = errno;
            if (error) {
                *error = NSRespringError(
                    [NSString stringWithFormat:@"sbreload is unavailable (tried %s: %@; %s: %@).", preferred,
                                               [NSError errorWithDomain:NSPOSIXErrorDomain
                                                                   code:preferredError
                                                               userInfo:nil].localizedDescription,
                                               fallback,
                                               [NSError errorWithDomain:NSPOSIXErrorDomain
                                                                   code:fallbackError
                                                               userInfo:nil].localizedDescription],
                    fallbackError);
            }
            return NO;
        }
    }
    char *const arguments[] = {(char *)path, NULL};
    pid_t process = 0;
    int result = posix_spawn(&process, path, NULL, NULL, arguments, environ);
    if (result != 0) {
        if (error) {
            *error = NSRespringError(
                [NSString stringWithFormat:@"Could not launch sbreload at %s (preferred %s): %@", path, preferred,
                                           [NSError errorWithDomain:NSPOSIXErrorDomain code:result userInfo:nil]
                                               .localizedDescription],
                result);
        }
        return NO;
    }
    return YES;
}
