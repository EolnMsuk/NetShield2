#import <Foundation/Foundation.h>

@protocol NSDNSOperation <NSObject>
- (void)cancel;
@end
typedef id<NSDNSOperation> (^NSDNSLookupFactory)(NSString *key, dispatch_queue_t queue,
                                                 void (^completion)(NSDictionary *result, NSError *error));

// Cancellable DNS lookups: at most four domains / eight DNSService references.
// Results contain only current DNS answers and an expiry capped at five minutes.
@interface NSDomainResolver : NSObject
- (instancetype)initWithCompletion:(void (^)(NSString *key, NSString *rule, NSDictionary *result,
                                             NSError *error))completion;
// Lookup completion must be asynchronous on queue. Used by deterministic tests.
- (instancetype)initWithQueue:(dispatch_queue_t)queue
                        clock:(NSTimeInterval (^)(void))clock
                       lookup:(NSDNSLookupFactory)lookup
                   completion:(void (^)(NSString *, NSString *, NSDictionary *, NSError *))completion;
- (void)refreshRules:(NSDictionary *)rules;
- (void)stop;
@end
