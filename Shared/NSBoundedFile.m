#import "NSBoundedFile.h"
#import "NSConstants.h"
#import <TargetConditionals.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

static NSString *const NSAbsentStage = @"Find document";
static NSString *const NSReadChangedStage = @"Document changed while reading";
BOOL NSFileFailure(NSString *stage, NSString *leaf, int code, NSError **error) {
    if (error) {
        NSError *cause = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
        *error =
            [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:code
                            userInfo:@{
                                NSLocalizedDescriptionKey : [NSString
                                    stringWithFormat:@"%@ (%@): %@", stage, leaf, cause.localizedDescription],
                                NSUnderlyingErrorKey : cause,
                                @"stage" : stage
                            }];
    }
    return NO;
}
BOOL NSFileIsAbsent(NSError *error) {
    return [error.domain isEqual:NSPOSIXErrorDomain] && error.code == ENOENT &&
           [error.userInfo[@"stage"] isEqual:NSAbsentStage];
}
BOOL NSFileReadChanged(NSError *error) {
    return [error.domain isEqual:NSPOSIXErrorDomain] && [error.userInfo[@"stage"] isEqual:NSReadChangedStage];
}
BOOL NSIsLockContention(NSError *error) {
    return [error.domain isEqual:NSPOSIXErrorDomain] &&
           (error.code == EWOULDBLOCK || error.code == EAGAIN || error.code == EBUSY);
}

