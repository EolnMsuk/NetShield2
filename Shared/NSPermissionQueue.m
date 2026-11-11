#import "NSPermissionQueue.h"
#import "NSConstants.h"
#import "NSPermissionRequest.h"

@interface NSPermissionWaiter : NSObject
@property(nonatomic) NSFlowDirection direction;
@property(nonatomic, copy) NSDictionary *destination;
@property(nonatomic, copy) void (^completion)(NSPermissionResult);
@end
@implementation NSPermissionWaiter
@end

@interface NSPermissionEntry : NSObject
@property(nonatomic) NSFlowDirection direction;
@property(nonatomic, copy) NSString *identity;
@property(nonatomic, copy) NSDictionary *destination;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, copy) NSString *askGeneration;
@property(nonatomic, copy) NSString *fingerprint;
@property(nonatomic, copy) NSString *flow;
@property(nonatomic) BOOL deferred;
@property(nonatomic, strong) NSDate *created;
@property(nonatomic) NSTimeInterval deadline;
@property(nonatomic) BOOL expired;
@property(nonatomic, strong) NSMutableArray<NSPermissionWaiter *> *waiters;
- (NSDictionary *)document;
@end
@implementation NSPermissionEntry
- (NSDictionary *)document {
    NSMutableDictionary *document = [@{
        @"token" : self.token,
        @"askGeneration" : self.askGeneration ?: @"",
        @"identity" : self.identity,
        @"destination" : self.destination ?: @{},
        @"direction" : NSPermissionDirectionName(self.direction),
        @"created" : self.created,
        @"expires" : [self.created dateByAddingTimeInterval:NSPermissionTimeout],
        @"waiting" : @(self.waiters.count),
        @"expired" : @(self.expired)
    } mutableCopy];
    if (self.fingerprint) {
        document[@"kind"] = @"unidentified";
        document[@"fingerprint"] = self.fingerprint;
        document[@"mode"] = self.flow ? @"once" : @"rule";
        document[@"flow"] = self.flow;
        document[@"deferred"] = @(self.deferred);
    }
    return [document copy];
}
@end

@interface NSPermissionQueue ()
@property(nonatomic, strong) NSMutableArray<NSPermissionEntry *> *active;
@property(nonatomic, strong) NSMutableArray<NSPermissionEntry *> *history;
@property(nonatomic, strong) NSPolicy *policy;
@property(nonatomic, readwrite) NSUInteger overflowCount;
@property(nonatomic, readwrite) NSUInteger evictedRequestCount;
@end

