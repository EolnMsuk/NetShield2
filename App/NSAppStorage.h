#import <Foundation/Foundation.h>
// One app worker; callers coalesce snapshots and generation-check UI delivery.
FOUNDATION_EXPORT dispatch_queue_t NSAppStorageQueue(void);
// Register only after UIApplicationMain; the removal helper never calls UIKit.
FOUNDATION_EXPORT void NSRegisterConfigurationExecution(void);
FOUNDATION_EXPORT void NSResumeConfigurationExecution(void);