static BOOL NSContainsNUL(NSString *value) {
    const unichar nul = 0;
    return [value rangeOfString:[NSString stringWithCharacters:&nul length:1] options:NSLiteralSearch]
               .location != NSNotFound;
}
static BOOL NSPlainLeaf(NSString *leaf) {
    return leaf.length && ![leaf isEqual:@"."] && ![leaf isEqual:@".."] && !NSContainsNUL(leaf) &&
           [leaf rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\"]]
                   .location == NSNotFound;
}
BOOL NSKnownDocumentLeaf(NSString *leaf) {
    return NSPlainLeaf(leaf) && [@[
               NSPolicyFile, NSMonitorFile, NSActivityClearFile, NSNotificationRetryFile,
               NSPendingConfigurationFile, NSConfigurationRecoveryFile
           ] containsObject:leaf];
}
BOOL NSKnownLockLeaf(NSString *leaf) {
    return NSPlainLeaf(leaf) &&
           [@[ NSConfigurationLockFile, @"provider.lock", @"policy.lock", @"activity.lock", @"exports.lock" ]
               containsObject:leaf];
}

@implementation NSSharedDirectory {
    struct stat _identity;
}
- (instancetype)init {
    if ((self = [super init])) {
        _descriptor = -1;
    }
    return self;
}
+ (instancetype)openRoot:(NSURL *)root leaf:(NSString *)leaf error:(NSError **)error {
    NSString *path = root.path;
    if (!root.isFileURL || (root.host.length && ![root.host.lowercaseString isEqual:@"localhost"]) ||
        !path.isAbsolutePath || NSContainsNUL(path)) {
        NSFileFailure(@"Resolve shared container", leaf, root ? EINVAL : ENOENT, error);
        return nil;
    }
    struct stat before;
    if (stat(root.fileSystemRepresentation, &before)) {
        NSFileFailure(@"Find shared container", leaf, errno, error);
        return nil;
    }
    NSSharedDirectory *directory = [self new];
    directory->_root = [root copy];
    do {
        directory->_descriptor = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    } while (directory->_descriptor < 0 && errno == EINTR);
    if (directory->_descriptor < 0 || fstat(directory->_descriptor, &directory->_identity)) {
        NSFileFailure(@"Open shared container", leaf, errno, error);
        return nil;
    }
    if (before.st_dev != directory->_identity.st_dev || before.st_ino != directory->_identity.st_ino) {
        NSFileFailure(@"Shared container changed", leaf, ESTALE, error);
        return nil;
    }
    return [directory validateForLeaf:leaf error:error] ? directory : nil;
}
- (BOOL)validateForLeaf:(NSString *)leaf error:(NSError **)error {
    struct stat named;
    if (stat(self.root.fileSystemRepresentation, &named)) {
        return NSFileFailure(@"Recheck shared container", leaf, errno, error);
    }
    if (!S_ISDIR(named.st_mode) || named.st_dev != _identity.st_dev || named.st_ino != _identity.st_ino) {
        return NSFileFailure(@"Shared container changed", leaf, ESTALE, error);
    }
    return YES;
}
- (void)dealloc {
    if (_descriptor >= 0) {
        close(_descriptor);
    }
}
@end

NSArray *NSDescriptorIdentity(struct stat info) {
    return @[
        @(info.st_dev), @(info.st_ino), @(info.st_size), @(info.st_mtimespec.tv_sec),
        @(info.st_mtimespec.tv_nsec), @(info.st_ctimespec.tv_sec), @(info.st_ctimespec.tv_nsec)
    ];
}
int NSOpenRegularFile(NSSharedDirectory *directory, NSString *leaf, struct stat *info, NSError **error) {
    if (!NSKnownDocumentLeaf(leaf)) {
        NSFileFailure(@"Validate document name", @"unknown document", EINVAL, error);
        return -1;
    }
    if (![directory validateForLeaf:leaf error:error]) {
        return -1;
    }
    int fd;
    do {
        fd = openat(directory.descriptor, leaf.fileSystemRepresentation,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    } while (fd < 0 && errno == EINTR);
    if (fd < 0) {
        int code = errno;
        if ([directory validateForLeaf:leaf error:error]) {
            NSFileFailure(code == ENOENT ? NSAbsentStage : @"Open document", leaf, code, error);
        }
        return -1;
    }
    NSString *stage = @"Stat document";
    struct stat before;
    int failure = fstat(fd, &before) ? errno : 0;
    if (!failure && (!S_ISREG(before.st_mode) || before.st_size < 0)) {
        failure = EINVAL;
        stage = @"Validate document type";
    }
    if (!failure && before.st_size > NSMaximumDocumentBytes) {
        failure = EFBIG;
        stage = @"Check document size";
    }
    if (failure) {
        close(fd);
        NSFileFailure(stage, leaf, failure, error);
        return -1;
    }
    *info = before;
    return fd;
}
BOOL NSCheckReadIdentity(int fd, NSSharedDirectory *directory, NSString *leaf, struct stat before,
                         NSError **error) {
    struct stat after, named;
    if (fstat(fd, &after)) {
        return NSFileFailure(@"Recheck open document", leaf, errno, error);
    }
    if (fstatat(directory.descriptor, leaf.fileSystemRepresentation, &named, AT_SYMLINK_NOFOLLOW)) {
        int code = errno;
        return NSFileFailure(code == ENOENT ? NSReadChangedStage : @"Recheck named document", leaf, code,
                             error);
    }
    NSArray *identity = NSDescriptorIdentity(before);
    if (![identity isEqual:NSDescriptorIdentity(after)] || ![identity isEqual:NSDescriptorIdentity(named)]) {
        return NSFileFailure(NSReadChangedStage, leaf, ESTALE, error);
    }
    return [directory validateForLeaf:leaf error:error];
}
NSData *NSReadBoundedDescriptor(int fd, NSSharedDirectory *directory, NSString *leaf, struct stat before,
                                NSError **error) {
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
            NSFileFailure(@"Read document", leaf, errno, error);
            return nil;
        }
        if (!count) {
            break;
        }
        if ((NSUInteger)count > NSMaximumDocumentBytes - data.length) {
            NSFileFailure(@"Bound document read", leaf, EFBIG, error);
            return nil;
        }
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    if (!NSCheckReadIdentity(fd, directory, leaf, before, error)) {
        return nil;
    }
    if (data.length != (NSUInteger)before.st_size) {
        NSFileFailure(NSReadChangedStage, leaf, ESTALE, error);
        return nil;
    }
    return [data copy];
}
NSData *NSReadBoundedFile(NSSharedDirectory *directory, NSString *leaf, NSError **error) {
    struct stat info;
    int fd = NSOpenRegularFile(directory, leaf, &info, error);
    if (fd < 0) {
        return nil;
    }
    NSData *data = NSReadBoundedDescriptor(fd, directory, leaf, info, error);
    close(fd);
    return data;
}

static BOOL NSCheckDocumentTarget(int parent, NSString *leaf, NSError **error) {
    struct stat named;
    if (fstatat(parent, leaf.fileSystemRepresentation, &named, AT_SYMLINK_NOFOLLOW)) {
        int code = errno;
        return code == ENOENT || NSFileFailure(@"Inspect document target", leaf, code, error);
    }
    return S_ISREG(named.st_mode) ||
           NSFileFailure(@"Validate document target", leaf, S_ISLNK(named.st_mode) ? ELOOP : EINVAL, error);
}
BOOL NSWriteBoundedFile(NSData *data, NSSharedDirectory *directory, NSString *leaf, BOOL durable,
                        NSError **error) {
    if (!NSKnownDocumentLeaf(leaf)) {
        return NSFileFailure(@"Validate document name", @"unknown document", EINVAL, error);
    }
    if (data.length > NSMaximumDocumentBytes) {
        return NSFileFailure(@"Bound document write", leaf, EFBIG, error);
    }
    int parent = directory.descriptor;
    if (![directory validateForLeaf:leaf error:error] || !NSCheckDocumentTarget(parent, leaf, error)) {
        return NO;
    }
    NSString *temporary = [@".netshield-" stringByAppendingString:NSUUID.UUID.UUIDString];
    const char *tempName = temporary.fileSystemRepresentation;
    int fd;
    do {
        fd = openat(parent, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    } while (fd < 0 && errno == EINTR);
    if (fd < 0) {
        return NSFileFailure(@"Create temporary document", leaf, errno, error);
    }
    BOOL published = NO;
    @try {
        if (fchmod(fd, 0600)) {
            return NSFileFailure(@"Set document mode", leaf, errno, error);
        }
        size_t offset = 0;
        while (offset < data.length) {
            ssize_t count = write(fd, (const uint8_t *)data.bytes + offset, data.length - offset);
            if (count < 0 && errno == EINTR) {
                continue;
            }
            if (count <= 0) {
                return NSFileFailure(@"Write document", leaf, count < 0 ? errno : EIO, error);
            }
            offset += (size_t)count;
        }
#if TARGET_OS_IPHONE
        if (![directory validateForLeaf:leaf error:error]) {
            return NO;
        }
        // Keep deployed pre-unlock behavior.
        NSURL *temporaryURL = [directory.root URLByAppendingPathComponent:temporary];
        NSError *protectionError = nil;
        if (![NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey : NSFileProtectionNone}
                                            ofItemAtPath:temporaryURL.path
                                                   error:&protectionError]) {
            if (error) {
                *error = [NSError errorWithDomain:protectionError.domain
                                             code:protectionError.code
                                         userInfo:@{
                                             NSLocalizedDescriptionKey : [NSString
                                                 stringWithFormat:@"Set file protection (%@)", leaf],
                                             NSUnderlyingErrorKey : protectionError
                                         }];
            }
            return NO;
        }
#endif
        if (durable) {
            int result;
            do {
                result = fsync(fd);
            } while (result && errno == EINTR);
            if (result) {
                return NSFileFailure(@"Sync document", leaf, errno, error);
            }
        }
        struct stat written, named;
        if (fstat(fd, &written) || fstatat(parent, tempName, &named, AT_SYMLINK_NOFOLLOW)) {
            return NSFileFailure(@"Inspect temporary document", leaf, errno, error);
        }
        if (!S_ISREG(written.st_mode) || (written.st_mode & 0777) != 0600 || written.st_nlink != 1 ||
            written.st_ino != named.st_ino || written.st_dev != named.st_dev) {
            return NSFileFailure(@"Temporary document changed", leaf, ESTALE, error);
        }
        if (![directory validateForLeaf:leaf error:error] || !NSCheckDocumentTarget(parent, leaf, error)) {
            return NO;
        }
        int closeResult = close(fd);
        fd = -1;
        if (closeResult) {
            return NSFileFailure(@"Close temporary document", leaf, errno, error);
        }
        if (renameat(parent, tempName, parent, leaf.fileSystemRepresentation)) {
            return NSFileFailure(@"Publish document", leaf, errno, error);
        }
        published = YES;
        return [directory validateForLeaf:leaf error:error];
    } @finally {
        if (fd >= 0) {
            close(fd);
        }
        if (!published) {
            unlinkat(parent, tempName, 0);
        }
    }
}
BOOL NSUnlinkBoundedFile(NSSharedDirectory *directory, NSString *leaf, NSError **error) {
    if (!NSKnownDocumentLeaf(leaf)) {
        return NSFileFailure(@"Validate document name", @"unknown document", EINVAL, error);
    }
    if (![directory validateForLeaf:leaf error:error] ||
        !NSCheckDocumentTarget(directory.descriptor, leaf, error)) {
        return NO;
    }
    if (unlinkat(directory.descriptor, leaf.fileSystemRepresentation, 0) && errno != ENOENT) {
        return NSFileFailure(@"Remove document", leaf, errno, error);
    }
    return [directory validateForLeaf:leaf error:error];
}
