#import <Foundation/Foundation.h>
#include <sys/stat.h>
// Caller owns the returned descriptor. Opens cannot block on FIFO/device input.
FOUNDATION_EXPORT int NSOpenRegularFile(NSURL *url, struct stat *info, NSError **error);
FOUNDATION_EXPORT NSArray *NSDescriptorIdentity(struct stat info);
FOUNDATION_EXPORT NSData *NSReadBoundedDescriptor(int descriptor, NSURL *url, struct stat before,
                                                  NSError **error);
FOUNDATION_EXPORT NSData *NSReadBoundedFile(NSURL *url, NSError **error);
FOUNDATION_EXPORT BOOL NSWriteBoundedFile(NSData *data, NSURL *url, BOOL durable, NSError **error);

FOUNDATION_EXPORT BOOL NSUnlinkBoundedFile(NSURL *url, NSError **error);
