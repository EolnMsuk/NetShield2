#import "NSStoreLock.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

@implementation NSStoreLock {
    int _descriptor;
}

- (instancetype)init {
    if ((self = [super init])) {
        _descriptor = -1;
    }
    return self;
}

+ (instancetype)tryLockURL:(NSURL *)url error:(NSError **)error {
    NSStoreLock *lock = [self new];
    lock->_descriptor = open(url.fileSystemRepresentation, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (lock->_descriptor < 0 || flock(lock->_descriptor, LOCK_EX | LOCK_NB) != 0) {
        int code = errno;
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:code
                                     userInfo:@{
                                         NSLocalizedDescriptionKey :
                                             @"Shared state is busy or unavailable. Try again shortly."
                                     }];
        }
        return nil;
    }
    return lock;
}

- (void)unlock {
    if (_descriptor >= 0) {
        close(_descriptor);
        _descriptor = -1;
    }
}
- (void)dealloc {
    [self unlock];
}
@end
