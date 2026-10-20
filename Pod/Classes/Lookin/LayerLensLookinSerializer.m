//
//  LayerLensLookinSerializer.m
//  LayerLens
//
//  Created by YueYou on 10/12/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LayerLensLookinSerializer.h"
#import "LookinDisplayItem.h"
#import "LookinObject.h"
#import "LookinIvarTrace.h"
#import "LookinAttributesGroup.h"
#import "LookinAttributesSection.h"
#import "LookinAttribute.h"
#import "LookinDashboardBlueprint.h"
#import "LookinEventHandler.h"
#import "LookinTuple.h"
#import "NSObject+LookinServer.h"
#import "CALayer+LookinServer.h"

@implementation LayerLensLookinSerializer

#pragma mark - Node

+ (NSDictionary *)nodeFromDisplayItem:(LookinDisplayItem *)item parentRect:(CGRect)parentRect {
    LookinObject *displayObject = item.viewObject ?: item.layerObject;
    CALayer *layer = item.layerObject ? (CALayer *)[NSObject lks_objectWithOid:item.layerObject.oid] : nil;

    CGRect rect = CGRectZero;
    if ([layer isKindOfClass:CALayer.class]) {
        rect = [self screenRectOfLayer:layer];
    } else {
        // 自定义节点(如 SwiftUI)没有 layer, frame 相对父节点
        rect = CGRectOffset(item.frame, parentRect.origin.x, parentRect.origin.y);
    }

    NSMutableArray<NSDictionary *> *children = [NSMutableArray arrayWithCapacity:item.subitems.count];
    for (LookinDisplayItem *subitem in item.subitems) {
        [children addObject:[self nodeFromDisplayItem:subitem parentRect:rect]];
    }

    NSMutableArray<NSString *> *traces = [NSMutableArray array];
    for (LookinIvarTrace *trace in displayObject.ivarTraces) {
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
    node[@"text"] = [self displayTextOfView:[layer isKindOfClass:CALayer.class] ? layer.lks_hostView : nil] ?: [NSNull null];
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
    UIWindow *window = layer.lks_window;
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

+ (NSArray<NSDictionary *> *)attrGroupsFromGroups:(NSArray<LookinAttributesGroup *> *)groups custom:(BOOL)custom {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:groups.count];
    for (LookinAttributesGroup *group in groups) {
        NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];
        for (LookinAttributesSection *section in group.attrSections) {
            NSMutableArray<NSDictionary *> *attrs = [NSMutableArray array];
            for (LookinAttribute *attr in section.attributes) {
                [attrs addObject:[self attrFromAttribute:attr custom:custom]];
            }
            NSString *sectionTitle = custom ? nil : [LookinDashboardBlueprint sectionTitleWithSectionID:section.identifier];
            [sections addObject:@{
                @"id": section.identifier ?: @"",
                @"title": sectionTitle ?: [NSNull null],
                @"attrs": attrs,
            }];
        }
        NSString *title = group.userCustomTitle ?: [LookinDashboardBlueprint groupTitleWithGroupID:group.identifier];
        [result addObject:@{
            @"id": group.identifier ?: @"",
            @"title": title ?: group.identifier ?: @"",
            @"custom": @(custom),
            @"sections": sections,
        }];
    }
    return result;
}

