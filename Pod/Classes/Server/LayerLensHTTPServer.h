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

/// 监听已失效(如挂起期间被系统回收)时按原参数重新监听; 监听器仍为 ready 时先连接自检, 连不上同样重新监听. 已有连接保持不变
- (void)resumeIfNeeded;

/// 向指定频道推送; 频道没有连接时不调用 objectBlock, 省去序列化
- (void)broadcastEvent:(NSString *)name channel:(NSString *)channel objectBlock:(id (^)(void))objectBlock;

/// 向默认频道(events)的所有事件流推送一个事件
- (void)broadcastEvent:(NSString *)name object:(id)object;

@end

NS_ASSUME_NONNULL_END
