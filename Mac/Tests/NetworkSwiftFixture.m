#import <Foundation/Foundation.h>
#import "LayerLensNetworkHooks.h"
#import "LayerLensNetworkRecorder.h"

static NSLock *lock;
static NSUInteger completionCount;
static NSData *captured;
static NSInteger capturedStatus;
static NSInteger capturedError;
static NSUInteger streamedBytes;
static NSData *uploadBody;
static BOOL uploadFile;
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation LayerLensNetworkRecorder
+ (BOOL)captureEnabledAtLaunch { return NO; }
+ (instancetype)sharedRecorder { static id recorder; static dispatch_once_t once; dispatch_once(&once, ^{ recorder = [self new]; }); return recorder; }
- (void)taskDidResume:(NSURLSessionTask *)task {}
- (void)markHandlerTask:(NSURLSessionTask *)task {}
- (void)setUploadBody:(id)body forTask:(NSURLSessionTask *)task { [lock lock]; uploadBody = [body isKindOfClass:NSData.class] ? body : nil; uploadFile = [body isKindOfClass:NSURL.class]; [lock unlock]; }
- (void)task:(NSURLSessionTask *)task didReceiveData:(NSData *)data { [lock lock]; streamedBytes += data.length; [lock unlock]; }
- (void)task:(NSURLSessionTask *)task didCompleteWithData:(NSData *)data error:(NSError *)error fromHandler:(BOOL)handler {
    [lock lock]; completionCount++; captured = data; capturedStatus = [(NSHTTPURLResponse *)task.response statusCode]; capturedError = error.code; [lock unlock];
}
@end

@interface AsyncFixtureProtocol : NSURLProtocol @end
@implementation AsyncFixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return [request.URL.host isEqualToString:@"layerlens.test"]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    if ([self.request.URL.path isEqualToString:@"/failure"]) {
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]];
        return;
    }
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[@"swift async payload" dataUsingEncoding:NSUTF8StringEncoding]];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

void ll_async_setup(void) { lock = [NSLock new]; [NSURLProtocol registerClass:AsyncFixtureProtocol.class]; [LayerLensNetworkHooks install]; }
int ll_async_count(void) { [lock lock]; int value = (int)completionCount; [lock unlock]; return value; }
int ll_async_status(void) { [lock lock]; int value = (int)capturedStatus; [lock unlock]; return value; }
int ll_async_error(void) { [lock lock]; int value = (int)capturedError; [lock unlock]; return value; }
int ll_async_body(void) { [lock lock]; BOOL valid = [captured isEqualToData:[@"swift async payload" dataUsingEncoding:NSUTF8StringEncoding]]; [lock unlock]; return valid; }

int ll_async_streamed(void) { [lock lock]; int value = (int)streamedBytes; [lock unlock]; return value; }
int ll_async_upload(void) { [lock lock]; BOOL value = [uploadBody isEqualToData:[@"upload bytes" dataUsingEncoding:NSUTF8StringEncoding]]; [lock unlock]; return value; }
int ll_async_upload_file(void) { [lock lock]; BOOL value = uploadFile; [lock unlock]; return value; }
