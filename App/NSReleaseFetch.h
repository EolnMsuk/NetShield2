#import <Foundation/Foundation.h>
// Streaming accumulation is shared by the real delegate and fault-injection tests.
@interface NSReleaseBody : NSObject
@property(nonatomic, readonly) NSData *data;
- (BOOL)acceptResponse:(NSURLResponse *)response;
- (BOOL)append:(NSData *)chunk;
@end
FOUNDATION_EXPORT BOOL NSAllowedReleaseURL(NSURL *url);
@interface NSReleaseFetch : NSObject <NSURLSessionDataDelegate>
- (instancetype)initWithRequest:(NSURLRequest *)request
                     completion:(void (^)(NSData *, NSURLResponse *, NSError *))completion;
- (void)resume;
- (void)cancel;
@end
