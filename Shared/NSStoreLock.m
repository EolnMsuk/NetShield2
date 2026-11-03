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

+ (instancetype)tryLockRoot:(NSURL *)root leaf:(NSString *)leaf error:(NSError **)error {
    if (!NSKnownLockLeaf(leaf)) {
        NSFileFailure(@"Validate lock name", @"unknown lock", EINVAL, error);
        return nil;
    }
    NSSharedDirectory *directory = [NSSharedDirectory openRoot:root leaf:leaf error:error];
    return directory ? [self tryLockInDirectory:directory leaf:leaf error:error] : nil;
}
+ (instancetype)tryLockInDirectory:(NSSharedDirectory *)directory
                              leaf:(NSString *)leaf
                             error:(NSError **)error {
    if (!NSKnownLockLeaf(leaf)) {
        NSFileFailure(@"Validate lock name", @"unknown lock", EINVAL, error);
        return nil;
    }
    if (![directory validateForLeaf:leaf error:error]) {
        return nil;
    }
    NSStoreLock *lock = [self new];
    lock->_directory = directory;
    int parent = directory.descriptor;
    const char *name = leaf.fileSystemRepresentation;
    do {
        lock->_descriptor =
            openat(parent, name, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0600);
    } while (lock->_descriptor < 0 && errno == EINTR);
    if (lock->_descriptor < 0) {
        NSFileFailure(@"Open lock", leaf, errno, error);
        return nil;
    }
    struct stat info, named;
    if (fstat(lock->_descriptor, &info)) {
        NSFileFailure(@"Stat lock", leaf, errno, error);
        return nil;
    }
    if (!S_ISREG(info.st_mode) || info.st_nlink != 1) {
        NSFileFailure(@"Validate lock type and link count", leaf, EINVAL, error);
        return nil;
    }
    int result;
    do {
        result = flock(lock->_descriptor, LOCK_EX | LOCK_NB);
    } while (result && errno == EINTR);
    if (result) {
        NSFileFailure(@"Acquire lock", leaf, errno, error);
        return nil;
    }
    if (fchmod(lock->_descriptor, 0600)) {
        NSFileFailure(@"Set lock mode", leaf, errno, error);
        return nil;
    }
    if (fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW)) {
        NSFileFailure(@"Recheck lock", leaf, errno, error);
        return nil;
    }
    if (info.st_ino != named.st_ino || info.st_dev != named.st_dev || named.st_nlink != 1) {
        NSFileFailure(@"Lock file changed", leaf, ESTALE, error);
        return nil;
    }
    return [directory validateForLeaf:leaf error:error] ? lock : nil;
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
