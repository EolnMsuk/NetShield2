#import "NSPermissionQueue.h"

@interface NSPermissionEntry : NSObject
@property(nonatomic, copy) NSString *identity;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, strong) NSDate *created;
@property(nonatomic) NSTimeInterval deadline;
@property(nonatomic) BOOL expired;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *waiters;
@end
@implementation NSPermissionEntry
@end

@interface NSPermissionQueue ()
@property(nonatomic, strong) NSMutableArray<NSPermissionEntry *> *entries;
@end

@implementation NSPermissionQueue
- (instancetype)init {
    if ((self = [super init])) _entries = [NSMutableArray new];
    return self;
}
- (NSUInteger)waitingCount {
    NSUInteger count = 0;
    for (NSPermissionEntry *entry in self.entries) count += entry.waiters.count;
    return count;
}
- (NSArray<NSDictionary *> *)requests {
    NSMutableArray *result = [NSMutableArray new];
    for (NSPermissionEntry *entry in self.entries) {
        [result addObject:@{@"token": entry.token, @"identity": entry.identity,
            @"created": entry.created, @"expires": [entry.created dateByAddingTimeInterval:30],
            @"waiting": @(entry.waiters.count), @"expired": @(entry.expired)}];
    }
    return result;
}
- (NSDictionary *)enqueueIdentity:(NSString *)identity direction:(NSFlowDirection)direction
                               now:(NSTimeInterval)now date:(NSDate *)date completion:(void (^)(BOOL))completion {
    if (!identity.length || identity.length > 1024) { completion(NO); return nil; }
    NSPermissionEntry *entry = nil;
    for (NSPermissionEntry *candidate in self.entries) {
        if ([candidate.identity isEqual:identity]) { entry = candidate; break; }
    }
    BOOL created = entry == nil;
    if (!entry) {
        if (self.entries.count >= 64 || self.waitingCount >= 256) { completion(NO); return nil; }
        entry = [NSPermissionEntry new];
        entry.identity = identity;
        entry.token = NSUUID.UUID.UUIDString;
        entry.created = date;
        entry.deadline = now + 30;
        entry.waiters = [NSMutableArray new];
        [self.entries addObject:entry];
    }
    if (entry.expired || now >= entry.deadline || entry.waiters.count >= 16 || self.waitingCount >= 256) {
        completion(NO);
        return nil;
    }
    [entry.waiters addObject:@{@"direction": @(direction), @"completion": [completion copy]}];
    if (!created) return nil;
    return self.requests.lastObject;
}
- (void)resolveWithPolicy:(NSPolicy *)policy now:(NSTimeInterval)now {
    NSMutableArray *callbacks = [NSMutableArray new];
    for (NSPermissionEntry *entry in [self.entries copy]) {
        BOOL resolved = !policy || ![policy requiresPermissionForIdentity:entry.identity];
        if (!resolved && now < entry.deadline) continue;
        BOOL timedOut = now >= entry.deadline;
        for (NSDictionary *waiter in entry.waiters) {
            BOOL allow = !timedOut && policy && resolved && [policy allowsIdentity:entry.identity direction:[waiter[@"direction"] integerValue]];
            [callbacks addObject:@{@"completion": waiter[@"completion"], @"allow": @(allow)}];
        }
        [entry.waiters removeAllObjects];
        entry.expired = YES;
        if (resolved) [self.entries removeObject:entry];
    }
    for (NSDictionary *callback in callbacks) {
        void (^finish)(BOOL) = callback[@"completion"];
        finish([callback[@"allow"] boolValue]);
    }
}
- (void)cancelAll {
    NSArray *entries = [self.entries copy];
    [self.entries removeAllObjects];
    for (NSPermissionEntry *entry in entries) {
        for (NSDictionary *waiter in entry.waiters) {
            void (^finish)(BOOL) = waiter[@"completion"];
            finish(NO);
        }
    }
}
@end
