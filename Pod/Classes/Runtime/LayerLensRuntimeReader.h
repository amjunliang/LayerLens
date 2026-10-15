//
//  LayerLensRuntimeReader.h
//  LayerLens
//
//  Created by YueYou on 10/12/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 通过 objc runtime 读取对象的类信息, 必须在主线程调用
@interface LayerLensRuntimeReader : NSObject

/// 返回类链上每一层的 ivar(含当前值)/property/method, 截止到 NSObject(不含)
/// @param nodeOidBlock 当 ivar 值为 view/layer 时, 用于获取其在层级树中的 oid
+ (NSDictionary *)classInfoOfObject:(NSObject *)object nodeOidBlock:(nullable unsigned long (^)(NSObject *value))nodeOidBlock;

@end

NS_ASSUME_NONNULL_END
