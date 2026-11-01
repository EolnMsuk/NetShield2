#import "../App/NSRespring.h"
#include <errno.h>
#include <stdlib.h>

static NSUInteger checks;
#define VERIFY(...)                                                                                          \
    do {                                                                                                     \
        checks++;                                                                                            \
        if (!(__VA_ARGS__)) {                                                                                \
            NSLog(@"FAIL %s:%d: %s", __FILE__, __LINE__, #__VA_ARGS__);                                      \
            abort();                                                                                         \
        }                                                                                                    \
    } while (0)

static BOOL Launch(NSArray<NSString *> *paths, NSArray<NSNumber *> *results,
                   NSMutableArray<NSString *> *attempts, NSError **error) {
    return NSRespringUsingLauncher(
        paths,
        ^int(NSString *path) {
            VERIFY(attempts.count < results.count);
            int result = results[attempts.count].intValue;
            [attempts addObject:path];
            return result;
        },
        error);
}

int main(void) {
    @autoreleasepool {
        // These paths intentionally do not exist on the test host: the launcher,
        // rather than a separate access() preflight, must decide the outcome.
        NSString *preferred = @"/netshield-test/.jbroot-fixture/usr/bin/sbreload";
        NSString *fallback = @"/netshield-test/usr/bin/sbreload";
        NSArray<NSString *> *paths = @[ preferred, fallback ];
        NSMutableArray<NSString *> *attempts = [NSMutableArray new];
        NSError *error = nil;
        VERIFY(Launch(paths, @[ @0 ], attempts, &error));
        VERIFY(error == nil && [attempts isEqual:@[ preferred ]]);

        for (NSNumber *missing in @[ @(ENOENT), @(ENOTDIR) ]) {
            [attempts removeAllObjects];
            error = nil;
            VERIFY(Launch(paths, @[ missing, @0 ], attempts, &error));
            VERIFY(error == nil && [attempts isEqual:paths]);
        }
        // Permission and policy denials are not evidence that a tool is absent.
        // Do not hide them by trying another jailbreak's executable.
        for (NSNumber *denied in @[ @(EPERM), @(EACCES), @(ENOEXEC) ]) {
            [attempts removeAllObjects];
            error = nil;
            VERIFY(!Launch(paths, @[ denied ], attempts, &error));
            VERIFY([attempts isEqual:@[ preferred ]]);
            VERIFY([error.domain isEqual:@"NetShield2.Respring"] && error.code == denied.intValue);
            NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
            VERIFY([underlying.domain isEqual:NSPOSIXErrorDomain] && underlying.code == denied.intValue);
            VERIFY([error.localizedDescription containsString:preferred]);
            VERIFY(![error.localizedDescription containsString:fallback]);
        }
        [attempts removeAllObjects];
        error = nil;
        VERIFY(!Launch(paths, @[ @(ENOENT), @(EPERM) ], attempts, &error));
        VERIFY([attempts isEqual:paths] && error.code == EPERM);
        VERIFY([error.localizedDescription containsString:preferred]);
        VERIFY([error.localizedDescription containsString:fallback]);
        [attempts removeAllObjects];
        VERIFY(!Launch(paths, @[ @(EACCES) ], attempts, NULL));
        [attempts removeAllObjects];
        error = nil;
        VERIFY(!Launch(@[], @[], attempts, &error));
        VERIFY(attempts.count == 0 && error.code == ENOENT);
        NSLog(@"Passed %lu respring launch/fallback checks", (unsigned long)checks);
    }
    return 0;
}
