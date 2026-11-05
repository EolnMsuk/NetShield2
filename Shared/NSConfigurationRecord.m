#import "NSConfigurationRecord.h"
#import "NSConstants.h"
#import "NSValidation.h"
#include <errno.h>

static NSString *NSRecordUUID(id value) {
    return NSBoundedString(value, 36, YES) ? [[NSUUID alloc] initWithUUIDString:value].UUIDString : nil;
}
NSDictionary *NSDecodeConfigurationRecord(NSData *data) {
    if (!data || data.length > 8192) {
        return nil;
    }
    id value = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListImmutable
                                                          format:NULL
                                                           error:NULL];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
BOOL NSConfigurationRecordValid(NSDictionary *record) {
    if (!NSRecordUUID(record[@"operation"]) || !NSUnsignedInteger(record[@"phase"], NSUIntegerMax) ||
        ![record[@"phase"] unsignedIntegerValue]) {
        return NO;
    }
    id version = record[@"version"];
    if (!version) {
        return YES; // Preserve legacy boot/witness recovery, including bootless records.
    }
    if (!NSUnsignedInteger(version, 3) || [version unsignedIntegerValue] < 1) {
        return NO;
    }
    BOOL v3 = [version isEqual:@3];
    BOOL reserved = v3 && [record[@"state"] isEqual:@"reserved"];
    BOOL save = [record[@"kind"] isEqual:@"save"];
    BOOL kind =
        save || [record[@"kind"] isEqual:@"remove"] || (reserved && [record[@"kind"] isEqual:@"transaction"]);
    BOOL receipt = !record[@"receipt"] || (save && NSRecordUUID(record[@"receipt"]));
    return kind && receipt && (![version isEqual:@2] || (save && NSRecordUUID(record[@"receipt"]))) &&
           (reserved || [record[@"state"] isEqual:@"pending"] ||
            [record[@"state"] isEqual:@"acknowledged"]) &&
           ((NSRecordUUID(record[@"boot"]) && [record[@"bootState"] isEqual:@"known"]) ||
            (!record[@"boot"] && [record[@"bootState"] isEqual:@"unavailable"]));
}
BOOL NSConfigurationSameDirectory(NSSharedDirectory *a, NSSharedDirectory *b) {
    struct stat first, second;
    return a && b && !fstat(a.descriptor, &first) && !fstat(b.descriptor, &second) &&
           first.st_dev == second.st_dev && first.st_ino == second.st_ino;
}
BOOL NSConfigurationAdmission(NSSharedDirectory *directory, NSDictionary *expected, NSError **error) {
    NSError *readError = nil;
    NSData *bytes = NSReadBoundedFile(directory, NSPendingConfigurationFile, &readError);
    if (!bytes && NSFileIsAbsent(readError) && !expected) {
        return YES;
    }
    NSDictionary *record = NSDecodeConfigurationRecord(bytes);
    if (expected && NSConfigurationRecordValid(record) && [record isEqual:expected] &&
        [record[@"version"] isEqual:@3] && [record[@"state"] isEqual:@"reserved"]) {
        return YES;
    }
    if (error) {
        NSString *detail = expected ? @"Configuration ownership changed. Refresh and retry explicitly."
                                    : @"A configuration reservation or pending write owns saved state. Retry "
                                      @"after setup or removal finishes.";
        if (bytes && !NSConfigurationRecordValid(record)) {
            detail = @"The configuration record is invalid or unsupported. Check shared storage and Content "
                     @"Filter in Settings.";
        }
        *error = readError && !NSFileIsAbsent(readError)
                     ? readError
                     : [NSError errorWithDomain:@"NetShield2.Configuration"
                                           code:expected ? ESTALE : EBUSY
                                       userInfo:@{NSLocalizedDescriptionKey : detail}];
    }
    return NO;
}

static id<NSConfigurationExecution> (^NSExecutionFactory)(void);
void NSSetConfigurationExecutionFactory(id<NSConfigurationExecution> (^factory)(void)) {
    @synchronized(NSConfigurationAccess.class) {
        NSExecutionFactory = [factory copy];
    }
}
BOOL NSConfigurationExecutionDeferred(NSError *error) {
    return [error.userInfo[@"configurationExecutionDeferred"] boolValue];
}
BOOL NSConfigurationSection(NSStoreLock * (^acquire)(NSError **),
                            BOOL (^work)(NSSharedDirectory *, NSError **), NSError **error) {
    id<NSConfigurationExecution> (^factory)(void);
    @synchronized(NSConfigurationAccess.class) {
        factory = NSExecutionFactory;
    }
    id<NSConfigurationExecution> execution = factory ? factory() : nil;
    NSStoreLock *lock = nil;
    @try {
        if (factory && !execution.valid) {
            if (error) {
                *error = [NSError
                    errorWithDomain:@"NetShield2.Configuration"
                               code:EAGAIN
                           userInfo:@{
                               NSLocalizedDescriptionKey :
                                   @"Local configuration work is deferred until the app can execute safely.",
                               @"configurationExecutionDeferred" : @YES
                           }];
            }
            return NO;
        }
        lock = acquire(error);
        if (!lock) {
            return NO;
        }
        if (factory && !execution.valid) {
            if (error) {
                *error = [NSError errorWithDomain:@"NetShield2.Configuration"
                                             code:EAGAIN
                                         userInfo:@{
                                             NSLocalizedDescriptionKey :
                                                 @"The local execution budget expired before work began.",
                                             @"configurationExecutionDeferred" : @YES
                                         }];
            }
            return NO;
        }
        return work(lock.directory, error);
    } @finally {
        [lock unlock];
        [execution finish]; // Never wait for main or hop queues with the lock held.
    }
}

@interface NSConfigurationAccess ()
@property(atomic) BOOL valid;
@end
@implementation NSConfigurationAccess {
    NSSharedDirectory *_directory;
    NSDictionary *_record;
    NSTimeInterval _expiry;
}
- (instancetype)initWithDirectory:(NSSharedDirectory *)directory
                           record:(NSDictionary *)record
                           expiry:(NSTimeInterval)expiry {
    if (!directory || !NSConfigurationRecordValid(record) || ![record[@"version"] isEqual:@3] ||
        ![record[@"state"] isEqual:@"reserved"]) {
        return nil;
    }
    if ((self = [super init])) {
        _directory = directory;
        _record = [record copy];
        _expiry = expiry;
        _valid = YES;
    }
    return self;
}
- (void)invalidate {
    self.valid = NO;
}
- (BOOL)perform:(BOOL (^)(NSSharedDirectory *, NSError **))work error:(NSError **)error {
    return NSConfigurationSection(
        ^NSStoreLock *(NSError **lockError) {
            return [NSStoreLock tryLockInDirectory:self->_directory
                                              leaf:NSConfigurationLockFile
                                             error:lockError];
        },
        ^BOOL(NSSharedDirectory *directory, NSError **localError) {
            if (!self.valid || (self->_expiry && NSProcessInfo.processInfo.systemUptime >= self->_expiry)) {
                if (localError) {
                    *localError =
                        [NSError errorWithDomain:@"NetShield2.Configuration"
                                            code:ESTALE
                                        userInfo:@{
                                            NSLocalizedDescriptionKey : @"The queued configuration operation "
                                                                        @"ended. Shared state was preserved."
                                        }];
                }
                return NO;
            }
            return NSConfigurationAdmission(directory, self->_record, localError) &&
                   work(directory, localError);
        },
        error);
}
@end
