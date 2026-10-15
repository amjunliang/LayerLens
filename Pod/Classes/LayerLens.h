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

@end

NS_ASSUME_NONNULL_END
