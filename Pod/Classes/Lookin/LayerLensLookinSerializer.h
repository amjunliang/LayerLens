//
//  LayerLensLookinSerializer.h
//  LayerLens
//
//  Created by YueYou on 10/12/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import <UIKit/UIKit.h>
#import "LayerLens_AttrType.h"

@class LayerLens_DisplayItem, LayerLens_AttributesGroup, LayerLens_EventHandler;

NS_ASSUME_NONNULL_BEGIN

/// Lookin 模型 <-> JSON 对象
@interface LayerLensLookinSerializer : NSObject

/// 递归转换节点, rect 为屏幕坐标
+ (NSDictionary *)nodeFromDisplayItem:(LayerLens_DisplayItem *)item parentRect:(CGRect)parentRect;

+ (NSArray<NSDictionary *> *)attrGroupsFromGroups:(nullable NSArray<LayerLens_AttributesGroup *> *)groups custom:(BOOL)custom;

+ (NSArray<NSDictionary *> *)eventHandlersFromHandlers:(nullable NSArray<LayerLens_EventHandler *> *)handlers;

/// 属性值 -> JSON 值
+ (id)JSONValueFromValue:(nullable id)value attrType:(LayerLens_AttrType)attrType;

/// JSON 值 -> 修改用的属性值, 不支持的类型返回 nil 并设置 supported 为 NO
+ (nullable id)modificationValueFromJSONValue:(nullable id)value attrType:(LayerLens_AttrType)attrType supported:(BOOL *)supported;

+ (BOOL)isEditableAttrType:(LayerLens_AttrType)attrType;

/// layer 在屏幕坐标系中的 rect
+ (CGRect)screenRectOfLayer:(CALayer *)layer;

@end

NS_ASSUME_NONNULL_END
