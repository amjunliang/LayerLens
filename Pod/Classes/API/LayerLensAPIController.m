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
#import "LayerLensLogger.h"
#import "LayerLensSandbox.h"
#import "LayerLensNetworkRecorder.h"
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

    // 日志流: 先补齐序号大于 since 的缓冲日志, 之后每批新日志推送一次; 连上时带上 instanceId, 对方据此判断 App 是否重启过
    [router addRoute:@"GET" path:@"/api/logs" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        uint64_t since = strtoull(request.query[@"since"].UTF8String ?: "0", NULL, 10);
        [LayerLensLogger.sharedLogger entriesSince:since completion:^(NSArray<NSDictionary *> *entries) {
            LayerLensHTTPResponse *response = [LayerLensHTTPResponse eventStreamResponseWithRetry:2000 event:@"logs" object:@{@"instanceId": [LayerLensLookinBridge instanceId], @"entries": entries}];
            response.channel = @"logs";
            responder(response);
        }];
    }];

    [router addRoute:@"GET" path:@"/api/logs/files" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        [LayerLensLogger.sharedLogger filesWithCompletion:^(NSArray<NSDictionary *> *files) {
            responder([LayerLensHTTPResponse JSONResponse:@{@"files": files}]);
        }];
    }];

    // 分段读取日志文件, 网页按需加载; 往日的文件不再变化, 读满一段时允许缓存
    [router addRoute:@"GET" path:@"/api/logs/file" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        NSString *name = request.query[@"name"] ?: @"";
        unsigned long long offset = strtoull(request.query[@"offset"].UTF8String ?: "0", NULL, 10);
        NSUInteger length = MIN((NSUInteger)strtoul(request.query[@"length"].UTF8String ?: "0", NULL, 10) ?: 1024 * 1024, 4 * 1024 * 1024);
        [LayerLensLogger.sharedLogger readFile:name offset:offset length:length completion:^(NSData *data, unsigned long long total) {
            if (!data) {
                responder([LayerLensHTTPResponse errorResponse:404 message:@"File not found"]);
                return;
            }
            LayerLensHTTPResponse *response = [LayerLensHTTPResponse responseWithStatus:200 contentType:@"text/plain; charset=utf-8" body:data];
            response.headers[@"X-Total-Size"] = [NSString stringWithFormat:@"%llu", total];
            NSString *today = [NSString stringWithFormat:@"%@.log", [self dayString]];
            response.headers[@"Cache-Control"] = data.length == length && ![name isEqualToString:today] ? @"max-age=86400" : @"no-store";
            responder(response);
        }];
    }];

    [self registerSandboxRoutesToRouter:router];
    [self registerNetworkRoutesToRouter:router];

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

#pragma mark - Sandbox

