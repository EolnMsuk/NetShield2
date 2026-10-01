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
- (void)refreshRules:(NSDictionary *)rules;
- (void)stop;
@end
