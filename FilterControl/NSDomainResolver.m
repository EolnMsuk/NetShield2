#import "NSDomainResolver.h"
#import "../Shared/NSGlobalRule.h"
#import "../Shared/NSDNSCache.h"
#include <dns_sd.h>
#include <netinet/in.h>

// All methods, C callbacks and reference destruction belong to queue. Each
// DNSServiceRef owns one retained callback context until deallocation on queue.
@interface NSDNSLookup : NSObject <NSDNSOperation>
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *references;
@property(nonatomic, strong) NSMutableDictionary<NSArray *, NSNumber *> *records;
@property(nonatomic, strong) NSMutableSet *batches;
@property(nonatomic) NSTimeInterval deadline;
@property(nonatomic, copy) void (^completion)(NSDictionary *, NSError *);
- (void)finish:(NSError *)error;
- (void)settle;
- (void)cancel;
@end
static NSError *NSDNSError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"NetShield2.DNS"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}
static void NSDNSAnswer(DNSServiceRef reference, DNSServiceFlags flags, uint32_t interface,
                        DNSServiceErrorType error, const char *host, const struct sockaddr *address,
                        uint32_t ttl, void *context) {
    NSDNSLookup *lookup = (__bridge NSDNSLookup *)context;
    if (!lookup.completion) {
        return;
    }
    NSValue *ref = [NSValue valueWithPointer:reference];
    if (error == kDNSServiceErr_NoSuchRecord) {
        [lookup.batches addObject:ref];
        [lookup settle];
        return;
    }
    if (error != kDNSServiceErr_NoError) {
        [lookup
            finish:NSDNSError(error, @"DNS service failed; previous answers retain their original expiry.")];
        return;
    }
    if (!address) {
        return;
    }
    {
        char text[INET6_ADDRSTRLEN];
        const void *bytes = address->sa_family == AF_INET
                                ? (const void *)&((const struct sockaddr_in *)address)->sin_addr
                                : (address->sa_family == AF_INET6
                                       ? (const void *)&((const struct sockaddr_in6 *)address)->sin6_addr
                                       : NULL);
        if (bytes && inet_ntop(address->sa_family, bytes, text, sizeof(text))) {
            NSString *key = NSGlobalHostKey(@(text));
            // Include reference and interface: withdrawing one interface must
            // not erase a still-live record returned on another interface.
            NSArray *record = @[ ref, @(interface), key ];
            if (!(flags & kDNSServiceFlagsAdd) || ttl == 0) {
                [lookup.records removeObjectForKey:record];
            } else if (lookup.records.count < 256 || lookup.records[record]) {
                lookup.records[record] = @(NSProcessInfo.processInfo.systemUptime + MIN(300, ttl));
            }
        }
    }
    if (!(flags & kDNSServiceFlagsMoreComing)) {
        [lookup.batches addObject:ref];
    } else {
        [lookup.batches removeObject:ref];
    }
    [lookup settle];
}
@implementation NSDNSLookup
- (instancetype)initWithKey:(NSString *)key
                      queue:(dispatch_queue_t)queue
                 completion:(void (^)(NSDictionary *, NSError *))completion {
    if ((self = [super init])) {
        _queue = queue;
        _records = [NSMutableDictionary new];
        _references = [NSMutableArray new];
        _batches = [NSMutableSet new];
        _completion = [completion copy];
        _deadline = NSProcessInfo.processInfo.systemUptime + 3;
        _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        if (!_timer) {
            return nil;
        }
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(_timer, ^{
            NSDNSLookup *owner = weakSelf;
            if (!owner) {
                return;
            }
            BOOL answered = owner.records.count || owner.batches.count == owner.references.count;
            [owner finish:answered
                              ? nil
                              : NSDNSError(1, @"DNS lookup timed out; previous answers expire normally.")];
        });
        dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                                  DISPATCH_TIME_FOREVER, NSEC_PER_MSEC * 10);
        dispatch_resume(_timer);
        NSError *failure = nil;
        for (NSString *host in NSGlobalDomainAliases(key)) {
            for (NSNumber *family in @[ @(kDNSServiceProtocol_IPv4), @(kDNSServiceProtocol_IPv6) ]) {
                DNSServiceRef reference = NULL;
                void *context = (__bridge_retained void *)self;
                DNSServiceErrorType error = DNSServiceGetAddrInfo(&reference, 0, 0, family.unsignedIntValue,
                                                                  host.UTF8String, NSDNSAnswer, context);
                if (!error) {
                    error = DNSServiceSetDispatchQueue(reference, queue);
                }
                if (error) {
                    if (reference) {
                        DNSServiceRefDeallocate(reference);
                    }
                    (void)CFBridgingRelease(context);
                    failure = NSDNSError(error, @"DNS reference allocation or dispatch integration failed.");
                } else {
                    [_references addObject:@{
                        @"ref" : [NSValue valueWithPointer:reference],
                        @"context" : [NSValue valueWithPointer:context]
                    }];
                }
            }
        }
        if (failure || !_references.count) {
            dispatch_async(queue, ^{
                [self finish:failure ?: NSDNSError(2, @"No DNS reference could be created.")];
            });
        }
    }
    return self;
}
- (void)settle {
    // A quiet 100 ms batch window is a bounded settling policy, not a claim
    // that MoreComing marks the end of all future DNS records.
    NSTimeInterval remaining = MAX(0, self.deadline - NSProcessInfo.processInfo.systemUptime);
    NSTimeInterval delay = self.batches.count == self.references.count ? MIN(0.1, remaining) : remaining;
    dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, NSEC_PER_MSEC * 10);
}
- (void)finish:(NSError *)error {
    void (^completion)(NSDictionary *, NSError *) = self.completion;
    if (!completion) {
        return;
    }
    NSMutableOrderedSet *addresses = [NSMutableOrderedSet new];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSTimeInterval expires = now + 300;
    for (NSArray *record in self.records) {
        NSTimeInterval expiry = self.records[record].doubleValue;
        if (expiry <= now) {
            continue;
        }
        if (addresses.count < 128) {
            [addresses addObject:record[2]];
        }
        expires = MIN(expires, expiry);
    }
    if (!addresses.count) {
        expires = now + 2;
    }
    NSDictionary *result = error ? nil : @{
        @"addresses" : [addresses.array sortedArrayUsingSelector:@selector(compare:)],
        @"expires" : [NSDate dateWithTimeIntervalSinceNow:expires - now],
        @"source" : @"dns",
        @"lifetime" :
            @{@"issued" : @(now), @"expires" : @(expires), @"boot" : NSBootSessionIdentifier() ?: @""}
    };
    [self cancel];
    completion(result, error);
}
- (void)cancel {
    self.completion = nil;
    if (self.timer) {
        dispatch_source_cancel(self.timer);
        self.timer = nil;
    }
    NSArray *references = [self.references copy];
    [self.references removeAllObjects];
    for (NSDictionary *entry in references) {
        DNSServiceRefDeallocate([entry[@"ref"] pointerValue]);
        (void)CFBridgingRelease([entry[@"context"] pointerValue]);
    }
}
@end

