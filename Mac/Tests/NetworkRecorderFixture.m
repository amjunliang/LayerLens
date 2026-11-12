#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "LayerLensNetworkHooks.h"
#import "LayerLensNetworkRecorder.h"
#import "LayerLensNetworkRecord.h"
#import "LayerLensStorage.h"

@implementation LayerLensStorage
+ (NSString *)directoryNamed:(NSString *)name { return [NSTemporaryDirectory() stringByAppendingPathComponent:@"LayerLensNetworkRecorderTest"]; }
+ (void)didWrite {}
+ (unsigned long long)limit { return 0; }
@end
NSString * const LayerLensVersion = @"test";
void LayerLensLog(NSString *format, ...) {}

@interface RecorderFixtureProtocol : NSURLProtocol @end
@implementation RecorderFixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return [request.URL.host isEqualToString:@"layerlens.test"]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[@"swift async payload" dataUsingEncoding:NSUTF8StringEncoding]];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

void ll_real_setup(void) {
    Class meta = object_getClass(LayerLensNetworkRecorder.class);
    Method method = class_getClassMethod(LayerLensNetworkRecorder.class, @selector(captureEnabledAtLaunch));
    class_replaceMethod(meta, @selector(captureEnabledAtLaunch), imp_implementationWithBlock(^BOOL(id cls) { return YES; }), method_getTypeEncoding(method));
    [NSURLProtocol registerClass:RecorderFixtureProtocol.class];
    [LayerLensNetworkHooks install];
}
int ll_real_stream_ok(void) {
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __block NSArray *records;
    [LayerLensNetworkRecorder.sharedRecorder recordsSince:0 completion:^(NSArray *value) { records = value; dispatch_semaphore_signal(ready); }];
    if (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC))) return 0;
    NSDictionary *record = records.lastObject;
    if (![record[@"state"] isEqual:@"done"] || [record[@"status"] intValue] != 200) return 0;
    dispatch_semaphore_t detailReady = dispatch_semaphore_create(0);
    __block NSDictionary *detail;
    [LayerLensNetworkRecorder.sharedRecorder detailForIdentifier:[record[@"id"] unsignedLongLongValue] completion:^(NSDictionary *value) { detail = value; dispatch_semaphore_signal(detailReady); }];
    if (dispatch_semaphore_wait(detailReady, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC))) return 0;
    return [detail[@"resBody"] isEqual:@"unavailable"] && [detail[@"resSize"] intValue] == 19;
}

int ll_real_uncaptured_ok(void) {
    LayerLensNetworkRecord *record = [LayerLensNetworkRecord new];
    record.startDate = [NSDate date];
    record.finished = YES;
    record.captureNote = @"Result not captured";
    NSDictionary *summary = record.summary;
    return [summary[@"state"] isEqual:@"unavailable"] && [summary[@"captureNote"] isEqual:@"Result not captured"] && summary[@"error"] == nil;
}
