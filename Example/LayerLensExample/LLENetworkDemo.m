//
//  LLENetworkDemo.m
//  LayerLensExample
//
//  Created by YueYou on 10/22/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LLENetworkDemo.h"

@interface LLENetworkDemo () <NSURLSessionDataDelegate>

@property (nonatomic, strong) NSURLSession *delegateSession;

@end

@implementation LLENetworkDemo

+ (instancetype)sharedDemo {
    static LLENetworkDemo *demo = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        demo = [[LLENetworkDemo alloc] init];
        demo.delegateSession = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration delegate:demo delegateQueue:nil];
    });
    return demo;
}

+ (void)sendRequests {
    [[self sharedDemo] sendRequests];
}

- (void)sendRequests {
    NSURLSession *shared = NSURLSession.sharedSession;
    // completionHandler 方式
    [[shared dataTaskWithURL:[NSURL URLWithString:@"https://httpbin.org/get?from=layerlens&lang=zh"] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    }] resume];
    [[shared dataTaskWithURL:[NSURL URLWithString:@"https://httpbin.org/status/404"] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    }] resume];
    [[shared dataTaskWithURL:[NSURL URLWithString:@"https://httpbin.org/image/png"] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    }] resume];
    [[shared dataTaskWithURL:[NSURL URLWithString:@"https://no-such-host.layerlens.invalid/"] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    }] resume];

    // 代理方式: JSON POST 与较大的响应
    NSMutableURLRequest *post = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://httpbin.org/post"]];
    post.HTTPMethod = @"POST";
    [post setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    post.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"name": @"LayerLens", @"items": @[@1, @2, @3], @"nested": @{@"ok": @YES}} options:0 error:nil];
    [[self.delegateSession dataTaskWithRequest:post] resume];
    [[self.delegateSession dataTaskWithURL:[NSURL URLWithString:@"https://httpbin.org/bytes/200000"]] resume];
    [[self.delegateSession dataTaskWithURL:[NSURL URLWithString:@"https://httpbin.org/delay/3"]] resume];

    // 上传与下载
    NSMutableURLRequest *upload = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://httpbin.org/put"]];
    upload.HTTPMethod = @"PUT";
    [upload setValue:@"text/plain; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    [[shared uploadTaskWithRequest:upload fromData:[@"Hello from LayerLens 你好" dataUsingEncoding:NSUTF8StringEncoding] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    }] resume];
    [[shared downloadTaskWithURL:[NSURL URLWithString:@"https://httpbin.org/bytes/50000"] completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
    }] resume];
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
}

@end