@interface NSDomainResolver ()
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSDictionary *rules;
@property(nonatomic, copy) NSDictionary *inputRules;
@property(nonatomic, copy) NSDictionary *sourceRules;
@property(nonatomic) BOOL refreshQueued;
@property(nonatomic, copy) NSString *inputGeneration;
@property(nonatomic, copy) NSString *generation;
@property(nonatomic, copy) NSString *coverageStatus;
@property(nonatomic, strong) NSMutableArray<NSString *> *unstartedKeys;
@property(nonatomic, strong) NSMutableArray<NSString *> *retryKeys;
@property(nonatomic, strong) NSMutableDictionary *failures;
@property(nonatomic, strong) NSMutableDictionary<NSString *, id<NSDNSOperation>> *active;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *lookupIDs;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *nextAttempt;
@property(nonatomic, copy) NSTimeInterval (^clock)(void);
@property(nonatomic, copy) NSDNSLookupFactory lookup;
@property(nonatomic, copy) void (^completion)(NSString *, NSString *, NSDictionary *, NSError *);
@property(nonatomic) BOOL stopped;
@end

@implementation NSDomainResolver
- (instancetype)initWithCompletion:(void (^)(NSString *, NSString *, NSDictionary *, NSError *))completion {
    return [self initWithQueue:dispatch_queue_create("com.eolnmsuk.netshield.dns", DISPATCH_QUEUE_SERIAL)
        clock:^NSTimeInterval {
            return NSProcessInfo.processInfo.systemUptime;
        }
        lookup:^id<NSDNSOperation>(NSString *key, dispatch_queue_t queue,
                                   void (^finished)(NSDictionary *, NSError *)) {
            return [[NSDNSLookup alloc] initWithKey:key queue:queue completion:finished];
        }
        completion:completion];
}
- (instancetype)initWithQueue:(dispatch_queue_t)queue
                        clock:(NSTimeInterval (^)(void))clock
                       lookup:(NSDNSLookupFactory)lookup
                   completion:(void (^)(NSString *, NSString *, NSDictionary *, NSError *))completion {
    if ((self = [super init])) {
        if (!queue || !clock || !lookup) {
            return nil;
        }
        _queue = queue;
        _clock = clock;
        _lookup = lookup;
        _unstartedKeys = [NSMutableArray new];
        _retryKeys = [NSMutableArray new];
        _active = [NSMutableDictionary new];
        _lookupIDs = [NSMutableDictionary new];
        _nextAttempt = [NSMutableDictionary new];
        _failures = [NSMutableDictionary new];
        _completion = completion;
    }
    return self;
}
- (NSString *)coverageIssue {
    @synchronized(self) {
        return self.coverageStatus ?: @"";
    }
}
- (void)refreshRules:(NSDictionary *)rules {
    [self refreshRules:rules generation:nil];
}
- (void)refreshRules:(NSDictionary *)rules generation:(NSString *)generation {
    @synchronized(self) {
        self.inputGeneration = [generation copy] ?: @"";
        self.inputRules = [rules copy];
        if (self.refreshQueued) {
            return;
        }
        self.refreshQueued = YES;
    }
    dispatch_async(self.queue, ^{
        NSDictionary *input;
        NSString *generation;
        @synchronized(self) {
            input = self.inputRules;
            generation = self.inputGeneration;
            self.inputRules = nil;
            self.refreshQueued = NO;
        }
        if (self.stopped) {
            return;
        }
        BOOL rebuildSchedule = ![generation isEqual:self.generation ?: @""];
        if (rebuildSchedule) {
            for (id<NSDNSOperation> operation in self.active.allValues) {
                [operation cancel];
            }
            [self.active removeAllObjects];
            [self.lookupIDs removeAllObjects];
            [self.nextAttempt removeAllObjects];
            [self.failures removeAllObjects];
        }
        self.generation = generation;
        if (![input isEqual:self.sourceRules]) {
            self.sourceRules = input;
            NSMutableDictionary *wanted = [NSMutableDictionary new];
            for (NSString *key in input) {
                if ([key hasPrefix:@"domain:"] && !NSGlobalActionIsAllow(input[key])) {
                    wanted[key] = input[key];
                }
            }
            if (![wanted isEqual:self.rules]) {
                for (NSString *key in self.rules) {
                    if (![wanted[key] isEqual:self.rules[key]]) {
                        [self.active[key] cancel];
                        [self.active removeObjectForKey:key];
                        [self.lookupIDs removeObjectForKey:key];
                        [self.nextAttempt removeObjectForKey:key];
                        [self.failures removeObjectForKey:key];
                    }
                }
                self.rules = [wanted copy];
                rebuildSchedule = YES;
            }
        }
        if (rebuildSchedule) {
            [self rebuildSchedule];
        }
        [self pump];
    });
}
- (NSComparisonResult)compareRetryKey:(NSString *)left toKey:(NSString *)right {
    NSComparisonResult order = [self.nextAttempt[right] compare:self.nextAttempt[left]];
    return order == NSOrderedSame ? [right compare:left] : order;
}
- (void)rebuildSchedule {
    [self.unstartedKeys removeAllObjects];
    [self.retryKeys removeAllObjects];
    for (NSString *key in self.rules) {
        if (!self.lookupIDs[key]) {
            NSMutableArray *pending = self.nextAttempt[key] ? self.retryKeys : self.unstartedKeys;
            [pending addObject:key];
        }
    }
    // Reverse priority keeps the next key at the end of each array.
    [self.unstartedKeys sortUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        return [right compare:left];
    }];
    [self.retryKeys sortUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        return [self compareRetryKey:left toKey:right];
    }];
}
- (NSString *)takeNextKeyAt:(NSTimeInterval)now {
    NSString *unstarted = self.unstartedKeys.lastObject;
    NSString *retry = self.retryKeys.lastObject;
    if (retry) {
        NSTimeInterval due = self.nextAttempt[retry].doubleValue;
        if (due <= now && (!unstarted || due < now || [retry compare:unstarted] == NSOrderedAscending)) {
            [self.retryKeys removeLastObject];
            return retry;
        }
    }
    if (unstarted) {
        [self.unstartedKeys removeLastObject];
    }
    return unstarted;
}
- (void)scheduleRetryForKey:(NSString *)key at:(NSTimeInterval)due {
    self.nextAttempt[key] = @(due);
    NSRange range = NSMakeRange(0, self.retryKeys.count);
    NSUInteger index = [self.retryKeys indexOfObject:key
                                       inSortedRange:range
                                             options:NSBinarySearchingInsertionIndex
                                     usingComparator:^NSComparisonResult(NSString *left, NSString *right) {
                                         return [self compareRetryKey:left toKey:right];
                                     }];
    [self.retryKeys insertObject:key atIndex:index];
}
- (NSUInteger)backlogAt:(NSTimeInterval)now {
    // Due retries are a suffix. Find its start without visiting every rule.
    NSUInteger first = 0, end = self.retryKeys.count;
    while (first < end) {
        NSUInteger middle = first + (end - first) / 2;
        if (self.nextAttempt[self.retryKeys[middle]].doubleValue > now) {
            first = middle + 1;
        } else {
            end = middle;
        }
    }
    return self.unstartedKeys.count + self.retryKeys.count - first;
}
- (void)pump {
    NSTimeInterval now = self.clock();
    while (!self.stopped && self.lookupIDs.count < 4) {
        NSString *key = [self takeNextKeyAt:now];
        if (!key) {
            break;
        }
        NSString *rule = self.rules[key];
        NSString *generation = self.generation ?: @"";
        NSString *lookupID = NSUUID.UUID.UUIDString;
        // Reserve before calling an injectable factory, including sync/nil paths.
        self.lookupIDs[key] = lookupID;
        __weak typeof(self) weakSelf = self;
        void (^finished)(NSDictionary *, NSError *) = ^(NSDictionary *result, NSError *error) {
            NSDomainResolver *owner = weakSelf;
            if (!owner) {
                return;
            }
            dispatch_async(owner.queue, ^{
                if (owner.stopped || ![owner.lookupIDs[key] isEqual:lookupID]) {
                    return;
                }
                [owner.active[key] cancel];
                [owner.active removeObjectForKey:key];
                [owner.lookupIDs removeObjectForKey:key];
                BOOL valid = [result isKindOfClass:NSDictionary.class] &&
                             [result[@"addresses"] isKindOfClass:NSArray.class] &&
                             [result[@"addresses"] count] <= 128 &&
                             NSDNSExpiryIsLive(result[@"expires"], NSDate.date);
                for (id address in valid ? result[@"addresses"] : @[]) {
                    if (![address isKindOfClass:NSString.class] || ![address hasPrefix:@"ip:"] ||
                        !NSValidGlobalRuleKey(address)) {
                        valid = NO;
                    }
                }
                NSDictionary *lifetime = valid ? result[@"lifetime"] : nil;
                if (lifetime && !NSDNSLifetimeIsLive(lifetime, NSProcessInfo.processInfo.systemUptime,
                                                     NSBootSessionIdentifier())) {
                    valid = NO;
                }
                NSUInteger failures = valid ? 0 : MIN(5, [owner.failures[key] unsignedIntegerValue] + 1);
                owner.failures[key] = @(failures);
                double jitter = 0.8 + (key.hash % 41) / 100.0;
                NSTimeInterval ttl =
                    !valid
                        ? 0
                        : (lifetime ? [lifetime[@"expires"] doubleValue] - [lifetime[@"issued"] doubleValue]
                                    : [result[@"expires"] timeIntervalSinceNow]);
                NSTimeInterval delay =
                    valid ? MIN(60, MAX(1, ttl / 2)) : MIN(60, 5 * (1u << (failures - 1))) * jitter;
                [owner scheduleRetryForKey:key at:owner.clock() + delay];
                if ([owner.rules[key] isEqual:rule] && owner.completion) {
                    NSMutableDictionary *tagged = valid ? [result mutableCopy] : nil;
                    tagged[@"generation"] = generation;
                    owner.completion(
                        key, rule, tagged,
                        valid ? error : (error ?: NSDNSError(3, @"DNS operation returned no valid result.")));
                }
                [owner pump];
            });
        };
        id<NSDNSOperation> operation = self.lookup(key, self.queue, finished);
        if (operation) {
            self.active[key] = operation;
        } else {
            finished(nil, NSDNSError(4, @"DNS operation could not be allocated."));
        }
    }
    NSUInteger backlog = [self backlogAt:now];
    @synchronized(self) {
        self.coverageStatus =
            backlog ? [NSString
                          stringWithFormat:
                              @"%lu domain refreshes waiting; DNS-derived block coverage may be incomplete.",
                              (unsigned long)backlog]
                    : @"";
    }
}
- (void)invalidateNetwork {
    [self invalidateNetworkWithCompletion:nil];
}
- (void)invalidateNetworkWithCompletion:(void (^)(void))completion {
    dispatch_async(self.queue, ^{
        if (self.stopped) {
            return;
        }
        for (id<NSDNSOperation> operation in self.active.allValues) {
            [operation cancel];
        }
        [self.active removeAllObjects];
        [self.lookupIDs removeAllObjects];
        [self.nextAttempt removeAllObjects];
        [self.failures removeAllObjects];
        [self rebuildSchedule];
        if (completion) {
            completion();
        }
        [self pump];
    });
}
- (void)stop {
    [self stopWithCompletion:nil];
}
- (void)stopWithCompletion:(void (^)(void))completion {
    dispatch_async(self.queue, ^{
        self.stopped = YES;
        self.completion = nil;
        for (id<NSDNSOperation> lookup in self.active.allValues) {
            [lookup cancel];
        }
        [self.active removeAllObjects];
        [self.lookupIDs removeAllObjects];
        [self.nextAttempt removeAllObjects];
        self.rules = @{};
        [self.unstartedKeys removeAllObjects];
        [self.retryKeys removeAllObjects];
        [self.failures removeAllObjects];
        if (completion) {
            completion();
        }
    });
}
- (void)dealloc {
    NSArray *operations = [self.active.allValues copy];
    if (operations.count) {
        dispatch_async(_queue, ^{
            for (id<NSDNSOperation> operation in operations) {
                [operation cancel];
            }
        });
    }
}
@end
