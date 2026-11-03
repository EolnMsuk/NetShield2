#import "NSBoundedFile.h"
#import "NSConstants.h"
#import <TargetConditionals.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

static BOOL NSFileFailure(int code, NSError **error) {
    if (error) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
    }
    return NO;
}
static int NSOpenParent(NSURL *url, NSError **error) {
    if (!url.isFileURL || !url.lastPathComponent.length ||
        ![url.path isEqual:url.URLByStandardizingPath.path]) {
        NSFileFailure(EINVAL, error);
        return -1;
    }
    int fd;
    do {
        fd = open(url.URLByDeletingLastPathComponent.fileSystemRepresentation,
                  O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    } while (fd < 0 && errno == EINTR);
    if (fd < 0) {
        NSFileFailure(errno, error);
    }
    return fd;
}
NSArray *NSDescriptorIdentity(struct stat info) {
    return @[
        @(info.st_dev), @(info.st_ino), @(info.st_size), @(info.st_mtimespec.tv_sec),
        @(info.st_mtimespec.tv_nsec), @(info.st_ctimespec.tv_sec), @(info.st_ctimespec.tv_nsec)
    ];
}
int NSOpenRegularFile(NSURL *url, struct stat *info, NSError **error) {
    int parent = NSOpenParent(url, error);
    if (parent < 0) {
        return -1;
    }
    int fd;
    do {
        fd = openat(parent, url.lastPathComponent.fileSystemRepresentation,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    } while (fd < 0 && errno == EINTR);
    int failure = fd < 0 ? errno : 0;
    close(parent);
    struct stat before = {0};
    if (!failure && fstat(fd, &before)) {
        failure = errno;
    }
    if (!failure && (!S_ISREG(before.st_mode) || before.st_size < 0)) {
        failure = EINVAL;
    }
    if (!failure && before.st_size > NSMaximumDocumentBytes) {
        failure = EFBIG;
    }
    if (failure) {
        if (fd >= 0) {
            close(fd);
        }
        NSFileFailure(failure, error);
        return -1;
    }
    if (info) {
        *info = before;
    }
    return fd;
}
NSData *NSReadBoundedDescriptor(int fd, NSURL *url, struct stat before, NSError **error) {
    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[8192];
    for (;;) {
        // Read at most one byte beyond the cap, without appending that byte.
        size_t limit = MIN(sizeof(buffer), NSMaximumDocumentBytes - data.length + 1);
        ssize_t count = read(fd, buffer, limit);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count < 0) {
            NSFileFailure(errno, error);
            return nil;
        }
        if (!count) {
            break;
        }
        if ((NSUInteger)count > NSMaximumDocumentBytes - data.length) {
            NSFileFailure(EFBIG, error);
            return nil;
        }
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    struct stat after = {0}, named = {0};
    if (fstat(fd, &after) || lstat(url.fileSystemRepresentation, &named)) {
        NSFileFailure(errno, error);
        return nil;
    }
    NSArray *identity = NSDescriptorIdentity(before);
    if (![identity isEqual:NSDescriptorIdentity(after)] || ![identity isEqual:NSDescriptorIdentity(named)] ||
        data.length != (NSUInteger)after.st_size) {
        NSFileFailure(EAGAIN, error);
        return nil;
    }
    return [data copy];
}
NSData *NSReadBoundedFile(NSURL *url, NSError **error) {
    struct stat info = {0};
    int fd = NSOpenRegularFile(url, &info, error);
    if (fd < 0) {
        return nil;
    }
    NSData *data = NSReadBoundedDescriptor(fd, url, info, error);
    close(fd);
    return data;
}
BOOL NSWriteBoundedFile(NSData *data, NSURL *url, BOOL durable, NSError **error) {
    if (data.length > NSMaximumDocumentBytes) {
        return NSFileFailure(EFBIG, error);
    }
    int parent = NSOpenParent(url, error);
    if (parent < 0) {
        return NO;
    }
    NSString *temporary = [@".netshield-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd = openat(parent, temporary.fileSystemRepresentation,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    int failure = fd < 0 ? errno : 0;
    if (!failure && fchmod(fd, 0600)) {
        failure = errno;
    }
    size_t offset = 0;
    while (!failure && offset < data.length) {
        ssize_t count = write(fd, (const uint8_t *)data.bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            failure = count < 0 ? errno : EIO;
            break;
        }
        offset += (size_t)count;
    }
#if TARGET_OS_IPHONE
    // Preserve deployed pre-unlock behavior. Changing activity protection needs
    // the device startup/share evidence described in the hardening plan.
    if (!failure) {
        NSURL *temporaryURL = [url.URLByDeletingLastPathComponent URLByAppendingPathComponent:temporary];
        NSError *protectionError = nil;
        if (![NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey : NSFileProtectionNone}
                                            ofItemAtPath:temporaryURL.path
                                                   error:&protectionError]) {
            if (error) {
                *error = protectionError;
            }
            failure = EACCES;
        }
    }
#endif
    struct stat written = {0}, named = {0};
    if (!failure && (fstat(fd, &written) ||
                     fstatat(parent, temporary.fileSystemRepresentation, &named, AT_SYMLINK_NOFOLLOW))) {
        failure = errno;
    }
    if (!failure && (!S_ISREG(written.st_mode) || (written.st_mode & 0777) != 0600 || written.st_nlink != 1 ||
                     written.st_ino != named.st_ino || written.st_dev != named.st_dev)) {
        failure = EAGAIN;
    }
    if (!failure && durable && fsync(fd)) {
        failure = errno;
    }
    if (fd >= 0 && close(fd) && !failure) {
        failure = errno;
    }
    if (!failure && renameat(parent, temporary.fileSystemRepresentation, parent,
                             url.lastPathComponent.fileSystemRepresentation)) {
        failure = errno;
    }
    if (failure) {
        unlinkat(parent, temporary.fileSystemRepresentation, 0);
    }
    close(parent);
    return failure ? NSFileFailure(failure, error) : YES;
}

BOOL NSUnlinkBoundedFile(NSURL *url, NSError **error) {
    int parent = NSOpenParent(url, error);
    if (parent < 0) {
        return NO;
    }
    int result = unlinkat(parent, url.lastPathComponent.fileSystemRepresentation, 0);
    int code = result ? errno : 0;
    close(parent);
    return code == 0 || code == ENOENT ? YES : NSFileFailure(code, error);
}
