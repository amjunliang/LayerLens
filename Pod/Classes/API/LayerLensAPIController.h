//
//  LayerLensAPIController.h
//  LayerLens
//
//  Created by YueYou on 10/12/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import <Foundation/Foundation.h>

@class LayerLensRouter;

NS_ASSUME_NONNULL_BEGIN

/// 注册 API 路由, 负责主线程切换
@interface LayerLensAPIController : NSObject

- (void)registerRoutesToRouter:(LayerLensRouter *)router;

@end

NS_ASSUME_NONNULL_END
