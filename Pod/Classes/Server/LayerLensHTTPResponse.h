//
//  LayerLensHTTPResponse.h
//  LayerLens
//
//  Created by YueYou on 10/12/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LayerLensHTTPResponse : NSObject

@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, copy) NSString *contentType;
@property (nonatomic, strong, nullable) NSData *body;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *headers;
/// 发送后保持连接不关闭, 用于事件流
@property (nonatomic, assign) BOOL keepOpen;

+ (instancetype)responseWithStatus:(NSInteger)status contentType:(NSString *)contentType body:(nullable NSData *)body;
/// JSON 序列化失败时返回 500
+ (instancetype)JSONResponse:(id)object;
+ (instancetype)errorResponse:(NSInteger)status message:(NSString *)message;
+ (instancetype)PNGResponse:(NSData *)data;
/// 不关闭的事件流, 网页据此即时感知 App 停止; retry 为浏览器断线后的重连间隔(毫秒)
+ (instancetype)eventStreamResponseWithRetry:(NSInteger)retry;
/// 带首个事件的事件流, 用于连上时同步当前状态
+ (instancetype)eventStreamResponseWithRetry:(NSInteger)retry event:(NSString *)name object:(id)object;
/// 单个事件的报文: event: name, data: object 的 JSON
+ (NSData *)eventDataWithName:(NSString *)name object:(id)object;

- (NSData *)serializedData;

@end

NS_ASSUME_NONNULL_END
