#import "NSPolicyCache.h"
#import "NSConstants.h"
#import "NSBoundedFile.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

@implementation NSPolicyCache {
    NSPolicy *_policy;
    NSArray *_identity;
    NSURL *_url;
    NSError *_invalidError;
    NSTimeInterval _invalidUntil;
}

- (void)invalidate {
    @synchronized(self) {
        _policy = nil;
        _identity = nil;
        _url = nil;
        _invalidError = nil;
    }
}

- (NSPolicy *)readURL:(NSURL *)url error:(NSError **)error {
    @synchronized(self) {
        struct stat before = {0};
        int descriptor = NSOpenRegularFile(url, &before, error);
        if (descriptor < 0) {
            [self invalidate];
            return nil;
        }
        BOOL same = [_url isEqual:url] && [_identity isEqual:NSDescriptorIdentity(before)];
        if (same && (_policy || (_invalidError && NSProcessInfo.processInfo.systemUptime < _invalidUntil))) {
            close(descriptor);
            if (!_policy && error) {
                *error = _invalidError;
            }
            return _policy;
        }
        [self invalidate];
        NSData *data = NSReadBoundedDescriptor(descriptor, url, before, error);
        close(descriptor);
        if (!data) {
            return nil;
        }
        NSError *parseError = nil;
        id document = [NSPropertyListSerialization propertyListWithData:data
                                                                options:NSPropertyListImmutable
                                                                 format:NULL
                                                                  error:&parseError];
        _policy = document ? [NSPolicy policyWithDocument:document error:&parseError] : nil;
        if (_policy) {
            _identity = NSDescriptorIdentity(before);
            _url = [url copy];
        }
        if (!_policy) {
            _identity = NSDescriptorIdentity(before);
            _url = [url copy];
            _invalidError = parseError ?: [NSError errorWithDomain:@"NetShield2.Policy" code:1 userInfo:nil];
            _invalidUntil = NSProcessInfo.processInfo.systemUptime + 1;
            if (error) {
                *error = _invalidError;
            }
        }
        return _policy;
    }
}
@end
