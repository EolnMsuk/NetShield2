#import "NSPolicyCache.h"
#import "NSConstants.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static NSArray *NSFileIdentity(struct stat info) {
    return @[
        @(info.st_dev), @(info.st_ino), @(info.st_size), @(info.st_mtimespec.tv_sec),
        @(info.st_mtimespec.tv_nsec), @(info.st_ctimespec.tv_sec), @(info.st_ctimespec.tv_nsec)
    ];
}

@implementation NSPolicyCache {
    NSPolicy *_policy;
    NSArray *_identity;
    NSURL *_url;
}

- (void)invalidate {
    @synchronized(self) {
        _policy = nil;
        _identity = nil;
        _url = nil;
    }
}

- (NSPolicy *)readURL:(NSURL *)url error:(NSError **)error {
    @synchronized(self) {
        int descriptor = open(url.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
        int failure = descriptor < 0 ? errno : 0;
        struct stat before = {0};
        if (!failure && fstat(descriptor, &before) != 0) {
            failure = errno;
        }
        if (!failure && (!S_ISREG(before.st_mode) || before.st_size > NSMaximumDocumentBytes)) {
            failure = EFBIG;
        }
        if (!failure && _policy && [_url isEqual:url] && [_identity isEqual:NSFileIdentity(before)]) {
            close(descriptor);
            return _policy;
        }
        [self invalidate];
        NSMutableData *data = [NSMutableData data];
        if (!failure) {
            uint8_t buffer[8192];
            ssize_t count;
            while ((count = read(descriptor, buffer, sizeof(buffer))) != 0) {
                if (count < 0) {
                    if (errno == EINTR) {
                        continue;
                    }
                    failure = errno;
                    break;
                }
                [data appendBytes:buffer length:(NSUInteger)count];
                if (data.length > NSMaximumDocumentBytes) {
                    failure = EFBIG;
                    break;
                }
            }
            struct stat after = {0};
            if (!failure && fstat(descriptor, &after) != 0) {
                failure = errno;
            }
            if (!failure && ![NSFileIdentity(before) isEqual:NSFileIdentity(after)]) {
                failure = EAGAIN;
            }
        }
        if (descriptor >= 0) {
            close(descriptor);
        }
        if (failure) {
            if (error) {
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:failure userInfo:nil];
            }
            return nil;
        }
        id document = [NSPropertyListSerialization propertyListWithData:data
                                                                options:NSPropertyListImmutable
                                                                 format:NULL
                                                                  error:error];
        if (!document) {
            return nil;
        }
        _policy = [NSPolicy policyWithDocument:document error:error];
        if (_policy) {
            _identity = NSFileIdentity(before);
            _url = [url copy];
        }
        return _policy;
    }
}
@end
