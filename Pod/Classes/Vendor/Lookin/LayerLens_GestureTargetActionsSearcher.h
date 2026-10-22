
//
//  LayerLens_GestureTargetActionsSearcher.h
//  LayerLens_Server
//
//  Created by likai.123 on 2023/9/11.
//

#import <UIKit/UIKit.h>

@class LayerLens_TwoTuple;

NS_ASSUME_NONNULL_BEGIN

@interface LayerLens_GestureTargetActionsSearcher : NSObject

/// 返回一个 UIGestureRecognizer 实例身上绑定的 target & action 信息
/// tuple.first => LayerLens_WeakContainer(包裹着 target)，tuple.second => action(方法名字符串)
+ (NSArray<LayerLens_TwoTuple *> *)getTargetActionsFromRecognizer:(UIGestureRecognizer *)recognizer;

@end

NS_ASSUME_NONNULL_END

