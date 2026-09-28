#import "NSPermissionQueue.h"
#import "NSConstants.h"

@interface NSPermissionWaiter : NSObject
@property(nonatomic) NSFlowDirection direction;
@property(nonatomic, copy) void (^completion)(BOOL);
@end
@implementation NSPermissionWaiter
@end

@interface NSPermissionEntry : NSObject
@property(nonatomic, copy) NSString *identity;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, strong) NSDate *created;
@property(nonatomic) NSTimeInterval deadline;
@property(nonatomic) BOOL expired;
@property(nonatomic, strong) NSMutableArray<NSPermissionWaiter *> *waiters;
- (NSDictionary *)document;
@end
@implementation NSPermissionEntry
- (NSDictionary *)document {
    return @{
        @"token" : self.token,
        @"identity" : self.identity,
        @"created" : self.created,
        @"expires" : [self.created dateByAddingTimeInterval:NSPermissionTimeout],
        @"waiting" : @(self.waiters.count),
        @"expired" : @(self.expired)
    };
}
@end

@interface NSPermissionQueue ()
@property(nonatomic, strong) NSMutableArray<NSPermissionEntry *> *active;
@property(nonatomic, strong) NSMutableArray<NSPermissionEntry *> *history;
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
        waiter.completion(NO);
    }
}
- (NSDictionary *)enqueueIdentity:(NSString *)identity
                        direction:(NSFlowDirection)direction
                              now:(NSTimeInterval)now
                             date:(NSDate *)date
                       completion:(void (^)(BOOL))completion {
    [self expireAtTime:now];
    if (!identity.length || identity.length > NSMaximumIdentityLength) {
        completion(NO);
        return nil;
    }
    // Retain the decision prompt after timeout, without holding a connection open.
    for (NSPermissionEntry *old in self.history) {
        if ([old.identity isEqual:identity]) {
            completion(NO);
            return nil;
        }
    }
    NSPermissionEntry *entry = nil;
    for (NSPermissionEntry *candidate in self.active) {
        if ([candidate.identity isEqual:identity]) {
            entry = candidate;
            break;
        }
    }
    if ((!entry && self.active.count >= NSMaximumActiveRequests) ||
        entry.waiters.count >= NSMaximumWaitersPerIdentity || self.waitingCount >= NSMaximumWaiters) {
        self.overflowCount++;
        completion(NO);
        return nil;
    }
    BOOL created = !entry;
    if (created) {
        entry = [NSPermissionEntry new];
        entry.identity = identity;
        entry.token = NSUUID.UUID.UUIDString;
        entry.created = date;
        entry.deadline = now + NSPermissionTimeout;
        entry.waiters = [NSMutableArray new];
        [self.active addObject:entry];
    }
    NSPermissionWaiter *waiter = [NSPermissionWaiter new];
    waiter.direction = direction;
    waiter.completion = completion;
    [entry.waiters addObject:waiter];
    return created ? entry.document : nil;
}
- (void)resolveWithPolicy:(NSPolicy *)policy now:(NSTimeInterval)now {
    [self expireAtTime:now];
    NSMutableArray<void (^)(void)> *callbacks = [NSMutableArray new];
    for (NSPermissionEntry *entry in [self.active copy]) {
        if (policy && [policy requiresPermissionForIdentity:entry.identity]) {
            continue;
        }
        [self.active removeObject:entry];
        for (NSPermissionWaiter *waiter in entry.waiters) {
            BOOL allow = policy && [policy allowsIdentity:entry.identity direction:waiter.direction];
            [callbacks addObject:[^{
                           waiter.completion(allow);
                       } copy]];
        }
        [entry.waiters removeAllObjects];
    }
    for (NSPermissionEntry *entry in [self.history copy]) {
        if (!policy || ![policy requiresPermissionForIdentity:entry.identity]) {
            [self.history removeObject:entry];
        }
    }
    for (void (^callback)(void) in callbacks) {
        callback();
    }
}
- (void)cancelAll {
    NSArray<NSPermissionEntry *> *entries = [self.active copy];
    [self.active removeAllObjects];
    [self.history removeAllObjects];
    for (NSPermissionEntry *entry in entries) {
        NSArray<NSPermissionWaiter *> *waiters = [entry.waiters copy];
        [entry.waiters removeAllObjects];
        for (NSPermissionWaiter *waiter in waiters) {
            waiter.completion(NO);
        }
    }
}
@end
