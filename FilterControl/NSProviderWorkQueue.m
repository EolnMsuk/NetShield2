#import "NSProviderWorkQueue.h"
@implementation NSProviderWorkQueue {
    NSUInteger _capacity;
    NSUInteger _pending;
    NSUInteger _rejected;
    dispatch_queue_t _queue;
}
- (instancetype)initWithCapacity:(NSUInteger)capacity {
    if ((self = [super init])) {
        _capacity = capacity;
        _queue = dispatch_queue_create("com.eolnmsuk.netshield.control.state", DISPATCH_QUEUE_SERIAL);
        if (!_queue) {
            return nil;
        }
    }
    return self;
}
- (dispatch_queue_t)queue {
    return _queue;
}
- (NSUInteger)rejectedCount {
    @synchronized(self) {
        return _rejected;
    }
}
- (BOOL)submit:(void (^)(void))work {
    @synchronized(self) {
        if (_pending >= _capacity) {
            if (_rejected < NSUIntegerMax) {
                _rejected++;
            }
            return NO;
        }
        _pending++;
    }
    dispatch_async(_queue, ^{
        @try {
            work();
        } @finally {
            @synchronized(self) {
                self->_pending--;
            }
        }
    });
    return YES;
}
@end

@interface NSProviderReplyGate ()
@property(nonatomic) NSUInteger capacity;
@property(nonatomic) NSUInteger pending;
@property(nonatomic) NSUInteger rejected;
@property(nonatomic, strong) dispatch_queue_t delivery;
@end
@interface NSProviderReply ()
@property(nonatomic, strong) NSProviderReplyGate *gate;
@property(nonatomic, copy) void (^completion)(id);
@end
@implementation NSProviderReply
- (void)complete:(id)result {
    void (^completion)(id);
    @synchronized(self) {
        completion = self.completion;
        self.completion = nil;
    }
    if (!completion) {
        return;
    }
    NSProviderReplyGate *gate = self.gate;
    self.gate = nil;
    dispatch_async(gate.delivery, ^{
        @try {
            completion(result);
        } @finally {
            @synchronized(gate) {
                gate.pending--;
            }
        }
    });
}
@end
@implementation NSProviderReplyGate
- (instancetype)initWithCapacity:(NSUInteger)capacity delivery:(dispatch_queue_t)delivery {
    if ((self = [super init])) {
        _capacity = capacity;
        _delivery = delivery;
    }
    return self;
}
- (NSUInteger)rejectedCount {
    @synchronized(self) {
        return self.rejected;
    }
}
- (NSProviderReply *)admit:(void (^)(id))completion {
    @synchronized(self) {
        if (self.pending >= self.capacity) {
            if (self.rejected < NSUIntegerMax) {
                self.rejected++;
            }
            return nil;
        }
        self.pending++;
    }
    NSProviderReply *reply = [NSProviderReply new];
    reply.gate = self;
    reply.completion = completion;
    return reply;
}
@end
