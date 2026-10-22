//
//  LayerLensNetworkRecord.m
//  LayerLens
//
//  Created by YueYou on 10/22/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LayerLensNetworkRecord.h"

@implementation LayerLensNetworkRecord

- (NSDictionary *)summary {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"s"] = @(self.seq);
    result[@"id"] = @(self.identifier);
    result[@"type"] = self.taskType ?: @"data";
    result[@"method"] = self.method ?: @"GET";
    result[@"url"] = self.url ?: @"";
    result[@"status"] = @(self.statusCode);
    result[@"mime"] = self.mimeType ?: @"";
    result[@"reqSize"] = @(self.requestBodySize);
    result[@"resSize"] = @(self.responseBodySize);
    result[@"start"] = @((long long)(self.startDate.timeIntervalSince1970 * 1000));
    if (self.endDate) {
        result[@"duration"] = @((long long)([self.endDate timeIntervalSinceDate:self.startDate] * 1000));
    }
    result[@"state"] = !self.finished ? @"pending" : self.errorMessage ? @"failed" : @"done";
    if (self.errorMessage) {
        result[@"error"] = self.errorMessage;
    }
    return result;
}

- (NSDictionary *)detail {
    NSMutableDictionary *result = [[self summary] mutableCopy];
    result[@"requestHeaders"] = self.requestHeaders ?: @{};
    result[@"responseHeaders"] = self.responseHeaders ?: @{};
    result[@"reqBody"] = [self bodyStateName:self.requestBodyState path:self.requestBodyPath];
    result[@"resBody"] = [self bodyStateName:self.responseBodyState path:self.responseBodyPath];
    return result;
}

- (NSString *)bodyStateName:(LayerLensBodyState)state path:(NSString *)path {
    switch (state) {
        case LayerLensBodyStateStored:
            // 存在文件中的内容可能已被缓存清理删除
            return path && ![NSFileManager.defaultManager fileExistsAtPath:path] ? @"evicted" : @"stored";
        case LayerLensBodyStateTooLarge:
            return @"tooLarge";
        case LayerLensBodyStateStream:
            return @"stream";
        case LayerLensBodyStateFile:
            return @"file";
        default:
            return @"none";
    }
}

@end
