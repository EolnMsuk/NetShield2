#import "../Shared/NSStore.h"
#import "../Shared/NSBoundedFile.h"
#import "../Shared/NSMonitorSchema.h"
#import "../FilterControl/NSDomainResolver.h"
#import "../FilterControl/NSProviderWorkQueue.h"
#import "../App/NSReleaseFetch.h"
#import "../Shared/NSActivity.h"
#import "../Shared/NSGlobalRule.h"
#import "../Shared/NSDNSCache.h"
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <limits.h>
#define EXPECT(...)                                                                                          \
    do {                                                                                                     \
        if (!(__VA_ARGS__)) {                                                                                \
            NSLog(@"Hardening regression failed %s:%d: %s", __FILE__, __LINE__, #__VA_ARGS__);               \
            abort();                                                                                         \
        }                                                                                                    \
    } while (0)
static void TestBoundedFiles(void) {
    NSURL *root = NSSharedURL(@"");
    NSSharedDirectory *directory = [NSSharedDirectory openRoot:root leaf:NSMonitorFile error:NULL];
    EXPECT(directory);
    NSURL *url = NSSharedURL(NSMonitorFile);
    [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    EXPECT(mkfifo(url.fileSystemRepresentation, 0600) == 0);
    EXPECT(!NSReadDocument(NSMonitorFile, NULL));
    [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    EXPECT(symlink(NSSharedURL(NSPolicyFile).fileSystemRepresentation, url.fileSystemRepresentation) == 0);
    EXPECT(!NSReadDocument(NSMonitorFile, NULL));
    EXPECT(!NSWriteDocument(@{}, NSMonitorFile, NULL));
    NSString *fixture = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSURL *lockRoot = [NSURL fileURLWithPath:fixture isDirectory:YES];
    EXPECT([NSFileManager.defaultManager createDirectoryAtURL:lockRoot
                                  withIntermediateDirectories:NO
                                                   attributes:nil
                                                        error:NULL]);
    NSURL *lockURL = [lockRoot URLByAppendingPathComponent:@"activity.lock"];
    EXPECT(symlink(NSSharedURL(NSPolicyFile).fileSystemRepresentation, lockURL.fileSystemRepresentation) ==
           0);
    EXPECT(![NSStoreLock tryLockRoot:lockRoot leaf:@"activity.lock" error:NULL]);
    EXPECT([NSFileManager.defaultManager removeItemAtURL:lockRoot error:NULL]);
    [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    EXPECT([NSFileManager.defaultManager createDirectoryAtURL:url
                                  withIntermediateDirectories:NO
                                                   attributes:nil
                                                        error:NULL]);
    EXPECT(!NSReadDocument(NSMonitorFile, NULL));
    [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    EXPECT(NSWriteDocument(@{@"value" : @1}, NSMonitorFile, NULL));
    struct stat before = {0};
    int fd = NSOpenRegularFile(directory, NSMonitorFile, &before, NULL);
    EXPECT(fd >= 0);
    EXPECT(NSWriteDocument(@{@"value" : @2}, NSMonitorFile, NULL));
    NSError *replacementError = nil;
    EXPECT(!NSReadBoundedDescriptor(fd, directory, NSMonitorFile, before, &replacementError) &&
           NSFileReadChanged(replacementError) && !NSFileIsAbsent(replacementError));
    close(fd);
    fd = NSOpenRegularFile(directory, NSMonitorFile, &before, NULL);
    EXPECT(fd >= 0);
    int writer = open(url.fileSystemRepresentation, O_WRONLY | O_APPEND);
    EXPECT(writer >= 0 && write(writer, "extra", 5) == 5);
    close(writer);
    EXPECT(!NSReadBoundedDescriptor(fd, directory, NSMonitorFile, before, NULL)); // growth after fstat
    close(fd);
    EXPECT(!NSReadDocument(@"../policy.plist", NULL));
    EXPECT(!NSWriteDocument(@{}, @"../policy.plist", NULL));
}
static void TestContainerAliases(void) {
    NSString *path = [@"/private/var/tmp" stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSURL *physical = [NSURL fileURLWithPath:path isDirectory:YES];
    NSURL *alias = [NSURL fileURLWithPath:[path substringFromIndex:@"/private".length] isDirectory:YES];
    EXPECT([physical.path hasPrefix:@"/private/var/"] && [alias.path hasPrefix:@"/var/"]);
    NSFileManager *files = NSFileManager.defaultManager;
    EXPECT([files createDirectoryAtURL:physical withIntermediateDirectories:NO attributes:nil error:NULL]);
    NSURL *original = NSSharedURL(@"");
    NSSetTestContainer(physical);
    NSError *error = nil;
    EXPECT(!NSReadDocument(NSMonitorFile, &error) && NSFileIsAbsent(error));
    EXPECT(NSWriteDocument(@{@"value" : @1}, NSMonitorFile, NULL));
    NSStoreLock *lock = [NSStoreLock tryLockRoot:physical leaf:NSConfigurationLockFile error:NULL];
    EXPECT(lock);
    NSSetTestContainer(alias);
    EXPECT([NSReadDocument(NSMonitorFile, NULL)[@"value"] isEqual:@1]);
    EXPECT(![NSStoreLock tryLockRoot:alias leaf:NSConfigurationLockFile error:&error] &&
           NSIsLockContention(error));
    [lock unlock];
    lock = [NSStoreLock tryLockRoot:alias leaf:NSConfigurationLockFile error:NULL];
    EXPECT(lock && ![NSStoreLock tryLockRoot:physical leaf:NSConfigurationLockFile error:&error] &&
           NSIsLockContention(error));
    [lock unlock];
    EXPECT(NSWriteDocument(@{@"value" : @2}, NSMonitorFile, NULL));
    NSSetTestContainer(physical);
    EXPECT([NSReadDocument(NSMonitorFile, NULL)[@"value"] isEqual:@2]);
    NSSharedDirectory *directory = [NSSharedDirectory openRoot:alias leaf:NSMonitorFile error:NULL];
    EXPECT(directory);
    EXPECT(!NSWriteBoundedFile([NSMutableData dataWithLength:NSMaximumDocumentBytes + 1], directory,
                               NSMonitorFile, NO, &error) &&
           error.code == EFBIG);
    const unichar nul = 0;
    NSString *embeddedNUL = [NSMonitorFile stringByAppendingString:[NSString stringWithCharacters:&nul
                                                                                           length:1]];
    EXPECT(!NSUnlinkBoundedFile(directory, embeddedNUL, &error) && error.code == EINVAL);
    EXPECT(NSUnlinkBoundedFile(directory, NSMonitorFile, NULL));
    EXPECT(NSUnlinkBoundedFile(directory, NSMonitorFile, NULL));
    EXPECT(!NSReadDocument(NSMonitorFile, &error) && NSFileIsAbsent(error));
    EXPECT([files fileExistsAtPath:NSSharedURL(NSConfigurationLockFile).path]);
    NSSetTestContainer([physical URLByAppendingPathComponent:@"missing" isDirectory:YES]);
    EXPECT(!NSReadDocument(NSMonitorFile, &error) && error.code == ENOENT && !NSFileIsAbsent(error));
    NSSetTestContainer(original);
    EXPECT([files removeItemAtURL:physical error:NULL]);
}
static void TestMonitorCorpus(void) {
    NSDictionary *request = @{
        @"token" : @"t",
        @"identity" : @"exact.identity",
        @"created" : NSDate.date,
        @"expires" : NSDate.date,
        @"waiting" : @0,
        @"expired" : @YES
    };
    NSDictionary *base = @{
        @"schema" : @2,
        @"updated" : NSDate.date,
        @"lastReport" : NSDate.date,
        @"controlRunning" : @YES,
        @"policyError" : @"",
        @"events" : @[],
        @"requests" : @[ request ]
    };
    EXPECT(NSValidateMonitor(base, NULL));
    for (id invalid in @[ @0, @1, @"yes", @[] ]) {
        NSMutableDictionary *d = [base mutableCopy];
        d[@"controlRunning"] = invalid;
        EXPECT(!NSValidateMonitor(d, NULL));
    }
    NSMutableDictionary *d = [base mutableCopy];
    d[@"requests"] = @[ request, request ];
    EXPECT(!NSValidateMonitor(d, NULL));
    for (NSString *field in @[ @"waiting", @"expired", @"askGeneration", @"token" ]) {
        NSMutableDictionary *r = [request mutableCopy];
        r[field] = @-1;
        d = [base mutableCopy];
        d[@"requests"] = @[ r ];
        EXPECT(!NSValidateMonitor(d, NULL));
    }
    for (id count in @[ @-1, @1.5, @YES, @"5" ]) {
        d = [base mutableCopy];
        d[@"overflowCount"] = count;
        EXPECT(!NSValidateMonitor(d, NULL));
    }
    d = [base mutableCopy];
    d[@"overflowCount"] = @(ULLONG_MAX);
    EXPECT(NSValidateMonitor(d, NULL));
    d[@"schema"] = @3;
    EXPECT(!NSValidateMonitor(d, NULL));
    NSError *error = nil;
    EXPECT(NSWriteDocument(d, NSMonitorFile, NULL));
    EXPECT(!NSReadMonitorWithError(&error) && [error.domain isEqual:@"NetShield2.Monitor"]);
    NSMutableDictionary *future = [[NSPolicy defaultDocument] mutableCopy];
    future[@"schema"] = @99;
    EXPECT(NSWriteDocument(future, NSPolicyFile, NULL));
    EXPECT(!NSReadPolicy(NULL) && !NSEnsurePolicy(NULL));
    EXPECT([NSReadDocument(NSPolicyFile, NULL)[@"schema"] isEqual:@99]);
    EXPECT(NSWriteDocument([NSPolicy defaultDocument], NSPolicyFile, NULL));
}
static void TestBoundedStateAdmission(void) {
    NSProviderWorkQueue *work = [[NSProviderWorkQueue alloc] initWithCapacity:2];
    dispatch_semaphore_t release = dispatch_semaphore_create(0);
    EXPECT([work submit:^{
        dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
    }]);
    EXPECT([work submit:^{
    }]);
    EXPECT(![work submit:^{
    }]);
    dispatch_semaphore_signal(release);
    dispatch_sync(work.queue, ^{
                  });
    __block BOOL reentered = NO;
    EXPECT([work submit:^{
        reentered = [work submit:^{
        }];
    }]);
    dispatch_sync(work.queue, ^{
                  });
    EXPECT(reentered);
}
static void TestDetachedReplyGate(void) {
    dispatch_queue_t delivery = dispatch_queue_create("test.control.delivery", DISPATCH_QUEUE_SERIAL);
    NSProviderReplyGate *gate = [[NSProviderReplyGate alloc] initWithCapacity:1 delivery:delivery];
    dispatch_semaphore_t resume = dispatch_semaphore_create(0);
    __block NSUInteger calls = 0;
    NSProviderReply *reply = [gate admit:^(id verdict) {
        EXPECT([verdict isEqual:@"deny"]);
        EXPECT(![gate admit:^(id ignored){
        }]); // reentrant callback still owns its slot
        dispatch_semaphore_wait(resume, DISPATCH_TIME_FOREVER);
        calls++;
    }];
    EXPECT(reply);
    [reply complete:@"deny"];
    [reply complete:@"duplicate"];
    EXPECT(![gate admit:^(id ignored){
    }]);
    dispatch_semaphore_signal(resume);
    dispatch_sync(delivery, ^{
        EXPECT(calls == 1);
    });
    reply = [gate admit:^(id verdict) {
        calls++;
    }];
    EXPECT(reply);
    [reply complete:@"done"];
    dispatch_sync(delivery, ^{
        EXPECT(calls == 2);
    });
}
static void TestDNSLifetime(void) {
    NSDictionary *lifetime = @{@"issued" : @100, @"expires" : @101, @"boot" : @"boot-one"};
    EXPECT(NSDNSLifetimeIsLive(lifetime, 100.5, @"boot-one"));
    EXPECT(!NSDNSLifetimeIsLive(lifetime, 100.5, @"boot-two"));
    EXPECT(!NSDNSLifetimeIsLive(lifetime, 101, @"boot-one"));
    EXPECT(!NSDNSLifetimeIsLive(lifetime, 0, @"boot-one"));
}
static void TestEarlyDNSFactories(void) {
    for (NSUInteger sizeIndex = 0; sizeIndex < 4; sizeIndex++) {
        NSUInteger count = (NSUInteger[]){1, 64, 256, NSMaximumRules}[sizeIndex];
        dispatch_queue_t queue = dispatch_queue_create("test.dns.early", DISPATCH_QUEUE_SERIAL);
        NSMutableDictionary *rules = [NSMutableDictionary new];
        for (NSUInteger i = 0; i < count; i++) {
            rules[[NSString stringWithFormat:@"domain:d%lu.test", (unsigned long)i]] = @"block";
        }
        NSMutableSet<NSString *> *delivered = [NSMutableSet new];
        __block NSUInteger factories = 0;
        dispatch_semaphore_t complete = dispatch_semaphore_create(0);
        NSDomainResolver *resolver = [[NSDomainResolver alloc] initWithQueue:queue
            clock:^{
                return 100.0;
            }
            lookup:^id<NSDNSOperation>(NSString *key, dispatch_queue_t unused,
                                       void (^finished)(NSDictionary *, NSError *)) {
                factories++;
                // Only the one-rule case returns nil without invoking the callback.
                if (count > 1) {
                    finished(nil, [NSError errorWithDomain:@"test" code:1 userInfo:nil]);
                    finished(nil, nil);
                }
                return nil;
            }
            completion:^(NSString *key, NSString *rule, NSDictionary *result, NSError *error) {
                EXPECT(!result && [error.domain isEqual:count > 1 ? @"test" : @"NetShield2.DNS"]);
                EXPECT([rules[key] isEqual:rule] && ![delivered containsObject:key]);
                [delivered addObject:key];
                if (delivered.count == count) {
                    dispatch_semaphore_signal(complete);
                }
            }];
        [resolver refreshRules:rules];
        long wait = dispatch_semaphore_wait(complete, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        if (wait) {
            NSLog(@"DNS factory fixture timed out with %lu rules", (unsigned long)count);
        }
        EXPECT(wait == 0);
        dispatch_sync(queue, ^{
            EXPECT(delivered.count == count && factories == count);
        });
        [resolver refreshRules:rules];
        dispatch_sync(queue, ^{
            EXPECT(factories == count);
        }); // failure backoff
        __block BOOL stopped = NO;
        [resolver stopWithCompletion:^{
            stopped = YES;
        }];
        dispatch_sync(queue, ^{
            EXPECT(stopped);
        });
    }
}
static void TestStreamingReleaseBody(void) {
    NSURL *url = [NSURL URLWithString:@"https://api.github.com/repos/EolnMsuk/NetShield2/releases/latest"];
    NSReleaseBody *body = [NSReleaseBody new];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{}];
    EXPECT([body acceptResponse:response]);
    EXPECT([body append:[NSMutableData dataWithLength:1024 * 1024]]);
    EXPECT(![body append:[@"x" dataUsingEncoding:NSUTF8StringEncoding]]);
    EXPECT(body.data.length == 1024 * 1024);
    response = [[NSHTTPURLResponse alloc] initWithURL:url
                                           statusCode:200
                                          HTTPVersion:@"HTTP/1.1"
                                         headerFields:@{@"Content-Length" : @"1048577"}];
    EXPECT(![body acceptResponse:response]);
    for (NSString *text in @[
             @"http://api.github.com/repos/EolnMsuk/NetShield2/releases/latest",
             @"https://evil.test/repos/EolnMsuk/NetShield2/releases/latest",
             @"https://api.github.com.evil.test/repos/EolnMsuk/NetShield2/releases/latest",
             @"https://user:password@api.github.com/repos/EolnMsuk/NetShield2/releases/latest"
         ]) {
        EXPECT(!NSAllowedReleaseURL([NSURL URLWithString:text]));
    }
}
static void TestDecisionParity(void) {
    NSDictionary *peer = @{
        @"address" : @"192.0.2.1",
        @"domain" : @"example.test",
        @"port" : @443,
        @"localPort" : @1234,
        @"protocol" : @"tcp"
    };
    for (NSString *address in @[ @"allow", @"block" ]) {
        for (NSString *domain in @[ @"allow", @"block" ]) {
            NSMutableDictionary *document = [[NSPolicy defaultDocument] mutableCopy];
            document[@"globalRules"] = @{
                @"ip:192.0.2.1" : address,
                @"domain:example.test" : domain,
                @"port:443" : @"allow",
                @"localPort:1234" : @"block"
            };
            for (NSString *customAction in @[ @"allow", @"block", @"allow-inbound", @"block-outbound" ]) {
                NSMutableDictionary *rules = [document[@"globalRules"] mutableCopy];
                rules[NSCustomGlobalRuleKey(@"exact.app", @"", @"", @"any")] = customAction;
                document[@"globalRules"] = rules;
                NSPolicy *policy = [NSPolicy policyWithDocument:document error:NULL];
                EXPECT(policy);
                for (NSNumber *direction in @[ @0, @1, @2, @-1, @99 ]) {
                    for (NSString *identity in @[ @"exact.app", @"com.apple.test", @"" ]) {
                        NSFlowDirection normalized = NSNormalizedFlowDirection(direction.integerValue);
                        NSFlowEvaluation decision = [policy evaluateIdentity:identity
                                                                   direction:direction.integerValue
                                                                 destination:peer
                                                                      socket:YES];
                        BOOL ask = [policy requiresPermissionForIdentity:identity
                                                               direction:normalized
                                                             destination:peer];
                        BOOL allow = [policy allowsIdentity:identity direction:normalized destination:peer];
                        EXPECT(decision.disposition ==
                               (ask ? NSFlowAsk : (allow ? NSFlowAllow : NSFlowDrop)));
                        if (![identity isEqual:@"exact.app"]) {
                            EXPECT(allow ==
                                   [address isEqual:@"allow"]); // schema-3 address precedes domain/ports
                        }
                    }
                }
            }
        }
    }
}
static void TestActivityGenerationsAndCounters(void) {
    NSDictionary *event = @{
        @"identity" : @"activity.app",
        @"flow" : @"one",
        @"action" : @"allow",
        @"direction" : @"outbound",
        @"event" : @0,
        @"bytesIn" : @(ULLONG_MAX),
        @"bytesOut" : @0,
        @"time" : [NSDate dateWithTimeIntervalSinceNow:86400],
        @"destination" : @{@"address" : @"192.0.2.1", @"port" : @443, @"protocol" : @"tcp"}
    };
    NSDictionary *old = NSActivityEventWithCurrentBoundary(event);
    NSDictionary *report = @{
        @"schema" : @2,
        @"updated" : NSDate.date,
        @"lastReport" : NSDate.date,
        @"controlRunning" : @YES,
        @"policyError" : @"",
        @"activityGenerations" : @YES,
        @"events" : @[],
        @"requests" : @[]
    };
    EXPECT(NSWriteMonitorSnapshot(report, NULL));
    EXPECT(NSClearActivity(NULL));
    NSMutableDictionary *past = [event mutableCopy];
    past[@"time"] = [NSDate dateWithTimeIntervalSince1970:1];
    NSDictionary *fresh = NSActivityEventWithCurrentBoundary(past);
    EXPECT(NSActivityAfterClear(@[ old, fresh ]).count == 1);
    NSMutableDictionary *two = [fresh mutableCopy];
    two[@"flow"] = @"two";
    two[@"action"] = @"block";
    NSArray *groups = NSGroupedActivity(@[ fresh, two ]);
    EXPECT(groups.count == 1 && [groups[0][@"action"] isEqual:@"mixed"]);
    EXPECT([groups[0][@"bytesIn"] unsignedLongLongValue] == ULLONG_MAX &&
           [groups[0][@"bytesSaturated"] boolValue]);
    two[@"destination"] = @{@"address" : @"192.0.2.1", @"port" : @443, @"protocol" : @"udp"};
    EXPECT(NSGroupedActivity(@[ fresh, two ]).count == 2);
    EXPECT(NSWriteMonitorSnapshot(report, NULL));
    EXPECT(NSReadMonitor()[@"events"] != nil);
}
void NSRunHardeningTests(void) {
    TestBoundedFiles();
    TestContainerAliases();
    TestMonitorCorpus();
    TestBoundedStateAdmission();
    TestEarlyDNSFactories();
    TestStreamingReleaseBody();
    TestDecisionParity();
    TestActivityGenerationsAndCounters();
    TestDetachedReplyGate();
    TestDNSLifetime();
}
