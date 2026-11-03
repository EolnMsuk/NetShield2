#import "NSStoreLock.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
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
    int parent = -1, code = 0;
    if (!url.isFileURL || !url.lastPathComponent.length ||
        ![url.path isEqual:url.URLByStandardizingPath.path]) {
        code = EINVAL;
    }
    if (!code) {
        do {
            parent = open(url.URLByDeletingLastPathComponent.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        } while (parent < 0 && errno == EINTR);
        if (parent < 0) {
            code = errno;
        }
    }
    if (!code) {
        do {
            lock->_descriptor = openat(parent, url.lastPathComponent.fileSystemRepresentation,
                                       O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0600);
        } while (lock->_descriptor < 0 && errno == EINTR);
        if (lock->_descriptor < 0) {
            code = errno;
        }
    }
    struct stat info = {0}, named = {0};
    if (!code && fstat(lock->_descriptor, &info)) {
        code = errno;
    }
    if (!code && (!S_ISREG(info.st_mode) || info.st_nlink != 1)) {
        code = EINVAL;
    }
    if (!code && flock(lock->_descriptor, LOCK_EX | LOCK_NB)) {
        code = errno;
    }
    if (!code &&
        fstatat(parent, url.lastPathComponent.fileSystemRepresentation, &named, AT_SYMLINK_NOFOLLOW)) {
        code = errno;
    }
    if (!code && (info.st_ino != named.st_ino || info.st_dev != named.st_dev)) {
        code = EAGAIN;
    }
    if (!code && fchmod(lock->_descriptor, 0600)) {
        code = errno;
    }
    if (parent >= 0) {
        close(parent);
    }
    if (code) {
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
    int descriptor;
    @synchronized(self) {
        descriptor = _descriptor;
        _descriptor = -1;
    }
    if (descriptor >= 0) {
        close(descriptor);
    }
}
- (void)dealloc {
    [self unlock];
}
@end
