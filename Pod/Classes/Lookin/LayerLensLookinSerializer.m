//
//  LayerLensLookinSerializer.m
//  LayerLens
//
//  Created by YueYou on 10/12/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LayerLensLookinSerializer.h"
#import "LayerLens_DisplayItem.h"
#import "LayerLens_Object.h"
#import "LayerLens_IvarTrace.h"
#import "LayerLens_AttributesGroup.h"
#import "LayerLens_AttributesSection.h"
#import "LayerLens_Attribute.h"
#import "LayerLens_DashboardBlueprint.h"
#import "LayerLens_EventHandler.h"
#import "LayerLens_Tuple.h"
#import "NSObject+LayerLens_Server.h"
#import "CALayer+LayerLens_Server.h"

@implementation LayerLensLookinSerializer

#pragma mark - Node

+ (NSDictionary *)nodeFromDisplayItem:(LayerLens_DisplayItem *)item parentRect:(CGRect)parentRect {
    LayerLens_Object *displayObject = item.viewObject ?: item.layerObject;
    CALayer *layer = item.layerObject ? (CALayer *)[NSObject layerlens_objectWithOid:item.layerObject.oid] : nil;

    CGRect rect = CGRectZero;
    if ([layer isKindOfClass:CALayer.class]) {
        rect = [self screenRectOfLayer:layer];
    } else {
        // 自定义节点(如 SwiftUI)没有 layer, frame 相对父节点
        rect = CGRectOffset(item.frame, parentRect.origin.x, parentRect.origin.y);
    }

    NSMutableArray<NSDictionary *> *children = [NSMutableArray arrayWithCapacity:item.subitems.count];
    for (LayerLens_DisplayItem *subitem in item.subitems) {
        [children addObject:[self nodeFromDisplayItem:subitem parentRect:rect]];
    }

    NSMutableArray<NSString *> *traces = [NSMutableArray array];
    for (LayerLens_IvarTrace *trace in displayObject.ivarTraces) {
        [traces addObject:[NSString stringWithFormat:@"%@.%@", trace.hostClassName ?: @"?", trace.ivarName ?: @"?"]];
    }

    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    node[@"oid"] = @(item.layerObject.oid);
    node[@"viewOid"] = item.viewObject ? @(item.viewObject.oid) : [NSNull null];
    node[@"classChain"] = displayObject.classChainList ?: @[item.customDisplayTitle ?: @"Unknown"];
    node[@"address"] = displayObject.memoryAddress ?: @"";
    node[@"isLayer"] = @(item.viewObject == nil && item.layerObject != nil);
    node[@"vcClass"] = item.hostViewControllerObject.classChainList.firstObject ?: [NSNull null];
    node[@"vcOid"] = item.hostViewControllerObject ? @(item.hostViewControllerObject.oid) : [NSNull null];
    node[@"ivarTraces"] = traces;
    node[@"specialTrace"] = displayObject.specialTrace ?: [NSNull null];
    node[@"title"] = item.customDisplayTitle ?: [NSNull null];
    node[@"text"] = [self displayTextOfView:[layer isKindOfClass:CALayer.class] ? layer.layerlens_hostView : nil] ?: [NSNull null];
    node[@"frame"] = [self arrayFromRect:item.frame];
    node[@"rect"] = [self arrayFromRect:rect];
    node[@"hidden"] = @(item.isHidden);
    node[@"alpha"] = [self safeNumber:item.alpha];
    node[@"keyWindow"] = @(item.representedAsKeyWindow);
    // 手势与 UIControl 事件, 树中据此显示事件标记
    if (item.eventHandlers.count) {
        node[@"events"] = [self eventHandlersFromHandlers:item.eventHandlers];
    }
    node[@"children"] = children;
    return node;
}

/// 控件上显示的文字, 便于按字符串搜索源码
+ (NSString *)displayTextOfView:(UIView *)view {
    NSString *text = nil;
    if ([view isKindOfClass:UILabel.class]) {
        text = ((UILabel *)view).text;
    } else if ([view isKindOfClass:UIButton.class]) {
        text = ((UIButton *)view).currentTitle;
    } else if ([view isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)view;
        text = field.text.length > 0 ? field.text : field.placeholder;
    } else if ([view isKindOfClass:UITextView.class]) {
        text = ((UITextView *)view).text;
    }
    if (text.length == 0) {
        return nil;
    }
    return text.length > 40 ? [[text substringToIndex:40] stringByAppendingString:@"..."] : text;
}

