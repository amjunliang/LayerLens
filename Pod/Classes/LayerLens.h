//
//  LayerLens.h
//  LayerLens
//
//  Created by YueYou on 10/12/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Pod 版本号
FOUNDATION_EXPORT NSString * const LayerLensVersion;
/// 接口版本号, 与 Mac App 不兼容时由其提示升级
FOUNDATION_EXPORT const NSInteger LayerLensAPIVersion;

/// 集成即用: DEBUG 编译时随 App 启动, 由 Mac 上的 LayerLens 自动发现并连接
@interface LayerLens : NSObject

/// 记录一条日志: 实时显示在 Mac 端的日志面板, 同时写入设备上的日志文件. 任意线程可调用, 非 DEBUG 编译时不做任何事
+ (void)log:(NSString *)message;

/// 设备上的日志目录, 每天一个文件, 可用于分享. LayerLens 的缓存共用 300MB 上限, 超出时先删最早的文件
+ (NSString *)logDirectory;

@end

/// 格式化后调用 [LayerLens log:]
FOUNDATION_EXPORT void LayerLensLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

NS_ASSUME_NONNULL_END
