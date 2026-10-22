//
//  LLENetworkDemo.h
//  LayerLensExample
//
//  Created by YueYou on 10/22/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 发出一组示例请求, 在 LayerLens 的网络面板中查看
@interface LLENetworkDemo : NSObject

+ (void)sendRequests;

@end

NS_ASSUME_NONNULL_END
