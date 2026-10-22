
//
//  LayerLens_AttrGroupsMaker.m
//  LayerLens_Server
//
//  Created by Li Kai on 2019/6/6.
//  https://lookin.work
//

#import "LayerLens_AttrGroupsMaker.h"
#import "LayerLens_AttributesGroup.h"
#import "LayerLens_AttributesSection.h"
#import "LayerLens_Attribute.h"
#import "LayerLens_DashboardBlueprint.h"
#import "LayerLens_IvarTrace.h"
#import "UIColor+LayerLens_Server.h"
#import "LayerLens_ServerDefines.h"

@implementation LayerLens_AttrGroupsMaker

+ (NSArray<LayerLens_AttributesGroup *> *)attrGroupsForLayer:(CALayer *)layer {
    if (!layer) {
        NSAssert(NO, @"");
        return nil;
    }
    NSArray<LayerLens_AttributesGroup *> *groups = [[LayerLens_DashboardBlueprint groupIDs] layerlens_map:^id(NSUInteger idx, LayerLens_AttrGroupIdentifier groupID) {
        LayerLens_AttributesGroup *group = [LayerLens_AttributesGroup new];
        group.identifier = groupID;

        NSArray<LayerLens_AttrSectionIdentifier> *secIDs = [LayerLens_DashboardBlueprint sectionIDsForGroupID:groupID];
        group.attrSections = [secIDs layerlens_map:^id(NSUInteger idx, LayerLens_AttrSectionIdentifier secID) {
            LayerLens_AttributesSection *sec = [LayerLens_AttributesSection new];
            sec.identifier = secID;
            
            NSArray<LayerLens_AttrIdentifier> *attrIDs = [LayerLens_DashboardBlueprint attrIDsForSectionID:secID];
            sec.attributes = [attrIDs layerlens_map:^id(NSUInteger idx, LayerLens_AttrIdentifier attrID) {
                NSInteger minAvailableVersion = [LayerLens_DashboardBlueprint minAvailableOSVersionWithAttrID:attrID];
                if (minAvailableVersion > 0 && (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < minAvailableVersion)) {
                    // iOS 版本过低不支持该属性
                    return nil;
                }
                
                id targetObj = nil;
                if ([LayerLens_DashboardBlueprint isUIViewPropertyWithAttrID:attrID]) {
                    targetObj = layer.layerlens_hostView;
                } else {
                    targetObj = layer;
                }
                
                if (targetObj) {
                    Class targetClass = NSClassFromString([LayerLens_DashboardBlueprint classNameWithAttrID:attrID]);
                    if (![targetObj isKindOfClass:targetClass]) {
                        return nil;
                    }
                    
                    LayerLens_Attribute *attr = [self _attributeWithIdentifer:attrID targetObject:targetObj];
                    return attr;
                } else {
                    return nil;
                }
            }];
            
            if (sec.attributes.count) {
                return sec;
            } else {
                return nil;
            }
        }];
        
        if ([groupID isEqualToString:LayerLens_AttrGroup_AutoLayout]) {
            // 这里特殊处理一下，如果 AutoLayout 里面不包含 Constraints 的话（只有 Hugging 和 Resistance），就丢弃掉这整个 AutoLayout 不显示
            BOOL hasConstraits = [group.attrSections layerlens_any:^BOOL(LayerLens_AttributesSection *obj) {
                return [obj.identifier isEqualToString:LayerLens_AttrSec_AutoLayout_Constraints];
            }];
            if (!hasConstraits) {
                return nil;
            }
        }
        
        if (group.attrSections.count) {
            return group;
        } else {
            return nil;
        }
    }];
    
    return groups;
}