+ (CGRect)screenRectOfLayer:(CALayer *)layer {
    UIWindow *window = layer.layerlens_window;
    if (!window) {
        return layer.frame;
    }
    if (layer == window.layer) {
        return window.frame;
    }
    CGRect rect = [layer convertRect:layer.bounds toLayer:window.layer];
    return CGRectOffset(rect, window.frame.origin.x, window.frame.origin.y);
}

#pragma mark - Attribute

+ (NSArray<NSDictionary *> *)attrGroupsFromGroups:(NSArray<LayerLens_AttributesGroup *> *)groups custom:(BOOL)custom {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:groups.count];
    for (LayerLens_AttributesGroup *group in groups) {
        NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];
        for (LayerLens_AttributesSection *section in group.attrSections) {
            NSMutableArray<NSDictionary *> *attrs = [NSMutableArray array];
            for (LayerLens_Attribute *attr in section.attributes) {
                [attrs addObject:[self attrFromAttribute:attr custom:custom]];
            }
            NSString *sectionTitle = custom ? nil : [LayerLens_DashboardBlueprint sectionTitleWithSectionID:section.identifier];
            [sections addObject:@{
                @"id": section.identifier ?: @"",
                @"title": sectionTitle ?: [NSNull null],
                @"attrs": attrs,
            }];
        }
        NSString *title = group.userCustomTitle ?: [LayerLens_DashboardBlueprint groupTitleWithGroupID:group.identifier];
        [result addObject:@{
            @"id": group.identifier ?: @"",
            @"title": title ?: group.identifier ?: @"",
            @"custom": @(custom),
            @"sections": sections,
        }];
    }
    return result;
}

+ (NSDictionary *)attrFromAttribute:(LayerLens_Attribute *)attr custom:(BOOL)custom {
    NSString *title = attr.displayTitle;
    NSString *enumList = nil;
    BOOL editable = NO;
    if (!custom) {
        title = [LayerLens_DashboardBlueprint briefTitleWithAttrID:attr.identifier] ?: title;
        enumList = [LayerLens_DashboardBlueprint enumListNameWithAttrID:attr.identifier];
        editable = [LayerLens_DashboardBlueprint setterWithAttrID:attr.identifier] != nil && [self isEditableAttrType:attr.attrType];
    }
    return @{
        @"id": attr.identifier ?: @"",
        @"title": title ?: attr.identifier ?: @"",
        @"type": @(attr.attrType),
        @"value": [self JSONValueFromValue:attr.value attrType:attr.attrType],
        @"editable": @(editable),
        @"enumList": enumList ?: [NSNull null],
    };
}

+ (NSArray<NSDictionary *> *)eventHandlersFromHandlers:(NSArray<LayerLens_EventHandler *> *)handlers {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:handlers.count];
    for (LayerLens_EventHandler *handler in handlers) {
        NSMutableArray<NSArray<NSString *> *> *targetActions = [NSMutableArray array];
        for (LayerLens_StringTwoTuple *tuple in handler.targetActions) {
            [targetActions addObject:@[tuple.first ?: @"", tuple.second ?: @""]];
        }
        [result addObject:@{
            @"type": handler.handlerType == LayerLens_EventHandlerTypeGesture ? @"gesture" : @"targetAction",
            @"name": handler.eventName ?: @"",
            @"inherited": handler.inheritedRecognizerName ?: [NSNull null],
            @"enabled": @(handler.gestureRecognizerIsEnabled),
            @"delegate": handler.gestureRecognizerDelegator ?: [NSNull null],
            @"ivarTraces": handler.recognizerIvarTraces ?: @[],
            @"targetActions": targetActions,
        }];
    }
    return result;
}

#pragma mark - Value

