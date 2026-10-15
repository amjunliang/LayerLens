//
//  LayerLensRuntimeReader.m
//  LayerLens
//
//  Created by YueYou on 10/12/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LayerLensRuntimeReader.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static const NSUInteger kLayerLensMaxDescriptionLength = 200;

@implementation LayerLensRuntimeReader

+ (NSDictionary *)classInfoOfObject:(NSObject *)object nodeOidBlock:(unsigned long (^)(NSObject *))nodeOidBlock {
    NSMutableArray<NSDictionary *> *classes = [NSMutableArray array];
    Class cls = object_getClass(object);
    while (cls && cls != NSObject.class) {
        [classes addObject:@{
            @"name": NSStringFromClass(cls) ?: @"",
            @"ivars": [self ivarsOfClass:cls object:object nodeOidBlock:nodeOidBlock],
            @"properties": [self propertiesOfClass:cls],
            @"methods": [self methodsOfClass:cls],
        }];
        cls = class_getSuperclass(cls);
    }
    return @{
        @"className": NSStringFromClass(object_getClass(object)) ?: @"",
        @"address": [NSString stringWithFormat:@"%p", object],
        @"description": [self safeDescriptionOfObject:object],
        @"classes": classes,
    };
}

#pragma mark - Ivar

+ (NSArray<NSDictionary *> *)ivarsOfClass:(Class)cls object:(NSObject *)object nodeOidBlock:(unsigned long (^)(NSObject *))nodeOidBlock {
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int i = 0; i < count; i++) {
        Ivar ivar = ivars[i];
        const char *name = ivar_getName(ivar);
        const char *type = ivar_getTypeEncoding(ivar);
        NSString *typeString = type ? @(type) : @"";

        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"name"] = name ? @(name) : @"?";
        item[@"type"] = [self readableType:typeString];

        if ([typeString hasPrefix:@"@"]) {
            id value = object_getIvar(object, ivar);
            item[@"value"] = value ? [self safeDescriptionOfObject:value] : @"nil";
            if (nodeOidBlock && ([value isKindOfClass:UIView.class] || [value isKindOfClass:CALayer.class])) {
                item[@"nodeOid"] = @(nodeOidBlock(value));
            }
        } else {
            void *address = (__bridge void *)object + ivar_getOffset(ivar);
            item[@"value"] = [self primitiveValueAtAddress:address type:typeString];
        }
        [result addObject:item];
    }
    free(ivars);
    return result;
}

+ (NSString *)primitiveValueAtAddress:(void *)address type:(NSString *)type {
    if (type.length == 0) {
        return @"?";
    }
    switch ([type characterAtIndex:0]) {
        case 'c': return [NSString stringWithFormat:@"%d", *(char *)address];
        case 'i': return [NSString stringWithFormat:@"%d", *(int *)address];
        case 's': return [NSString stringWithFormat:@"%d", *(short *)address];
        case 'l': return [NSString stringWithFormat:@"%ld", *(long *)address];
        case 'q': return [NSString stringWithFormat:@"%lld", *(long long *)address];
        case 'C': return [NSString stringWithFormat:@"%u", *(unsigned char *)address];
        case 'I': return [NSString stringWithFormat:@"%u", *(unsigned int *)address];
        case 'S': return [NSString stringWithFormat:@"%u", *(unsigned short *)address];
        case 'L': return [NSString stringWithFormat:@"%lu", *(unsigned long *)address];
        case 'Q': return [NSString stringWithFormat:@"%llu", *(unsigned long long *)address];
        case 'f': return [NSString stringWithFormat:@"%g", *(float *)address];
        case 'd': return [NSString stringWithFormat:@"%g", *(double *)address];
        case 'B': return *(bool *)address ? @"YES" : @"NO";
        case ':': {
            SEL sel = *(SEL *)address;
            return sel ? NSStringFromSelector(sel) : @"NULL";
        }
        case '#': {
            Class cls = *(Class __unsafe_unretained *)address;
            return cls ? NSStringFromClass(cls) : @"Nil";
        }
        case '^':
        case '*':
            return [NSString stringWithFormat:@"%p", *(void **)address];
        default:
            break;
    }
    if ([type isEqualToString:@(@encode(CGRect))]) {
        return NSStringFromCGRect(*(CGRect *)address);
    }
    if ([type isEqualToString:@(@encode(CGPoint))]) {
        return NSStringFromCGPoint(*(CGPoint *)address);
    }
    if ([type isEqualToString:@(@encode(CGSize))]) {
        return NSStringFromCGSize(*(CGSize *)address);
    }
    if ([type isEqualToString:@(@encode(UIEdgeInsets))]) {
        return NSStringFromUIEdgeInsets(*(UIEdgeInsets *)address);
    }
    if ([type isEqualToString:@(@encode(CGAffineTransform))]) {
        return NSStringFromCGAffineTransform(*(CGAffineTransform *)address);
    }
    return @"-";
}