+ (LayerLens_Attribute *)_attributeWithIdentifer:(LayerLens_AttrIdentifier)identifier targetObject:(id)target {
    if (!target) {
        NSAssert(NO, @"");
        return nil;
    }
    
    LayerLens_Attribute *attribute = [LayerLens_Attribute new];
    attribute.identifier = identifier;
    
    SEL getter = [LayerLens_DashboardBlueprint getterWithAttrID:identifier];
    if (!getter) {
        NSAssert(NO, @"");
        return nil;
    }
    if (![target respondsToSelector:getter]) {
        // 比如某些 QMUI 的属性，不引入 QMUI 就会走到这个分支里
        return nil;
    }
    NSMethodSignature *signature = [target methodSignatureForSelector:getter];
    if (signature.numberOfArguments > 2) {
        NSAssert(NO, @"getter 不可以有参数");
        return nil;
    }
    if (strcmp([signature methodReturnType], @encode(void)) == 0) {
        NSAssert(NO, @"getter 返回值不能为 void");
        return nil;
    }
    
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = getter;
    [invocation invoke];
    
    const char *returnType = [signature methodReturnType];
    
    if (strcmp(returnType, @encode(char)) == 0) {
        char targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.attrType = LayerLens_AttrTypeChar;
        attribute.value = @(targetValue);
        
    } else if (strcmp(returnType, @encode(int)) == 0) {
        int targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.value = @(targetValue);
        if ([LayerLens_DashboardBlueprint enumListNameWithAttrID:identifier]) {
            attribute.attrType = LayerLens_AttrTypeEnumInt;
        } else {
            attribute.attrType = LayerLens_AttrTypeInt;
        }
        
    } else if (strcmp(returnType, @encode(short)) == 0) {
        short targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.attrType = LayerLens_AttrTypeShort;
        attribute.value = @(targetValue);
        
    } else if (strcmp(returnType, @encode(long)) == 0) {
        long targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.value = @(targetValue);
        if ([LayerLens_DashboardBlueprint enumListNameWithAttrID:identifier]) {
            attribute.attrType = LayerLens_AttrTypeEnumLong;
        } else {
            attribute.attrType = LayerLens_AttrTypeLong;
        }
        
    } else if (strcmp(returnType, @encode(long long)) == 0) {
        long long targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.attrType = LayerLens_AttrTypeLongLong;
        attribute.value = @(targetValue);
        
    } else if (strcmp(returnType, @encode(unsigned char)) == 0) {
        unsigned char targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.attrType = LayerLens_AttrTypeUnsignedChar;
        attribute.value = @(targetValue);
        
    } else if (strcmp(returnType, @encode(unsigned int)) == 0) {
        unsigned int targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.attrType = LayerLens_AttrTypeUnsignedInt;
        attribute.value = @(targetValue);
        
    } else if (strcmp(returnType, @encode(unsigned short)) == 0) {
        unsigned short targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.attrType = LayerLens_AttrTypeUnsignedShort;
        attribute.value = @(targetValue);
        
    } else if (strcmp(returnType, @encode(unsigned long)) == 0) {
        unsigned long targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.attrType = LayerLens_AttrTypeUnsignedLong;
        attribute.value = @(targetValue);
        
    } else if (strcmp(returnType, @encode(unsigned long long)) == 0) {
        unsigned long long targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.attrType = LayerLens_AttrTypeUnsignedLongLong;
        attribute.value = @(targetValue);
        
    } else if (strcmp(returnType, @encode(float)) == 0) {
        float targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.attrType = LayerLens_AttrTypeFloat;
        attribute.value = @(targetValue);
        
    } else if (strcmp(returnType, @encode(double)) == 0) {
        double targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.attrType = LayerLens_AttrTypeDouble;
        attribute.value = @(targetValue);
        
    } else if (strcmp(returnType, @encode(BOOL)) == 0) {
        BOOL targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.attrType = LayerLens_AttrTypeBOOL;
        attribute.value = @(targetValue);
        
    } else if (strcmp(returnType, @encode(SEL)) == 0) {
        SEL targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.attrType = LayerLens_AttrTypeSel;
        attribute.value = NSStringFromSelector(targetValue);
        
    } else if (strcmp(returnType, @encode(Class)) == 0) {
        Class targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.attrType = LayerLens_AttrTypeClass;
        attribute.value = NSStringFromClass(targetValue);
        
    } else if (strcmp(returnType, @encode(CGPoint)) == 0) {
        CGPoint targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.attrType = LayerLens_AttrTypeCGPoint;
        attribute.value = [NSValue valueWithCGPoint:targetValue];
        
    } else if (strcmp(returnType, @encode(CGVector)) == 0) {
        CGVector targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.attrType = LayerLens_AttrTypeCGVector;
        attribute.value = [NSValue valueWithCGVector:targetValue];
        
    } else if (strcmp(returnType, @encode(CGSize)) == 0) {
        CGSize targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.attrType = LayerLens_AttrTypeCGSize;
        attribute.value = [NSValue valueWithCGSize:targetValue];
        
    } else if (strcmp(returnType, @encode(CGRect)) == 0) {
        CGRect targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.attrType = LayerLens_AttrTypeCGRect;
        attribute.value = [NSValue valueWithCGRect:targetValue];
        
    } else if (strcmp(returnType, @encode(CGAffineTransform)) == 0) {
        CGAffineTransform targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.attrType = LayerLens_AttrTypeCGAffineTransform;
        attribute.value = [NSValue valueWithCGAffineTransform:targetValue];
        
    } else if (strcmp(returnType, @encode(UIEdgeInsets)) == 0) {
        UIEdgeInsets targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.attrType = LayerLens_AttrTypeUIEdgeInsets;
        attribute.value = [NSValue valueWithUIEdgeInsets:targetValue];
        
    } else if (strcmp(returnType, @encode(UIOffset)) == 0) {
        UIOffset targetValue;
        [invocation getReturnValue:&targetValue];
        attribute.attrType = LayerLens_AttrTypeUIOffset;
        attribute.value = [NSValue valueWithUIOffset:targetValue];
        
    } else {
        NSString *argType_string = [[NSString alloc] layerlens_safeInitWithUTF8String:returnType];
        if ([argType_string hasPrefix:@"@"]) {
            __unsafe_unretained id returnObjValue;
            [invocation getReturnValue:&returnObjValue];
            
            if (!returnObjValue && [LayerLens_DashboardBlueprint hideIfNilWithAttrID:identifier]) {
                // 对于某些属性，若 value 为 nil 则不显示
                return nil;
            }
            
            attribute.attrType = [LayerLens_DashboardBlueprint objectAttrTypeWithAttrID:identifier];
            if (attribute.attrType == LayerLens_AttrTypeUIColor) {
                if (returnObjValue == nil) {
                    attribute.value = nil;
                } else if ([returnObjValue isKindOfClass:[UIColor class]] && [returnObjValue respondsToSelector:@selector(layerlens_rgbaComponents)]) {
                    attribute.value = [returnObjValue layerlens_rgbaComponents];
                } else {
                    // https://github.com/QMUI/LayerLens_Server/issues/124
                    return nil;
                }
            } else {
                attribute.value = returnObjValue;
            }
            
        } else {
            NSAssert(NO, @"不支持解析该类型的返回值");
            return nil;
        }
    }
    
    return attribute;
}

@end

