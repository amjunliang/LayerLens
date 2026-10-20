//
//  LayerLensLookinBridge.h
//  LayerLens
//
//  Created by YueYou on 10/12/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 对 LookinServer 内部 API 的唯一封装, 所有方法必须在主线程调用
@interface LayerLensLookinBridge : NSObject

+ (NSDictionary *)appInfo;

/// 本次启动的随机标识, 网页据此判断重连后是否为同一次启动
+ (NSString *)instanceId;

/// 所有 window 的层级树
+ (NSArray<NSDictionary *> *)hierarchy;

/// layer oid 对应的属性分组/自定义属性/事件, 找不到返回 nil
+ (nullable NSDictionary *)detailWithOid:(unsigned long)oid;

/// solo: 仅自身内容, 不含子视图; 否则包含子层
/// soloLayers: solo 时是否也排除非视图的子 CALayer. 网页不显示 CALayer 时传 NO, 这些层不会单独绘制, 留在父视图截图中(如 AVPlayerLayer 内部的视频层)
+ (nullable NSData *)screenshotWithOid:(unsigned long)oid solo:(BOOL)solo soloLayers:(BOOL)soloLayers;

/// oid 为 layer oid, completion 在主线程回调并返回最新 detail
+ (void)modifyWithOid:(unsigned long)oid attrId:(NSString *)attrId attrType:(NSInteger)attrType value:(nullable id)value completion:(void (^)(NSDictionary * _Nullable detail, NSString * _Nullable errorMessage))completion;

/// oid 可以是任意已注册对象(view/layer/vc)
+ (nullable NSObject *)objectWithOid:(unsigned long)oid;

/// 为对象注册 oid, view 会使用其 layer 的 oid 以便与层级树节点对应
+ (unsigned long)nodeOidForObject:(NSObject *)object;

@end

NS_ASSUME_NONNULL_END
