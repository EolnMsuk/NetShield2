#import <Foundation/Foundation.h>
// Bounded admission in front of the provider's serial state queue. The short
// admission monitor never invokes caller code. Control lifecycle work bypasses
// admission so stop cannot be lost during a report flood.
@interface NSProviderWorkQueue : NSObject
@property(nonatomic, readonly) dispatch_queue_t queue;
@property(nonatomic, readonly) NSUInteger rejectedCount;
- (instancetype)initWithCapacity:(NSUInteger)capacity;
- (BOOL)submit:(void (^)(void))work;
@end

@interface NSProviderReply : NSObject
- (void)complete:(id)result;
@end
@interface NSProviderReplyGate : NSObject
@property(nonatomic, readonly) NSUInteger rejectedCount;
- (instancetype)initWithCapacity:(NSUInteger)capacity delivery:(dispatch_queue_t)delivery;
// nil means no slot. The caller must synchronously deny outside all state locks.
- (NSProviderReply *)admit:(void (^)(id))completion;
@end