+ (BOOL)isEditableAttrType:(LayerLens_AttrType)attrType {
    switch (attrType) {
        case LayerLens_AttrTypeChar:
        case LayerLens_AttrTypeInt:
        case LayerLens_AttrTypeShort:
        case LayerLens_AttrTypeLong:
        case LayerLens_AttrTypeLongLong:
        case LayerLens_AttrTypeUnsignedChar:
        case LayerLens_AttrTypeUnsignedInt:
        case LayerLens_AttrTypeUnsignedShort:
        case LayerLens_AttrTypeUnsignedLong:
        case LayerLens_AttrTypeUnsignedLongLong:
        case LayerLens_AttrTypeFloat:
        case LayerLens_AttrTypeDouble:
        case LayerLens_AttrTypeBOOL:
        case LayerLens_AttrTypeEnumInt:
        case LayerLens_AttrTypeEnumLong:
        case LayerLens_AttrTypeCGPoint:
        case LayerLens_AttrTypeCGVector:
        case LayerLens_AttrTypeCGSize:
        case LayerLens_AttrTypeCGRect:
        case LayerLens_AttrTypeCGAffineTransform:
        case LayerLens_AttrTypeUIEdgeInsets:
        case LayerLens_AttrTypeUIOffset:
        case LayerLens_AttrTypeNSString:
        case LayerLens_AttrTypeUIColor:
            return YES;
        default:
            return NO;
    }
}

+ (id)JSONValueFromValue:(id)value attrType:(LayerLens_AttrType)attrType {
    if (!value || value == [NSNull null]) {
        return [NSNull null];
    }
    if ([value isKindOfClass:NSValue.class] && ![value isKindOfClass:NSNumber.class]) {
        NSValue *v = value;
        switch (attrType) {
            case LayerLens_AttrTypeCGPoint: {
                CGPoint p = v.CGPointValue;
                return @[[self safeNumber:p.x], [self safeNumber:p.y]];
            }
            case LayerLens_AttrTypeCGVector: {
                CGVector p = v.CGVectorValue;
                return @[[self safeNumber:p.dx], [self safeNumber:p.dy]];
            }
            case LayerLens_AttrTypeCGSize: {
                CGSize s = v.CGSizeValue;
                return @[[self safeNumber:s.width], [self safeNumber:s.height]];
            }
            case LayerLens_AttrTypeCGRect:
                return [self arrayFromRect:v.CGRectValue];
            case LayerLens_AttrTypeCGAffineTransform: {
                CGAffineTransform t = v.CGAffineTransformValue;
                return @[[self safeNumber:t.a], [self safeNumber:t.b], [self safeNumber:t.c], [self safeNumber:t.d], [self safeNumber:t.tx], [self safeNumber:t.ty]];
            }
            case LayerLens_AttrTypeUIEdgeInsets: {
                UIEdgeInsets i = v.UIEdgeInsetsValue;
                return @[[self safeNumber:i.top], [self safeNumber:i.left], [self safeNumber:i.bottom], [self safeNumber:i.right]];
            }
            case LayerLens_AttrTypeUIOffset: {
                UIOffset o = v.UIOffsetValue;
                return @[[self safeNumber:o.horizontal], [self safeNumber:o.vertical]];
            }
            default:
                return v.description ?: @"";
        }
    }
    if ([value isKindOfClass:NSNumber.class]) {
        return [self sanitizeNumber:value];
    }
    if ([value isKindOfClass:NSString.class]) {
        return value;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *array = [NSMutableArray arrayWithCapacity:[value count]];
        for (id obj in value) {
            [array addObject:[self JSONValueFromValue:obj attrType:LayerLens_AttrTypeNone]];
        }
        return array;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            dict[[key description]] = [self JSONValueFromValue:obj attrType:LayerLens_AttrTypeNone];
        }];
        return dict;
    }
    if ([value isKindOfClass:UIColor.class]) {
        CGFloat r = 0, g = 0, b = 0, a = 0;
        [(UIColor *)value getRed:&r green:&g blue:&b alpha:&a];
        return @[@(r), @(g), @(b), @(a)];
    }
    return [value description] ?: @"";
}

