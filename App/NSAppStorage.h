#import <Foundation/Foundation.h>
// One app worker; callers coalesce snapshots and generation-check UI delivery.
FOUNDATION_EXPORT dispatch_queue_t NSAppStorageQueue(void);
