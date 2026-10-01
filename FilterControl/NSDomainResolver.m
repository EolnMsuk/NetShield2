#import "NSDomainResolver.h"
#import "../Shared/NSGlobalRule.h"
#include <dns_sd.h>
#include <netinet/in.h>

@interface NSDNSLookup : NSObject <NSDNSOperation>
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, strong) NSMutableArray<NSValue *> *references;
@property(nonatomic, strong) NSMutableOrderedSet<NSString *> *addresses;
@property(nonatomic, strong) NSMutableSet *answers;
@property(nonatomic, strong) NSDate *expires;
@property(nonatomic, copy) void (^completion)(NSDictionary *, NSError *);
- (void)cancel;
@end

static void NSDNSAnswer(DNSServiceRef reference, DNSServiceFlags flags, uint32_t interface,
                        DNSServiceErrorType error, const char *host, const struct sockaddr *address,
                        uint32_t ttl, void *context) {
    NSDNSLookup *lookup = (__bridge NSDNSLookup *)context;
    if (!lookup.completion) {
        return;
    }
    if (error != kDNSServiceErr_NoError) {
        return;
    }
    if (!address) {
        return;
    }
    [lookup.answers addObject:@[ [NSValue valueWithPointer:reference], @(address->sa_family) ]];
    char text[INET6_ADDRSTRLEN];
    const void *bytes =
        address->sa_family == AF_INET    ? (const void *)&((const struct sockaddr_in *)address)->sin_addr
        : address->sa_family == AF_INET6 ? (const void *)&((const struct sockaddr_in6 *)address)->sin6_addr
                                         : NULL;
    if (!bytes || !inet_ntop(address->sa_family, bytes, text, sizeof(text))) {
        return;
    }
    NSString *key = NSGlobalHostKey(@(text));
    if (!(flags & kDNSServiceFlagsAdd) || ttl == 0) {
        [lookup.addresses removeObject:key];
    } else {
        if (lookup.addresses.count < 128) {
            [lookup.addresses addObject:key];
        }
        NSDate *expires = [NSDate dateWithTimeIntervalSinceNow:MIN(300, ttl)];
        if ([expires compare:lookup.expires] == NSOrderedAscending) {
            lookup.expires = expires;
        }
    }
}

@implementation NSDNSLookup
- (instancetype)initWithKey:(NSString *)key
                      queue:(dispatch_queue_t)queue
                 completion:(void (^)(NSDictionary *, NSError *))completion {
    if ((self = [super init])) {
        _queue = queue;
        _references = [NSMutableArray new];
        _addresses = [NSMutableOrderedSet new];
        _answers = [NSMutableSet new];
        _expires = [NSDate dateWithTimeIntervalSinceNow:300];
        _completion = completion;
        for (NSString *host in NSGlobalDomainAliases(key)) {
            DNSServiceRef reference = NULL;
            DNSServiceErrorType error =
                DNSServiceGetAddrInfo(&reference, 0, 0, kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6,
                                      host.UTF8String, NSDNSAnswer, (__bridge void *)self);
            if (!error) {
                error = DNSServiceSetDispatchQueue(reference, queue);
            }
            if (error) {
                if (reference) {
                    DNSServiceRefDeallocate(reference);
                }
            } else {
                [_references addObject:[NSValue valueWithPointer:reference]];
            }
        }
        _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                                  DISPATCH_TIME_FOREVER, NSEC_PER_MSEC * 50);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(_timer, ^{
            NSDNSLookup *owner = weakSelf;
            if (!owner) {
                return;
            }
            void (^finished)(NSDictionary *, NSError *) = owner.completion;
            BOOL answered =
                owner.addresses.count || (owner.references.count == 2 && owner.answers.count == 4);
            BOOL live = owner.expires.timeIntervalSinceNow > 0;
            NSDictionary *result = answered ? @{
                @"addresses" : live ? owner.addresses.array : @[],
                @"expires" : live ? owner.expires : [NSDate dateWithTimeIntervalSinceNow:2],
                @"source" : @"dns"
            }
                                            : nil;
            [owner cancel];
            if (finished) {
                finished(result, answered ? nil
                                          : [NSError errorWithDomain:@"NetShield2.DNS"
                                                                code:1
                                                            userInfo:@{
                                                                NSLocalizedDescriptionKey :
                                                                    @"DNS lookup timed out or failed; "
                                                                    @"previous answers expire normally."
                                                            }]);
            }
        });
        dispatch_resume(_timer);
    }
    return self;
}
- (void)cancel {
    self.completion = nil;
    if (self.timer) {
        dispatch_source_cancel(self.timer);
        self.timer = nil;
    }
    for (NSValue *value in self.references) {
        DNSServiceRefDeallocate(value.pointerValue);
    }
    [self.references removeAllObjects];
}
@end

@interface NSDomainResolver ()
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSDictionary *rules;
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
        _queue = queue;
        _clock = clock;
        _lookup = lookup;
        _active = [NSMutableDictionary new];
        _lookupIDs = [NSMutableDictionary new];
        _nextAttempt = [NSMutableDictionary new];
        _completion = completion;
    }
    return self;
}
- (void)refreshRules:(NSDictionary *)rules {
    dispatch_async(self.queue, ^{
        if (self.stopped) {
            return;
        }
        NSMutableDictionary *wanted = [NSMutableDictionary new];
        for (NSString *key in rules) {
            if ([key hasPrefix:@"domain:"] && ![rules[key] isEqual:@"allow"]) {
                wanted[key] = rules[key];
            }
        }
        for (NSString *key in self.rules) {
            if (![wanted[key] isEqual:self.rules[key]]) {
                [self.active[key] cancel];
                [self.active removeObjectForKey:key];
                [self.lookupIDs removeObjectForKey:key];
                [self.nextAttempt removeObjectForKey:key];
            }
        }
        self.rules = wanted;
        [self pump];
    });
}
- (void)pump {
    NSTimeInterval now = self.clock();
    NSArray *keys =
        [self.rules.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
            return [(self.nextAttempt[left] ?: @0) compare:(self.nextAttempt[right] ?: @0)];
        }];
    for (NSString *key in keys) {
        if (self.active.count >= 4) {
            break;
        }
        if (self.active[key] || [self.nextAttempt[key] doubleValue] > now) {
            continue;
        }
        NSString *rule = self.rules[key];
        NSString *lookupID = NSUUID.UUID.UUIDString;
        self.lookupIDs[key] = lookupID;
        __weak typeof(self) weakSelf = self;
        id<NSDNSOperation> lookup = self.lookup(key, self.queue, ^(NSDictionary *result, NSError *error) {
            NSDomainResolver *owner = weakSelf;
            if (!owner || owner.stopped || ![owner.lookupIDs[key] isEqual:lookupID]) {
                return;
            }
            [owner.active removeObjectForKey:key];
            [owner.lookupIDs removeObjectForKey:key];
            NSTimeInterval delay =
                result ? MIN(60, MAX(1, [result[@"expires"] timeIntervalSinceNow] / 2)) : 5;
            owner.nextAttempt[key] = @(owner.clock() + delay);
            if ([owner.rules[key] isEqual:rule] && owner.completion) {
                owner.completion(key, rule, result, error);
            }
            [owner pump];
        });
        self.active[key] = lookup;
    }
}
- (void)stop {
    dispatch_async(self.queue, ^{
        self.stopped = YES;
        self.completion = nil;
        for (id<NSDNSOperation> lookup in self.active.allValues) {
            [lookup cancel];
        }
        [self.active removeAllObjects];
        [self.lookupIDs removeAllObjects];
    });
}
@end