@implementation NSPermissionQueue
- (instancetype)init {
    if ((self = [super init])) {
        _active = [NSMutableArray new];
        _history = [NSMutableArray new];
    }
    return self;
}
- (NSUInteger)waitingCount {
    NSUInteger count = 0;
    for (NSPermissionEntry *entry in self.active) {
        count += entry.waiters.count;
    }
    return count;
}
- (NSArray<NSDictionary *> *)requests {
    NSMutableArray *result = [NSMutableArray new];
    for (NSPermissionEntry *entry in [self.active arrayByAddingObjectsFromArray:self.history]) {
        [result addObject:entry.document];
    }
    return result;
}
- (void)trimHistory {
    while (self.history.count > NSMaximumRequestHistory) {
        [self.history removeObjectAtIndex:0];
        self.evictedRequestCount++;
    }
}
- (void)expireAtTime:(NSTimeInterval)now {
    NSMutableArray<NSPermissionWaiter *> *finished = [NSMutableArray new];
    for (NSPermissionEntry *entry in [self.active copy]) {
        if (now < entry.deadline) {
            continue;
        }
        [finished addObjectsFromArray:entry.waiters];
        [entry.waiters removeAllObjects];
        entry.expired = YES;
        [self.active removeObject:entry];
        [self.history addObject:entry];
    }
    [self trimHistory];
    for (NSPermissionWaiter *waiter in finished) {
        waiter.completion(NSPermissionBlocked);
    }
}
- (NSDictionary *)enqueueIdentity:(NSString *)identity
                        direction:(NSFlowDirection)direction
                              now:(NSTimeInterval)now
                             date:(NSDate *)date
                       completion:(void (^)(BOOL))completion {
    return [self enqueueIdentity:identity
                       direction:direction
                     destination:@{}
                             now:now
                            date:date
                      completion:completion];
}
- (NSDictionary *)enqueueIdentity:(NSString *)identity
                        direction:(NSFlowDirection)direction
                      destination:(NSDictionary *)destination
                              now:(NSTimeInterval)now
                             date:(NSDate *)date
                       completion:(void (^)(BOOL))completion {
    return [self
        enqueueIdentity:identity
              direction:direction
            destination:destination
                   flow:@""
                    now:now
                   date:date
                 result:^(NSPermissionResult result) {
                     completion(result == NSPermissionAllowedByPolicy || result == NSPermissionAllowedOnce);
                 }];
}
- (NSDictionary *)enqueueIdentity:(NSString *)identity
                        direction:(NSFlowDirection)direction
                      destination:(NSDictionary *)destination
                             flow:(NSString *)flow
                              now:(NSTimeInterval)now
                             date:(NSDate *)date
                           result:(void (^)(NSPermissionResult))completion {
    [self expireAtTime:now];
    identity = identity ?: @"";
    if (identity.length > NSMaximumIdentityLength ||
        (!identity.length && ![self.policy.document[@"unattributed"] isEqual:@"ask"])) {
        completion(NSPermissionBlocked);
        return nil;
    }
    direction = NSNormalizedFlowDirection(direction);
    NSString *generation = NSPermissionGeneration(self.policy, identity);
    NSString *fingerprint = nil;
    BOOL once = NO;
    if (!identity.length) {
        destination = NSCanonicalConnectionDestination(destination);
        NSString *name = NSPermissionDirectionName(direction);
        fingerprint = NSConnectionFingerprint(destination, name);
        once = !NSConnectionHasConditions(destination, name);
    }
    BOOL (^sameGroup)(NSPermissionEntry *) = ^BOOL(NSPermissionEntry *candidate) {
        return !once && [candidate.identity isEqual:identity] &&
               [candidate.askGeneration isEqual:generation] &&
               (!fingerprint || [candidate.fingerprint isEqual:fingerprint]);
    };
    for (NSPermissionEntry *old in self.history) {
        if (sameGroup(old)) {
            completion(NSPermissionBlocked);
            return nil;
        }
    }
    NSPermissionEntry *entry = nil;
    for (NSPermissionEntry *candidate in self.active) {
        if (sameGroup(candidate)) {
            entry = candidate;
            break;
        }
    }
    if ((!entry && self.active.count >= NSMaximumActiveRequests) ||
        entry.waiters.count >= NSMaximumWaitersPerIdentity || self.waitingCount >= NSMaximumWaiters) {
        self.overflowCount++;
        completion(NSPermissionBlocked);
        return nil;
    }
    BOOL created = !entry;
    if (created) {
        entry = [NSPermissionEntry new];
        entry.identity = identity;
        entry.destination = [destination copy];
        entry.direction = direction;
        entry.token = NSUUID.UUID.UUIDString;
        entry.askGeneration = generation;
        entry.fingerprint = fingerprint;
        // An empty OS flow identifier is valid. The token still binds exactly one waiter.
        entry.flow = once ? (flow.length <= 128 ? flow ?: @"" : @"") : nil;
        entry.created = date;
        entry.deadline = now + NSPermissionTimeout;
        entry.waiters = [NSMutableArray new];
        [self.active addObject:entry];
    }
    NSPermissionWaiter *waiter = [NSPermissionWaiter new];
    waiter.direction = direction;
    waiter.destination = [destination copy];
    waiter.completion = completion;
    [entry.waiters addObject:waiter];
    return created ? entry.document : nil;
}
- (void)resolveWithPolicy:(NSPolicy *)policy now:(NSTimeInterval)now {
    self.policy = policy;
    NSMutableArray *replaced = [NSMutableArray new];
    for (NSPermissionEntry *entry in [self.active arrayByAddingObjectsFromArray:self.history]) {
        if (![entry.askGeneration isEqual:NSPermissionGeneration(policy, entry.identity)]) {
            [replaced addObjectsFromArray:entry.waiters];
            [entry.waiters removeAllObjects];
            [self.active removeObject:entry];
            [self.history removeObject:entry];
        }
    }
    for (NSPermissionWaiter *waiter in replaced) {
        waiter.completion(NSPermissionBlocked);
    }
    [self expireAtTime:now];
    NSMutableArray<void (^)(void)> *callbacks = [NSMutableArray new];
    for (NSPermissionEntry *entry in [self.active copy]) {
        for (NSPermissionWaiter *waiter in [entry.waiters copy]) {
            if (policy && [policy requiresPermissionForIdentity:entry.identity
                                                      direction:waiter.direction
                                                    destination:waiter.destination]) {
                continue;
            }
            [entry.waiters removeObject:waiter];
            BOOL allow = policy && [policy allowsIdentity:entry.identity
                                                direction:waiter.direction
                                              destination:waiter.destination];
            [callbacks addObject:[^{
                           waiter.completion(allow ? NSPermissionAllowedByPolicy : NSPermissionBlocked);
                       } copy]];
        }
        if (!entry.waiters.count) {
            [self.active removeObject:entry];
        } else if (entry.identity.length) {
            NSPermissionWaiter *first = entry.waiters.firstObject;
            if (entry.direction != first.direction || ![entry.destination isEqual:first.destination]) {
                entry.token = NSUUID.UUID.UUIDString;
                entry.destination = first.destination;
                entry.direction = first.direction;
            }
        }
    }
    for (NSPermissionEntry *entry in [self.history copy]) {
        if (!policy || ![policy requiresPermissionForIdentity:entry.identity
                                                    direction:entry.direction
                                                  destination:entry.destination ?: @{}]) {
            [self.history removeObject:entry];
        }
    }
    for (void (^callback)(void) in callbacks) {
        callback();
    }
}
- (dispatch_block_t)takeResponse:(NSDictionary *)response policy:(NSPolicy *)policy now:(NSTimeInterval)now {
    NSString *action = response[@"action"];
    BOOL defer = [action isEqual:@"defer"];
    NSArray *entries = defer ? [self.active arrayByAddingObjectsFromArray:self.history] : self.active;
    for (NSPermissionEntry *entry in entries) {
        if (![entry.token isEqual:response[@"token"]]) {
            continue;
        }
        NSDictionary *request = entry.document;
        if (!entry.fingerprint || (!defer && now >= entry.deadline) ||
            ![entry.askGeneration isEqual:NSPermissionGeneration(policy, entry.identity)] ||
            ![policy requiresPermissionForRequest:request]) {
            return nil;
        }
        for (NSString *key in
             @[ @"kind", @"fingerprint", @"direction", @"mode", @"askGeneration", @"expires", @"flow" ]) {
            if (![(request[key] ?: @"") isEqual:(response[key] ?: @"")]) {
                return nil;
            }
        }
        if (defer) {
            entry.deferred = YES;
            return nil;
        }
        if (!entry.flow || entry.waiters.count != 1 || ![@[ @"allow", @"block" ] containsObject:action]) {
            return nil;
        }
        NSPermissionWaiter *waiter = entry.waiters.firstObject;
        [entry.waiters removeAllObjects];
        [self.active removeObject:entry];
        NSPermissionResult result =
            [action isEqual:@"allow"] ? NSPermissionAllowedOnce : NSPermissionBlockedOnce;
        return ^{
            waiter.completion(result);
        };
    }
    return nil;
}
- (void)cancelAll {
    NSArray<NSPermissionEntry *> *entries = [self.active copy];
    [self.active removeAllObjects];
    [self.history removeAllObjects];
    for (NSPermissionEntry *entry in entries) {
        NSArray<NSPermissionWaiter *> *waiters = [entry.waiters copy];
        [entry.waiters removeAllObjects];
        for (NSPermissionWaiter *waiter in waiters) {
            waiter.completion(NSPermissionBlocked);
        }
    }
}
@end
