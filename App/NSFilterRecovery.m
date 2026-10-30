#import "NSFilterRecovery.h"

@interface NSFilterRecovery ()
@property(nonatomic, readwrite) BOOL busy;
@property(nonatomic) BOOL uncertain;
@property(nonatomic) NSUInteger step;
@property(nonatomic) NSUInteger request;
@property(nonatomic, copy) NSString *operation;
@property(nonatomic, copy) NSDictionary *evidence;
@property(nonatomic, copy) NSDictionary *before;
@property(nonatomic, copy) NSDictionary *lastLoaded;
@property(nonatomic, strong) NSMutableArray *events;
@property(nonatomic, copy) void (^completion)(NSDictionary *);
@property(nonatomic) NSTimeInterval started;
@end

@implementation NSFilterRecovery
- (instancetype)init {
    if ((self = [super init])) {
        _timeout = 20;
        _schedule = ^(NSTimeInterval delay, void (^work)(void)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), work);
        };
    }
    return self;
}
- (void)event:(NSString *)phase error:(NSError *)error {
    NSMutableDictionary *event =
        [@{@"phase" : phase, @"elapsed" : @(NSProcessInfo.processInfo.systemUptime - self.started)}
            mutableCopy];
    if (error) {
        event[@"error"] =
            @{@"domain" : error.domain, @"code" : @(error.code), @"description" : error.localizedDescription};
    }
    [self.events addObject:event];
}
- (void)finish:(NSString *)status {
    if (!self.completion) {
        return;
    }
    NSDictionary *result = @{
        @"operation" : self.operation,
        @"status" : status,
        @"before" : self.before ?: @{},
        @"lastSuccessfulLoad" : self.lastLoaded ?: @{},
        @"managerMemoryOnly" : self.snapshot(),
        @"persistedResultVerified" : @(
            [@[ @"disabledVerified", @"alreadyDisabledVerified", @"removedVerified" ] containsObject:status]),
        @"events" : self.events.copy,
        @"elapsed" : @(NSProcessInfo.processInfo.systemUptime - self.started)
    };
    void (^completion)(NSDictionary *) = self.completion;
    self.completion = nil;
    self.step++;
    self.busy = self.uncertain;
    completion(result);
}
- (BOOL)matchesEvidence:(NSDictionary *)snapshot {
    return [snapshot[@"present"] boolValue] && self.evidence.count &&
           [snapshot[@"fingerprint"] isEqual:self.evidence];
}
- (NSString *)failure:(NSError *)error fallback:(NSString *)fallback {
    // Preserve the actual NSError as well as this summary. Do not retry writes.
    return [error.domain isEqual:@"NEFilterErrorDomain"] && error.code == 5 ? @"permissionDenied" : fallback;
}
- (void)perform:(NSString *)operation
       evidence:(NSDictionary *)fingerprint
     completion:(void (^)(NSDictionary *))completion {
    NSAssert(NSThread.isMainThread, @"Recovery belongs to the main queue");
    if (self.busy) {
        completion(@{@"operation" : operation, @"status" : self.uncertain ? @"busyUncertain" : @"busy"});
        return;
    }
    self.busy = YES;
    self.operation = operation;
    self.evidence = fingerprint;
    self.before = nil;
    self.lastLoaded = nil;
    self.events = [NSMutableArray new];
    self.started = NSProcessInfo.processInfo.systemUptime;
    self.completion = completion;
    // A timeout cannot cancel an NE request. Quarantine this instance rather
    // than race a late write with a second operation in this process.
    __weak typeof(self) weakSelf = self;
    NSUInteger request = ++self.request;
    self.schedule(self.timeout, ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf.completion && strongSelf.request == request) {
            strongSelf.uncertain = YES;
            [strongSelf event:@"deadline; request may still complete" error:nil];
            [strongSelf finish:@"timedOut"];
        }
    });
    [self loadInitial];
}
- (void)loadInitial {
    NSUInteger step = ++self.step;
    [self.manager loadFromPreferencesWithCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.completion || step != self.step) {
                return;
            }
            self.step++;
            [self event:@"load" error:error];
            if (error) {
                [self finish:[self failure:error fallback:@"inaccessible"]];
                return;
            }
            self.before = self.snapshot();
            self.lastLoaded = self.before;
            if (![self.before[@"present"] boolValue]) {
                [self finish:@"noVisibleConfiguration"];
                return;
            }
            if (![self matchesEvidence:self.before]) {
                [self finish:@"ownershipUnverified"];
                return;
            }
            if ([self.operation isEqual:@"status"]) {
                [self finish:@"foundRecordedConfiguration"];
                return;
            }
            if ([self.operation isEqual:@"disable"]) {
                if (![self.before[@"enabled"] boolValue]) {
                    [self verify];
                } else {
                    // Only this property changes. Never synthesize a provider.
                    self.manager.enabled = NO;
                    [self write:NO];
                }
            } else if ([self.operation isEqual:@"remove"]) {
                [self write:YES];
            } else {
                [self finish:@"invalidOperation"];
            }
        });
    }];
}
- (void)write:(BOOL)remove {
    NSUInteger step = ++self.step;
    void (^saved)(NSError *) = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.completion || step != self.step) {
                return;
            }
            self.step++;
            [self event:remove ? @"remove callback" : @"save callback" error:error];
            if (error) {
                [self finish:[self failure:error fallback:remove ? @"cannotRemove" : @"saveFailed"]];
            } else {
                [self verify];
            }
        });
    };
    if (remove) {
        [self.manager removeFromPreferencesWithCompletionHandler:saved];
    } else {
        [self.manager saveToPreferencesWithCompletionHandler:saved];
    }
}
- (void)verify {
    NSUInteger step = ++self.step;
    [self.manager loadFromPreferencesWithCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.completion || step != self.step) {
                return;
            }
            self.step++;
            [self event:@"fresh verification load" error:error];
            if (error) {
                [self finish:[self failure:error fallback:@"verificationFailed"]];
                return;
            }
            NSDictionary *after = self.snapshot();
            self.lastLoaded = after;
            if ([self.operation isEqual:@"remove"]) {
                [self finish:![after[@"present"] boolValue] && ![after[@"enabled"] boolValue]
                                 ? @"removedVerified"
                                 : @"verificationFailed"];
            } else if (![self matchesEvidence:after] || [after[@"enabled"] boolValue]) {
                [self finish:@"verificationFailed"];
            } else {
                [self finish:[self.before[@"enabled"] boolValue] ? @"disabledVerified"
                                                                 : @"alreadyDisabledVerified"];
            }
        });
    }];
}
@end
