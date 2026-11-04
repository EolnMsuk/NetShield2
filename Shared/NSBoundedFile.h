#import <Foundation/Foundation.h>
#include <sys/stat.h>

// Only the trusted app-group root may resolve aliases. All document and lock
// operations use known leaves relative to this pinned directory.
@interface NSSharedDirectory : NSObject
@property(nonatomic, readonly) NSURL *root;
@property(nonatomic, readonly) int descriptor;
+ (instancetype)openRoot:(NSURL *)root leaf:(NSString *)leaf error:(NSError **)error;
- (BOOL)validateForLeaf:(NSString *)leaf error:(NSError **)error;
@end

FOUNDATION_EXPORT BOOL NSFileFailure(NSString *stage, NSString *leaf, int code, NSError **error);
FOUNDATION_EXPORT BOOL NSFileIsAbsent(NSError *error);
FOUNDATION_EXPORT BOOL NSFileReadChanged(NSError *error);
FOUNDATION_EXPORT BOOL NSIsLockContention(NSError *error);
FOUNDATION_EXPORT BOOL NSKnownDocumentLeaf(NSString *leaf);
FOUNDATION_EXPORT BOOL NSKnownLockLeaf(NSString *leaf);

// Caller owns the returned file descriptor. Keep the directory alive through
// the final identity check, even for a cached read.
FOUNDATION_EXPORT int NSOpenRegularFile(NSSharedDirectory *directory, NSString *leaf, struct stat *info,
                                        NSError **error);
FOUNDATION_EXPORT NSArray *NSDescriptorIdentity(struct stat info);
FOUNDATION_EXPORT BOOL NSCheckReadIdentity(int fd, NSSharedDirectory *directory, NSString *leaf,
                                           struct stat before, NSError **error);
FOUNDATION_EXPORT NSData *NSReadBoundedDescriptor(int fd, NSSharedDirectory *directory, NSString *leaf,
                                                  struct stat before, NSError **error);
FOUNDATION_EXPORT NSData *NSReadBoundedFile(NSSharedDirectory *directory, NSString *leaf, NSError **error);
FOUNDATION_EXPORT BOOL NSWriteBoundedFile(NSData *data, NSSharedDirectory *directory, NSString *leaf,
                                          BOOL durable, NSError **error);
FOUNDATION_EXPORT BOOL NSUnlinkBoundedFile(NSSharedDirectory *directory, NSString *leaf, NSError **error);
