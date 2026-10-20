//
//  LayerLensAPIController.m
//  LayerLens
//
//  Created by YueYou on 10/12/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LayerLensAPIController.h"
#import "LayerLensRouter.h"
#import "LayerLensHTTPRequest.h"
#import "LayerLensHTTPResponse.h"
#import "LayerLensLookinBridge.h"
#import "LayerLensRuntimeReader.h"
#import <UIKit/UIKit.h>

@implementation LayerLensAPIController

- (void)registerRoutesToRouter:(LayerLensRouter *)router {
    // 网页由 Mac App 提供, 直接访问时给出提示
    [router addRoute:@"GET" path:@"/" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        NSData *body = [@"LayerLens is running. Open the LayerLens Mac app or http://127.0.0.1:9523 to inspect this app.\n" dataUsingEncoding:NSUTF8StringEncoding];
        responder([LayerLensHTTPResponse responseWithStatus:200 contentType:@"text/plain; charset=utf-8" body:body]);
    }];

    [router addRoute:@"GET" path:@"/api/events" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        // 连上时带上当前前后台状态, 之后的变化由 LayerLens 推送
        [self onMain:^{
            BOOL foreground = UIApplication.sharedApplication.applicationState != UIApplicationStateBackground;
            responder([LayerLensHTTPResponse eventStreamResponseWithRetry:2000 event:@"state" object:@{@"foreground": @(foreground)}]);
        }];
    }];

    [router addRoute:@"GET" path:@"/api/app" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        [self onMain:^{
            responder([LayerLensHTTPResponse JSONResponse:[LayerLensLookinBridge appInfo]]);
        }];
    }];

    [router addRoute:@"GET" path:@"/api/hierarchy" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        [self onMain:^{
            responder([LayerLensHTTPResponse JSONResponse:[LayerLensLookinBridge hierarchy]]);
        }];
    }];

    [router addRoute:@"GET" path:@"/api/detail" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        unsigned long oid = [self oidFromString:request.query[@"oid"]];
        [self onMain:^{
            NSDictionary *detail = [LayerLensLookinBridge detailWithOid:oid];
            responder(detail ? [LayerLensHTTPResponse JSONResponse:detail] : [LayerLensHTTPResponse errorResponse:404 message:@"Object not found, please refresh"]);
        }];
    }];

    [router addRoute:@"GET" path:@"/api/screenshot" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        unsigned long oid = [self oidFromString:request.query[@"oid"]];
        BOOL solo = [request.query[@"type"] isEqualToString:@"solo"];
        // 旧版网页不传 layers, 按原行为排除所有子层
        BOOL soloLayers = ![request.query[@"layers"] isEqualToString:@"0"];
        [self onMain:^{
            NSData *data = [LayerLensLookinBridge screenshotWithOid:oid solo:solo soloLayers:soloLayers];
            // 无内容的容器返回透明图, 避免浏览器报 404 并触发前端重试
            responder([LayerLensHTTPResponse PNGResponse:data ?: [self transparentPNG]]);
        }];
    }];

    [router addRoute:@"POST" path:@"/api/modify" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        NSDictionary *body = [request JSONBody];
        if (![body isKindOfClass:NSDictionary.class] || ![body[@"attrId"] isKindOfClass:NSString.class]) {
            responder([LayerLensHTTPResponse errorResponse:400 message:@"Invalid body"]);
            return;
        }
        unsigned long oid = [self oidFromString:[body[@"oid"] description]];
        id value = body[@"value"] == [NSNull null] ? nil : body[@"value"];
        [self onMain:^{
            [LayerLensLookinBridge modifyWithOid:oid attrId:body[@"attrId"] attrType:[body[@"attrType"] integerValue] value:value completion:^(NSDictionary *detail, NSString *errorMessage) {
                if (!detail) {
                    responder([LayerLensHTTPResponse errorResponse:400 message:errorMessage ?: @"Modification failed"]);
                    return;
                }
                responder([LayerLensHTTPResponse JSONResponse:@{@"detail": detail, @"error": errorMessage ?: [NSNull null]}]);
            }];
        }];
    }];

    [router addRoute:@"GET" path:@"/api/class" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        unsigned long oid = [self oidFromString:request.query[@"oid"]];
        [self onMain:^{
            NSObject *object = [LayerLensLookinBridge objectWithOid:oid];
            if (!object) {
                responder([LayerLensHTTPResponse errorResponse:404 message:@"Object not found, please refresh"]);
                return;
            }
            NSDictionary *info = [LayerLensRuntimeReader classInfoOfObject:object nodeOidBlock:^unsigned long(NSObject *value) {
                return [LayerLensLookinBridge nodeOidForObject:value];
            }];
            responder([LayerLensHTTPResponse JSONResponse:info]);
        }];
    }];
}

#pragma mark - Private

- (NSData *)transparentPNG {
    static NSData *data = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        data = [[NSData alloc] initWithBase64EncodedString:@"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=" options:0];
    });
    return data;
}

- (unsigned long)oidFromString:(NSString *)string {
    return strtoul(string.UTF8String ?: "0", NULL, 10);
}

- (void)onMain:(dispatch_block_t)block {
    dispatch_async(dispatch_get_main_queue(), block);
}

@end