+ (NSDictionary *)attrFromAttribute:(LookinAttribute *)attr custom:(BOOL)custom {
    NSString *title = attr.displayTitle;
    NSString *enumList = nil;
    BOOL editable = NO;
    if (!custom) {
        title = [LookinDashboardBlueprint briefTitleWithAttrID:attr.identifier] ?: title;
        enumList = [LookinDashboardBlueprint enumListNameWithAttrID:attr.identifier];
        editable = [LookinDashboardBlueprint setterWithAttrID:attr.identifier] != nil && [self isEditableAttrType:attr.attrType];
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

+ (NSArray<NSDictionary *> *)eventHandlersFromHandlers:(NSArray<LookinEventHandler *> *)handlers {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:handlers.count];
    for (LookinEventHandler *handler in handlers) {
        NSMutableArray<NSArray<NSString *> *> *targetActions = [NSMutableArray array];
        for (LookinStringTwoTuple *tuple in handler.targetActions) {
            [targetActions addObject:@[tuple.first ?: @"", tuple.second ?: @""]];
        }
        [result addObject:@{
            @"type": handler.handlerType == LookinEventHandlerTypeGesture ? @"gesture" : @"targetAction",
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

+ (BOOL)isEditableAttrType:(LookinAttrType)attrType {
    switch (attrType) {
        case LookinAttrTypeChar:
        case LookinAttrTypeInt:
        case LookinAttrTypeShort:
        case LookinAttrTypeLong:
        case LookinAttrTypeLongLong:
        case LookinAttrTypeUnsignedChar:
        case LookinAttrTypeUnsignedInt:
        case LookinAttrTypeUnsignedShort:
        case LookinAttrTypeUnsignedLong:
        case LookinAttrTypeUnsignedLongLong:
        case LookinAttrTypeFloat:
        case LookinAttrTypeDouble:
        case LookinAttrTypeBOOL:
        case LookinAttrTypeEnumInt:
        case LookinAttrTypeEnumLong:
        case LookinAttrTypeCGPoint:
        case LookinAttrTypeCGVector:
        case LookinAttrTypeCGSize:
        case LookinAttrTypeCGRect:
        case LookinAttrTypeCGAffineTransform:
        case LookinAttrTypeUIEdgeInsets:
        case LookinAttrTypeUIOffset:
        case LookinAttrTypeNSString:
        case LookinAttrTypeUIColor:
            return YES;
        default:
            return NO;
    }
}

+ (id)JSONValueFromValue:(id)value attrType:(LookinAttrType)attrType {
    if (!value || value == [NSNull null]) {
        return [NSNull null];
    }
    if ([value isKindOfClass:NSValue.class] && ![value isKindOfClass:NSNumber.class]) {
        NSValue *v = value;
        switch (attrType) {
            case LookinAttrTypeCGPoint: {
                CGPoint p = v.CGPointValue;
                return @[[self safeNumber:p.x], [self safeNumber:p.y]];
            }
            case LookinAttrTypeCGVector: {
                CGVector p = v.CGVectorValue;
                return @[[self safeNumber:p.dx], [self safeNumber:p.dy]];
            }
            case LookinAttrTypeCGSize: {
                CGSize s = v.CGSizeValue;
                return @[[self safeNumber:s.width], [self safeNumber:s.height]];
            }
            case LookinAttrTypeCGRect:
                return [self arrayFromRect:v.CGRectValue];
            case LookinAttrTypeCGAffineTransform: {
                CGAffineTransform t = v.CGAffineTransformValue;
                return @[[self safeNumber:t.a], [self safeNumber:t.b], [self safeNumber:t.c], [self safeNumber:t.d], [self safeNumber:t.tx], [self safeNumber:t.ty]];
            }
            case LookinAttrTypeUIEdgeInsets: {
                UIEdgeInsets i = v.UIEdgeInsetsValue;
                return @[[self safeNumber:i.top], [self safeNumber:i.left], [self safeNumber:i.bottom], [self safeNumber:i.right]];
            }
            case LookinAttrTypeUIOffset: {
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
            [array addObject:[self JSONValueFromValue:obj attrType:LookinAttrTypeNone]];
        }
        return array;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            dict[[key description]] = [self JSONValueFromValue:obj attrType:LookinAttrTypeNone];
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

+ (id)modificationValueFromJSONValue:(id)value attrType:(LookinAttrType)attrType supported:(BOOL *)supported {
    BOOL ok = YES;
    id result = nil;
    NSArray<NSNumber *> *numbers = [value isKindOfClass:NSArray.class] ? value : nil;
    switch (attrType) {
        case LookinAttrTypeChar:
        case LookinAttrTypeInt:
        case LookinAttrTypeShort:
        case LookinAttrTypeLong:
        case LookinAttrTypeLongLong:
        case LookinAttrTypeUnsignedChar:
        case LookinAttrTypeUnsignedInt:
        case LookinAttrTypeUnsignedShort:
        case LookinAttrTypeUnsignedLong:
        case LookinAttrTypeUnsignedLongLong:
        case LookinAttrTypeFloat:
        case LookinAttrTypeDouble:
        case LookinAttrTypeEnumInt:
        case LookinAttrTypeEnumLong:
            result = [value isKindOfClass:NSNumber.class] ? value : @([[value description] doubleValue]);
            break;
        case LookinAttrTypeBOOL:
            result = @([value boolValue]);
            break;
        case LookinAttrTypeNSString:
            result = [value isKindOfClass:NSString.class] ? value : nil;
            break;
        case LookinAttrTypeUIColor:
            // nil 表示清除颜色
            result = numbers.count == 4 ? numbers : nil;
            break;
        case LookinAttrTypeCGPoint:
            ok = numbers.count == 2;
            result = ok ? [NSValue valueWithCGPoint:CGPointMake(numbers[0].doubleValue, numbers[1].doubleValue)] : nil;
            break;
        case LookinAttrTypeCGVector:
            ok = numbers.count == 2;
            result = ok ? [NSValue valueWithCGVector:CGVectorMake(numbers[0].doubleValue, numbers[1].doubleValue)] : nil;
            break;
        case LookinAttrTypeCGSize:
            ok = numbers.count == 2;
            result = ok ? [NSValue valueWithCGSize:CGSizeMake(numbers[0].doubleValue, numbers[1].doubleValue)] : nil;
            break;
        case LookinAttrTypeCGRect:
            ok = numbers.count == 4;
            result = ok ? [NSValue valueWithCGRect:CGRectMake(numbers[0].doubleValue, numbers[1].doubleValue, numbers[2].doubleValue, numbers[3].doubleValue)] : nil;
            break;
        case LookinAttrTypeCGAffineTransform:
            ok = numbers.count == 6;
            result = ok ? [NSValue valueWithCGAffineTransform:CGAffineTransformMake(numbers[0].doubleValue, numbers[1].doubleValue, numbers[2].doubleValue, numbers[3].doubleValue, numbers[4].doubleValue, numbers[5].doubleValue)] : nil;
            break;
        case LookinAttrTypeUIEdgeInsets:
            ok = numbers.count == 4;
            result = ok ? [NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(numbers[0].doubleValue, numbers[1].doubleValue, numbers[2].doubleValue, numbers[3].doubleValue)] : nil;
            break;
        case LookinAttrTypeUIOffset:
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
