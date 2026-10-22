//
//  LayerLensNetworkHooks.h
//  LayerLens
//
//  Created by YueYou on 10/22/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 替换 NSURLSession 的实现以记录请求, 结果交给 LayerLensNetworkRecorder.
/// 覆盖任务的 resume, 带 completionHandler 的创建方法, 以及代理的数据与结束回调; WKWebView 的请求不经过这里
@interface LayerLensNetworkHooks : NSObject

/// 整个进程只安装一次, 应尽早调用以记录启动阶段的请求
+ (void)install;

@end

NS_ASSUME_NONNULL_END
