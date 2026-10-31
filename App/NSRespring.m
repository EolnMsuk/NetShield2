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
    const char *path =
        strcmp(NS_JAILBREAK_TYPE, "rootless") == 0 ? "/var/jb/usr/bin/sbreload" : "/usr/bin/sbreload";
    if (access(path, X_OK) != 0) {
        int code = errno;
        if (error) {
            *error = NSRespringError([NSString stringWithFormat:@"sbreload is unavailable at %s: %@", path,
                                                                [NSError errorWithDomain:NSPOSIXErrorDomain
                                                                                    code:code
                                                                                userInfo:nil]
                                                                    .localizedDescription],
                                     code);
        }
        return NO;
    }
    char *const arguments[] = {(char *)path, NULL};
    pid_t process = 0;
    int result = posix_spawn(&process, path, NULL, NULL, arguments, environ);
    if (result != 0) {
        if (error) {
            *error = NSRespringError([NSString stringWithFormat:@"Could not launch sbreload: %@",
                                                                [NSError errorWithDomain:NSPOSIXErrorDomain
                                                                                    code:result
                                                                                userInfo:nil]
                                                                    .localizedDescription],
                                     result);
        }
        return NO;
    }
    return YES;
}
