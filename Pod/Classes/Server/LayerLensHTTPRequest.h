//
//  LayerLensHTTPRequest.h
//  LayerLens
//
//  Created by YueYou on 10/12/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LayerLensParseResult) {
    LayerLensParseResultIncomplete,
    LayerLensParseResultDone,
    LayerLensParseResultError,
};

@interface LayerLensHTTPRequest : NSObject

@property (nonatomic, copy, readonly) NSString *method;
@property (nonatomic, copy, readonly) NSString *path;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *query;
/// header 名统一小写
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, strong, readonly, nullable) NSData *body;

/// 尝试从累积的数据中解析出完整请求
+ (LayerLensParseResult)parseData:(NSData *)data request:(LayerLensHTTPRequest * _Nullable * _Nullable)request;

- (nullable id)JSONBody;

@end

NS_ASSUME_NONNULL_END
