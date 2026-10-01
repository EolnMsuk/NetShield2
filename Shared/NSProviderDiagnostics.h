#import <Foundation/Foundation.h>
#import <os/log.h>
#import "NSConstants.h"

// Lifecycle diagnostics only: never log destinations, payloads, or policy contents.
// The data provider must not write a heartbeat into the shared container.
static inline void NSProviderLog(NSString *role, NSString *stage, NSString *activation, NSError *error) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.eolnmsuk.netshield", "ProviderLifecycle");
    });
    os_log_with_type(log, error ? OS_LOG_TYPE_ERROR : OS_LOG_TYPE_DEFAULT,
                     "%{public}@ %{public}@ engine=%ld activation=%{public}@ OS=%{public}@ "
                     "error=%{public}@ code=%ld description=%{public}@",
                     role, stage, (long)NSEngineVersion, activation ?: @"",
                     NSProcessInfo.processInfo.operatingSystemVersionString, error.domain ?: @"",
                     (long)error.code, error.localizedDescription ?: @"");
}
