#import <Foundation/Foundation.h>
#import "NSStoreLock.h"

// Version 3 distinguishes a replaceable reservation (no OS write outstanding)
// from a pending dispatch. Legacy/v1/v2 pending records retain their old fences.
FOUNDATION_EXPORT NSDictionary *NSDecodeConfigurationRecord(NSData *data);
FOUNDATION_EXPORT BOOL NSConfigurationRecordValid(NSDictionary *record);
FOUNDATION_EXPORT BOOL NSConfigurationAdmission(NSSharedDirectory *directory, NSDictionary *expected,
                                                NSError **error);
FOUNDATION_EXPORT BOOL NSConfigurationSameDirectory(NSSharedDirectory *a, NSSharedDirectory *b);

// Installed only by UIApplicationMain's delegate. Tests and --remove-filter use
// the Foundation-only default. A refused/expired budget never grants a lock.
@protocol NSConfigurationExecution <NSObject>
@property(atomic, readonly) BOOL valid;
- (void)finish;
@end
FOUNDATION_EXPORT void NSSetConfigurationExecutionFactory(id<NSConfigurationExecution> (^factory)(void));
FOUNDATION_EXPORT BOOL NSConfigurationExecutionDeferred(NSError *error);
FOUNDATION_EXPORT BOOL NSConfigurationSection(NSStoreLock * (^acquire)(NSError **),
                                              BOOL (^work)(NSSharedDirectory *, NSError **), NSError **error);

// Immutable record/directory for a queued local mutation, with a revocation
// latch for finish/expiry. It carries no lock or mutable coordinator state.
@interface NSConfigurationAccess : NSObject
- (instancetype)initWithDirectory:(NSSharedDirectory *)directory
                           record:(NSDictionary *)record
                           expiry:(NSTimeInterval)expiry;
- (void)invalidate;
- (BOOL)perform:(BOOL (^)(NSSharedDirectory *, NSError **))work error:(NSError **)error;
@end