#pragma mark - Property & Method

+ (NSArray<NSDictionary *> *)propertiesOfClass:(Class)cls {
    unsigned int count = 0;
    objc_property_t *properties = class_copyPropertyList(cls, &count);
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int i = 0; i < count; i++) {
        const char *name = property_getName(properties[i]);
        const char *attributes = property_getAttributes(properties[i]);
        [result addObject:@{
            @"name": name ? @(name) : @"?",
            @"attributes": attributes ? @(attributes) : @"",
        }];
    }
    free(properties);
    return result;
}

+ (NSArray<NSString *> *)methodsOfClass:(Class)cls {
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    unsigned int count = 0;
    Method *classMethods = class_copyMethodList(object_getClass(cls), &count);
    for (unsigned int i = 0; i < count; i++) {
        [result addObject:[@"+ " stringByAppendingString:NSStringFromSelector(method_getName(classMethods[i]))]];
    }
    free(classMethods);

    Method *instanceMethods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        [result addObject:[@"- " stringByAppendingString:NSStringFromSelector(method_getName(instanceMethods[i]))]];
    }
    free(instanceMethods);
    return result;
}

#pragma mark - Helper

+ (NSString *)safeDescriptionOfObject:(id)object {
    // 集合类 description 可能非常大, 只显示数量
    if ([object isKindOfClass:NSArray.class] || [object isKindOfClass:NSSet.class] || [object isKindOfClass:NSDictionary.class] || [object isKindOfClass:NSHashTable.class] || [object isKindOfClass:NSMapTable.class]) {
        return [NSString stringWithFormat:@"<%@: %p> count = %lu", NSStringFromClass([object class]), object, (unsigned long)[object count]];
    }
    NSString *description = nil;
    @try {
        description = [object description];
    } @catch (NSException *exception) {
        description = [NSString stringWithFormat:@"<%@: %p>", NSStringFromClass(object_getClass(object)), object];
    }
    if (description.length > kLayerLensMaxDescriptionLength) {
        description = [[description substringToIndex:kLayerLensMaxDescriptionLength] stringByAppendingString:@"..."];
    }
    return description ?: @"";
}

+ (NSString *)readableType:(NSString *)type {
    // @"UIView" -> UIView *
    if ([type hasPrefix:@"@\""] && type.length > 3) {
        return [[type substringWithRange:NSMakeRange(2, type.length - 3)] stringByAppendingString:@" *"];
    }
    NSDictionary<NSString *, NSString *> *map = @{
        @"@": @"id", @"@?": @"block", @"c": @"char", @"i": @"int", @"s": @"short", @"l": @"long",
        @"q": @"long long", @"C": @"unsigned char", @"I": @"unsigned int", @"S": @"unsigned short",
        @"L": @"unsigned long", @"Q": @"unsigned long long", @"f": @"float", @"d": @"double",
        @"B": @"BOOL", @":": @"SEL", @"#": @"Class", @"*": @"char *",
    };
    if (map[type]) {
        return map[type];
    }
    // {CGRect={CGPoint=dd}{CGSize=dd}} -> CGRect
    if ([type hasPrefix:@"{"]) {
        NSRange equal = [type rangeOfString:@"="];
        if (equal.location != NSNotFound) {
            return [type substringWithRange:NSMakeRange(1, equal.location - 1)];
        }
    }
    return type;
}

@end