+ (id)modificationValueFromJSONValue:(id)value attrType:(LayerLens_AttrType)attrType supported:(BOOL *)supported {
    BOOL ok = YES;
    id result = nil;
    NSArray<NSNumber *> *numbers = [value isKindOfClass:NSArray.class] ? value : nil;
    switch (attrType) {
        case LayerLens_AttrTypeChar:
        case LayerLens_AttrTypeInt:
        case LayerLens_AttrTypeShort:
        case LayerLens_AttrTypeLong:
        case LayerLens_AttrTypeLongLong:
        case LayerLens_AttrTypeUnsignedChar:
        case LayerLens_AttrTypeUnsignedInt:
        case LayerLens_AttrTypeUnsignedShort:
        case LayerLens_AttrTypeUnsignedLong:
        case LayerLens_AttrTypeUnsignedLongLong:
        case LayerLens_AttrTypeFloat:
        case LayerLens_AttrTypeDouble:
        case LayerLens_AttrTypeEnumInt:
        case LayerLens_AttrTypeEnumLong:
            result = [value isKindOfClass:NSNumber.class] ? value : @([[value description] doubleValue]);
            break;
        case LayerLens_AttrTypeBOOL:
            result = @([value boolValue]);
            break;
        case LayerLens_AttrTypeNSString:
            result = [value isKindOfClass:NSString.class] ? value : nil;
            break;
        case LayerLens_AttrTypeUIColor:
            // nil 表示清除颜色
            result = numbers.count == 4 ? numbers : nil;
            break;
        case LayerLens_AttrTypeCGPoint:
            ok = numbers.count == 2;
            result = ok ? [NSValue valueWithCGPoint:CGPointMake(numbers[0].doubleValue, numbers[1].doubleValue)] : nil;
            break;
        case LayerLens_AttrTypeCGVector:
            ok = numbers.count == 2;
            result = ok ? [NSValue valueWithCGVector:CGVectorMake(numbers[0].doubleValue, numbers[1].doubleValue)] : nil;
            break;
        case LayerLens_AttrTypeCGSize:
            ok = numbers.count == 2;
            result = ok ? [NSValue valueWithCGSize:CGSizeMake(numbers[0].doubleValue, numbers[1].doubleValue)] : nil;
            break;
        case LayerLens_AttrTypeCGRect:
            ok = numbers.count == 4;
            result = ok ? [NSValue valueWithCGRect:CGRectMake(numbers[0].doubleValue, numbers[1].doubleValue, numbers[2].doubleValue, numbers[3].doubleValue)] : nil;
            break;
        case LayerLens_AttrTypeCGAffineTransform:
            ok = numbers.count == 6;
            result = ok ? [NSValue valueWithCGAffineTransform:CGAffineTransformMake(numbers[0].doubleValue, numbers[1].doubleValue, numbers[2].doubleValue, numbers[3].doubleValue, numbers[4].doubleValue, numbers[5].doubleValue)] : nil;
            break;
        case LayerLens_AttrTypeUIEdgeInsets:
            ok = numbers.count == 4;
            result = ok ? [NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(numbers[0].doubleValue, numbers[1].doubleValue, numbers[2].doubleValue, numbers[3].doubleValue)] : nil;
            break;
        case LayerLens_AttrTypeUIOffset:
            ok = numbers.count == 2;
            result = ok ? [NSValue valueWithUIOffset:UIOffsetMake(numbers[0].doubleValue, numbers[1].doubleValue)] : nil;
            break;
        default:
            ok = NO;
            break;
    }
    if (supported) {
        *supported = ok;
    }
    return result;
}

#pragma mark - Helper

+ (NSArray<NSNumber *> *)arrayFromRect:(CGRect)rect {
    return @[[self safeNumber:rect.origin.x], [self safeNumber:rect.origin.y], [self safeNumber:rect.size.width], [self safeNumber:rect.size.height]];
}

/// NaN/Inf 无法 JSON 序列化
+ (NSNumber *)safeNumber:(double)value {
    if (isnan(value) || isinf(value)) {
        return @0;
    }
    return @(value);
}

+ (id)sanitizeNumber:(NSNumber *)number {
    double value = number.doubleValue;
    if (isnan(value) || isinf(value)) {
        return number.description ?: @"NaN";
    }
    return number;
}

@end
