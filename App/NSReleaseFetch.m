#import "NSReleaseFetch.h"
static const NSUInteger NSReleaseBodyLimit = 1024 * 1024;
BOOL NSAllowedReleaseURL(NSURL *url) {
    return [url.scheme.lowercaseString isEqual:@"https"] &&
           [url.host.lowercaseString isEqual:@"api.github.com"] &&
           (!url.port || url.port.integerValue == 443) && !url.user && !url.password &&
           [url.path isEqual:@"/repos/EolnMsuk/NetShield2/releases/latest"];
}
@implementation NSReleaseBody {
    NSMutableData *_bytes;
}
- (instancetype)init {
    if ((self = [super init])) {
        _bytes = [NSMutableData new];
    }
    return self;
}
- (NSData *)data {
    return [_bytes copy];
}
- (BOOL)acceptResponse:(NSURLResponse *)response {
    return [response isKindOfClass:NSHTTPURLResponse.class] && NSAllowedReleaseURL(response.URL) &&
           [(NSHTTPURLResponse *)response statusCode] == 200 &&
           response.expectedContentLength <= (long long)NSReleaseBodyLimit;
}
- (BOOL)append:(NSData *)chunk {
    if (chunk.length > NSReleaseBodyLimit - _bytes.length) {
        return NO;
    }
    [_bytes appendData:chunk];
    return YES;
}
@end
@interface NSReleaseFetch ()
@property(nonatomic, strong) NSURLRequest *request;
@property(nonatomic, copy) void (^completion)(NSData *, NSURLResponse *, NSError *);
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) dispatch_source_t deadline;
@property(nonatomic, strong) NSReleaseBody *body;
@property(nonatomic, strong) NSURLResponse *response;
@property(nonatomic, strong) NSError *failure;
@end
@implementation NSReleaseFetch
- (instancetype)initWithRequest:(NSURLRequest *)request
                     completion:(void (^)(NSData *, NSURLResponse *, NSError *))completion {
    if ((self = [super init])) {
        _request = request;
        _completion = [completion copy];
        _queue = dispatch_queue_create("com.eolnmsuk.netshield.release", DISPATCH_QUEUE_SERIAL);
        if (!_queue) {
            return nil;
        }
        _body = [NSReleaseBody new];
    }
    return self;
}
- (void)finish:(NSError *)error {
    void (^completion)(NSData *, NSURLResponse *, NSError *) = self.completion;
    self.completion = nil;
    NSData *data = error ? nil : self.body.data;
    NSURLResponse *response = self.response;
    self.body = nil;
    if (self.deadline) {
        dispatch_source_cancel(self.deadline);
    }
    self.deadline = nil;
    [self.task cancel];
    self.task = nil;
    [self.session invalidateAndCancel];
    self.session = nil;
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(data, response, error);
        });
    }
}
- (void)resume {
    dispatch_async(self.queue, ^{
        if (!self.completion || self.task) {
            return;
        }
        if (!NSAllowedReleaseURL(self.request.URL)) {
            [self finish:[NSError errorWithDomain:NSURLErrorDomain
                                             code:NSURLErrorUnsupportedURL
                                         userInfo:nil]];
            return;
        }
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.HTTPShouldSetCookies = NO;
        configuration.HTTPCookieStorage = nil;
        configuration.URLCredentialStorage = nil;
        configuration.URLCache = nil;
        configuration.timeoutIntervalForRequest = 20;
        configuration.timeoutIntervalForResource = 25;
        NSOperationQueue *delegate = [NSOperationQueue new];
        delegate.maxConcurrentOperationCount = 1;
        delegate.underlyingQueue = self.queue;
        self.session = [NSURLSession sessionWithConfiguration:configuration
                                                     delegate:self
                                                delegateQueue:delegate];
        self.task = [self.session dataTaskWithRequest:self.request];
        self.deadline = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
        if (!self.deadline) {
            [self finish:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorUnknown userInfo:nil]];
            return;
        }
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(self.deadline, ^{
            [weakSelf finish:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]];
        });
        dispatch_source_set_timer(self.deadline, dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC),
                                  DISPATCH_TIME_FOREVER, NSEC_PER_MSEC * 100);
        dispatch_resume(self.deadline);
        [self.task resume];
    });
}
- (void)cancel {
    dispatch_async(self.queue, ^{
        [self finish:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
    });
}
- (void)URLSession:(NSURLSession *)session
                          task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                    newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *))completionHandler {
    BOOL allowed = NSAllowedReleaseURL(request.URL);
    completionHandler(allowed ? request : nil);
    if (!allowed) {
        [self finish:[NSError errorWithDomain:NSURLErrorDomain
                                         code:NSURLErrorRedirectToNonExistentLocation
                                     userInfo:nil]];
    }
}
- (void)URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    self.response = response;
    BOOL allowed = self.completion && [self.body acceptResponse:response];
    completionHandler(allowed ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
    if (!allowed) {
        [self finish:[NSError errorWithDomain:NSURLErrorDomain
                                         code:NSURLErrorBadServerResponse
                                     userInfo:nil]];
    }
}
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)task
    didReceiveData:(NSData *)data {
    if (self.completion && ![self.body append:data]) {
        [self finish:[NSError errorWithDomain:NSURLErrorDomain
                                         code:NSURLErrorDataLengthExceedsMaximum
                                     userInfo:nil]];
    }
}
- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
    if (self.completion) {
        [self finish:error];
    }
}
@end
