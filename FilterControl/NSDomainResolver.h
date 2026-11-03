#import <Foundation/Foundation.h>

@protocol NSDNSOperation <NSObject>
- (void)cancel;
@end
typedef id<NSDNSOperation> (^NSDNSLookupFactory)(NSString *key, dispatch_queue_t queue,
                                                 void (^completion)(NSDictionary *result, NSError *error));

@interface NSDomainResolver : NSObject
- (instancetype)initWithCompletion:(void (^)(NSString *key, NSString *rule, NSDictionary *result,
                                             NSError *error))completion;
- (instancetype)initWithQueue:(dispatch_queue_t)queue
                        clock:(NSTimeInterval (^)(void))clock
                       lookup:(NSDNSLookupFactory)lookup
                   completion:(void (^)(NSString *, NSString *, NSDictionary *, NSError *))completion;
@property(nonatomic, readonly, copy) NSString *coverageIssue;
- (void)refreshRules:(NSDictionary *)rules;
- (void)refreshRules:(NSDictionary *)rules generation:(NSString *)generation;
- (void)invalidateNetwork;
- (void)invalidateNetworkWithCompletion:(void (^)(void))completion;
- (void)stop;
// Acknowledged on the DNS queue after all DNS references have been cancelled.
- (void)stopWithCompletion:(void (^)(void))completion;
@end