// 沙盒文件读写较慢, 放到后台队列, 路径参数均为相对主目录的路径
- (void)registerSandboxRoutesToRouter:(LayerLensRouter *)router {
    [router addRoute:@"GET" path:@"/api/sandbox/list" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        [self onBackground:^{
            NSError *error = nil;
            NSDictionary *result = [LayerLensSandbox listDirectory:request.query[@"path"] ?: @"" error:&error];
            responder(result ? [LayerLensHTTPResponse JSONResponse:result] : [self responseWithError:error]);
        }];
    }];

    // limit 用于预览只取开头; download=1 时作为附件下载
    [router addRoute:@"GET" path:@"/api/sandbox/file" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        [self onBackground:^{
            NSString *path = request.query[@"path"] ?: @"";
            unsigned long long total = 0;
            NSError *error = nil;
            NSData *data = [LayerLensSandbox readFile:path limit:strtoull(request.query[@"limit"].UTF8String ?: "0", NULL, 10) total:&total error:&error];
            if (!data) {
                responder([self responseWithError:error]);
                return;
            }
            LayerLensHTTPResponse *response = [LayerLensHTTPResponse responseWithStatus:200 contentType:[LayerLensSandbox contentTypeForPath:path] body:data];
            response.headers[@"X-Total-Size"] = [NSString stringWithFormat:@"%llu", total];
            response.headers[@"Cache-Control"] = @"no-store";
            if ([request.query[@"download"] isEqualToString:@"1"]) {
                response.headers[@"Content-Disposition"] = [self attachmentHeaderWithName:path.lastPathComponent];
            }
            responder(response);
        }];
    }];

    [router addRoute:@"GET" path:@"/api/sandbox/zip" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        [self onBackground:^{
            NSString *path = request.query[@"path"] ?: @"";
            NSError *error = nil;
            NSData *data = [LayerLensSandbox zipItem:path error:&error];
            if (!data) {
                responder([self responseWithError:error]);
                return;
            }
            LayerLensHTTPResponse *response = [LayerLensHTTPResponse responseWithStatus:200 contentType:@"application/zip" body:data];
            NSString *name = path.lastPathComponent.length > 0 ? path.lastPathComponent : @"Sandbox";
            response.headers[@"Content-Disposition"] = [self attachmentHeaderWithName:[name stringByAppendingPathExtension:@"zip"]];
            responder(response);
        }];
    }];

    [router addRoute:@"GET" path:@"/api/sandbox/plist" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        [self onBackground:^{
            NSError *error = nil;
            id result = [LayerLensSandbox propertyList:request.query[@"path"] ?: @"" error:&error];
            responder(result ? [LayerLensHTTPResponse JSONResponse:@{@"value": result}] : [self responseWithError:error]);
        }];
    }];

    [router addRoute:@"GET" path:@"/api/sandbox/sqlite" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        [self onBackground:^{
            NSError *error = nil;
            NSDictionary *result = [LayerLensSandbox queryDatabase:request.query[@"path"] ?: @""
                                                             table:request.query[@"table"]
                                                            offset:[request.query[@"offset"] integerValue]
                                                             limit:[request.query[@"limit"] integerValue] ?: 100
                                                             error:&error];
            responder(result ? [LayerLensHTTPResponse JSONResponse:result] : [self responseWithError:error]);
        }];
    }];

    // 请求体为文件原始内容, 上限见 LayerLensHTTPRequest
    [router addRoute:@"POST" path:@"/api/sandbox/upload" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        [self onBackground:^{
            NSError *error = nil;
            BOOL ok = [LayerLensSandbox writeData:request.body ?: [NSData data] directory:request.query[@"path"] ?: @"" name:request.query[@"name"] ?: @"" error:&error];
            responder(ok ? [LayerLensHTTPResponse JSONResponse:@{@"ok": @YES}] : [self responseWithError:error]);
        }];
    }];

    [router addRoute:@"POST" path:@"/api/sandbox/delete" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        NSDictionary *body = [request.JSONBody isKindOfClass:NSDictionary.class] ? request.JSONBody : @{};
        NSString *path = [body[@"path"] isKindOfClass:NSString.class] ? body[@"path"] : @"";
        [self onBackground:^{
            NSError *error = nil;
            BOOL ok = [LayerLensSandbox removeItem:path error:&error];
            responder(ok ? [LayerLensHTTPResponse JSONResponse:@{@"ok": @YES}] : [self responseWithError:error]);
        }];
    }];
}

#pragma mark - Network

