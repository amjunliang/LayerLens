//
//  LayerLensHTTPServer.h
//  LayerLens
//
//  Created by YueYou on 10/12/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import <Foundation/Foundation.h>

@class LayerLensRouter;

NS_ASSUME_NONNULL_BEGIN

/// 基于 Network.framework 的极简 HTTP/1.1 服务, 每个请求处理完即关闭连接
@interface LayerLensHTTPServer : NSObject

@property (nonatomic, assign, readonly) uint16_t port;
@property (nonatomic, assign, readonly) BOOL isRunning;

- (instancetype)initWithRouter:(LayerLensRouter *)router;

/// 从 startPort 开始依次尝试, 最多尝试 attempts 个端口; completion 在主线程回调
- (void)startWithLoopbackOnly:(BOOL)loopbackOnly startPort:(uint16_t)startPort attempts:(NSInteger)attempts completion:(void (^)(uint16_t port, NSError * _Nullable error))completion;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
