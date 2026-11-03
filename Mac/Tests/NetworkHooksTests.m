// Exercise the real URLSession hooks with a session created before installation.
// A local NSURLProtocol supplies all responses; no network or user storage is used.
#import <Foundation/Foundation.h>
#import "LayerLensNetworkHooks.h"
#import "LayerLensNetworkRecorder.h"

static NSUInteger receivedBytes, completions;
static dispatch_semaphore_t finished;

// The hooks' recorder sink is isolated from the application's singleton and defaults.
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation LayerLensNetworkRecorder
+ (BOOL)captureEnabledAtLaunch { return NO; }
+ (instancetype)sharedRecorder {
    static id recorder; static dispatch_once_t once;
    dispatch_once(&once, ^{ recorder = [self new]; });
    return recorder;
}
- (void)taskDidResume:(NSURLSessionTask *)task {}
- (void)markHandlerTask:(NSURLSessionTask *)task {}
- (void)setUploadBody:(id)body forTask:(NSURLSessionTask *)task {}
- (void)task:(NSURLSessionTask *)task didReceiveData:(NSData *)data { receivedBytes += data.length; }
- (void)task:(NSURLSessionTask *)task didCompleteWithData:(NSData *)data error:(NSError *)error fromHandler:(BOOL)handler {
    NSCAssert(task != nil && error == nil, @"Completion must retain task identity and result");
    completions++;
}
@end

@interface LocalResponse : NSURLProtocol @end
@implementation LocalResponse
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[@"payload" dataUsingEncoding:NSUTF8StringEncoding]];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

@interface ExistingDelegate : NSObject <NSURLSessionDataDelegate>
@property NSUInteger bytes;
@end
@implementation ExistingDelegate
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data { self.bytes += data.length; }
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error { dispatch_semaphore_signal(finished); }
@end

int main(void) {
    @autoreleasepool {
        finished = dispatch_semaphore_create(0);
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.protocolClasses = @[LocalResponse.class];
        ExistingDelegate *delegate = [ExistingDelegate new];
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:delegate delegateQueue:nil];
        [LayerLensNetworkHooks install];
        [[session dataTaskWithURL:[NSURL URLWithString:@"https://layerlens.test/local"]] resume];
        NSCAssert(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0, @"Delegate completion was lost");
        NSCAssert(delegate.bytes == 7 && receivedBytes == 7 && completions == 1, @"Existing session must capture once and preserve delegate delivery");
        [session invalidateAndCancel];
        puts("PASS first capture: pre-existing URLSession delegate data and completion, original delivery preserved");
    }
}