- (void)registerNetworkRoutesToRouter:(LayerLensRouter *)router {
    // 网页据此判断 Pod 是否支持抓包
    [router addRoute:@"GET" path:@"/api/network/status" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        responder([LayerLensHTTPResponse JSONResponse:@{@"ok": @YES}]);
    }];

    // 请求流: 先补齐序号大于 since 的请求, 之后每批变化推送一次, 同一请求以 id 合并; 清空时推送 clear
    [router addRoute:@"GET" path:@"/api/network" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        uint64_t since = strtoull(request.query[@"since"].UTF8String ?: "0", NULL, 10);
        [LayerLensNetworkRecorder.sharedRecorder recordsSince:since completion:^(NSArray<NSDictionary *> *records) {
            LayerLensHTTPResponse *response = [LayerLensHTTPResponse eventStreamResponseWithRetry:2000 event:@"network" object:@{@"instanceId": [LayerLensLookinBridge instanceId], @"records": records}];
            response.channel = @"network";
            responder(response);
        }];
    }];

    [router addRoute:@"GET" path:@"/api/network/detail" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        uint64_t identifier = strtoull(request.query[@"id"].UTF8String ?: "0", NULL, 10);
        [LayerLensNetworkRecorder.sharedRecorder detailForIdentifier:identifier completion:^(NSDictionary *detail) {
            responder(detail ? [LayerLensHTTPResponse JSONResponse:detail] : [LayerLensHTTPResponse errorResponse:404 message:@"Request not found"]);
        }];
    }];

    // side 为 req 或 res, 返回原始内容; 没有内容时 404 并给出原因
    [router addRoute:@"GET" path:@"/api/network/body" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        uint64_t identifier = strtoull(request.query[@"id"].UTF8String ?: "0", NULL, 10);
        [LayerLensNetworkRecorder.sharedRecorder bodyForIdentifier:identifier side:request.query[@"side"] ?: @"res" completion:^(NSData *data, NSString *contentType, NSString *message) {
            if (!data) {
                responder([LayerLensHTTPResponse errorResponse:404 message:message ?: @"No content"]);
                return;
            }
            LayerLensHTTPResponse *response = [LayerLensHTTPResponse responseWithStatus:200 contentType:contentType body:data];
            response.headers[@"Cache-Control"] = @"no-store";
            responder(response);
        }];
    }];

    // ids 为逗号分隔的请求 id, 为空时导出全部
    [router addRoute:@"GET" path:@"/api/network/har" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        NSMutableArray<NSNumber *> *identifiers = [NSMutableArray array];
        for (NSString *item in [request.query[@"ids"] ?: @"" componentsSeparatedByString:@","]) {
            uint64_t identifier = strtoull(item.UTF8String ?: "0", NULL, 10);
            if (identifier > 0) {
                [identifiers addObject:@(identifier)];
            }
        }
        [LayerLensNetworkRecorder.sharedRecorder HARWithIdentifiers:identifiers completion:^(NSData *data) {
            LayerLensHTTPResponse *response = [LayerLensHTTPResponse responseWithStatus:200 contentType:@"application/json; charset=utf-8" body:data];
            NSString *name = request.query[@"name"].length > 0 ? request.query[@"name"] : @"LayerLens.har";
            response.headers[@"Content-Disposition"] = [self attachmentHeaderWithName:name];
            responder(response);
        }];
    }];

    [router addRoute:@"POST" path:@"/api/network/clear" handler:^(LayerLensHTTPRequest *request, LayerLensResponder responder) {
        [LayerLensNetworkRecorder.sharedRecorder clear];
        responder([LayerLensHTTPResponse JSONResponse:@{@"ok": @YES}]);
    }];
}

- (LayerLensHTTPResponse *)responseWithError:(NSError *)error {
    return [LayerLensHTTPResponse errorResponse:error.code >= 400 ? error.code : 500 message:error.localizedDescription ?: @"Failed"];
}

/// 文件名可能含中文, 同时给出 RFC 5987 编码的版本
- (NSString *)attachmentHeaderWithName:(NSString *)name {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSString *encoded = [name stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"download";
    NSString *ascii = [[name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\"\\\r\n"]] componentsJoinedByString:@"_"];
    if (![ascii canBeConvertedToEncoding:NSASCIIStringEncoding]) {
        ascii = name.pathExtension.length > 0 ? [@"download" stringByAppendingPathExtension:name.pathExtension] : @"download";
    }
    return [NSString stringWithFormat:@"attachment; filename=\"%@\"; filename*=UTF-8''%@", ascii, encoded];
}

- (void)onBackground:(dispatch_block_t)block {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), block);
}

- (NSString *)dayString {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd";
    return [formatter stringFromDate:[NSDate date]];
}

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
