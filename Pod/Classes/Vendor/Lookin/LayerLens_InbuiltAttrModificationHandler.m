
//
//  LayerLens_InbuiltAttrModificationHandler.m
//  LayerLens_Server
//
//  Created by Li Kai on 2019/6/12.
//  https://lookin.work
//

#import "LayerLens_InbuiltAttrModificationHandler.h"
#import "UIColor+LayerLens_Server.h"
#import "LayerLens_AttributeModification.h"
#import "LayerLens_AttrGroupsMaker.h"
#import "LayerLens_DisplayItemDetail.h"
#import "LayerLens_StaticAsyncUpdateTask.h"
#import "LayerLens_ServerDefines.h"
#import "LayerLens_CustomAttrGroupsMaker.h"

@implementation LayerLens_InbuiltAttrModificationHandler

+ (void)handleModification:(LayerLens_AttributeModification *)modification completion:(void (^)(LayerLens_DisplayItemDetail *data, NSError *error))completion {
    if (!completion) {
        NSAssert(NO, @"");
        return;
    }
    if (!modification || ![modification isKindOfClass:[LayerLens_AttributeModification class]]) {
        completion(nil, LayerLens_Err_Inner);
        return;
    }
    
    NSObject *receiver = [NSObject layerlens_objectWithOid:modification.targetOid];
    if (!receiver) {
        completion(nil, LayerLens_Err_ObjNotFound);
        return;
    }
    
    NSMethodSignature *setterSignature = [receiver methodSignatureForSelector:modification.setterSelector];
    NSInvocation *setterInvocation = [NSInvocation invocationWithMethodSignature:setterSignature];
    setterInvocation.target = receiver;
    setterInvocation.selector = modification.setterSelector;
    
    if (setterSignature.numberOfArguments != 3 || ![receiver respondsToSelector:modification.setterSelector]) {
        completion(nil, LayerLens_Err_Inner);
        return;
    }
    
    switch (modification.attrType) {
        case LayerLens_AttrTypeNone:
        case LayerLens_AttrTypeVoid: {
            completion(nil, LayerLens_Err_Inner);
            return;
        }
        case LayerLens_AttrTypeChar: {
            char expectedValue = [(NSNumber *)modification.value charValue];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeInt:
        case LayerLens_AttrTypeEnumInt: {
            int expectedValue = [(NSNumber *)modification.value intValue];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeShort: {
            short expectedValue = [(NSNumber *)modification.value shortValue];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeLong:
        case LayerLens_AttrTypeEnumLong: {
            long expectedValue = [(NSNumber *)modification.value longValue];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeLongLong: {
            long long expectedValue = [(NSNumber *)modification.value longLongValue];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeUnsignedChar: {
            unsigned char expectedValue = [(NSNumber *)modification.value unsignedCharValue];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeUnsignedInt: {
            unsigned int expectedValue = [(NSNumber *)modification.value unsignedIntValue];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeUnsignedShort: {
            unsigned short expectedValue = [(NSNumber *)modification.value unsignedShortValue];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeUnsignedLong: {
            unsigned long expectedValue = [(NSNumber *)modification.value unsignedLongValue];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeUnsignedLongLong: {
            unsigned long long expectedValue = [(NSNumber *)modification.value unsignedLongLongValue];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeFloat: {
            float expectedValue = [(NSNumber *)modification.value floatValue];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeDouble: {
            double expectedValue = [(NSNumber *)modification.value doubleValue];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeBOOL: {
            BOOL expectedValue = [(NSNumber *)modification.value boolValue];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeSel: {
            SEL expectedValue = NSSelectorFromString(modification.value);
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeClass: {
            Class expectedValue = NSClassFromString(modification.value);
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeCGPoint: {
            CGPoint expectedValue = [(NSValue *)modification.value CGPointValue];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeCGVector: {
            CGVector expectedValue = [(NSValue *)modification.value CGVectorValue];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeCGSize: {
            CGSize expectedValue = [(NSValue *)modification.value CGSizeValue];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeCGRect: {
            CGRect expectedValue = [(NSValue *)modification.value CGRectValue];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeCGAffineTransform: {
            CGAffineTransform expectedValue = [(NSValue *)modification.value CGAffineTransformValue];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeUIEdgeInsets: {
            UIEdgeInsets expectedValue = [(NSValue *)modification.value UIEdgeInsetsValue];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeUIOffset: {
            UIOffset expectedValue = [(NSValue *)modification.value UIOffsetValue];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            break;
        }
        case LayerLens_AttrTypeCustomObj:
        case LayerLens_AttrTypeNSString: {
            NSObject *expectedValue = modification.value;
            [setterInvocation setArgument:&expectedValue atIndex:2];
            [setterInvocation retainArguments];
            break;
        }
        case LayerLens_AttrTypeUIColor: {
            NSArray<NSNumber *> *rgba = modification.value;
            UIColor *expectedValue = [UIColor layerlens_colorFromRGBAComponents:rgba];
            [setterInvocation setArgument:&expectedValue atIndex:2];
            [setterInvocation retainArguments];
            break;
        }
        default: {
            completion(nil, LayerLens_Err_Inner);
            return;
        }
    }
    
    NSError *error = nil;
    @try {
        [setterInvocation invoke];
    } @catch (NSException *exception) {
        NSString *errorMsg = [NSString stringWithFormat:LayerLens_Localized(@"<%@: %p>: an exception was raised when invoking %@. (%@)"), NSStringFromClass(receiver.class), receiver, NSStringFromSelector(modification.setterSelector), exception.reason];
        error = [NSError errorWithDomain:LayerLens_ErrorDomain code:LayerLens_ErrCode_Exception userInfo:@{NSLocalizedDescriptionKey:LayerLens_Localized(@"The modification may failed."), NSLocalizedRecoverySuggestionErrorKey:errorMsg}];
    } @finally {
        
    }
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CALayer *layer = nil;
        if ([receiver isKindOfClass:[CALayer class]]) {
            layer = (CALayer *)receiver;
        } else if ([receiver isKindOfClass:[UIView class]]) {
            layer = ((UIView *)receiver).layer;
        } else {
            completion(nil, LayerLens_Err_ObjNotFound);
            return;
        }
        // 比如试图更改 frame 时，这个改动很有可能触发用户业务的 relayout，因此这时 dispatch 一下以确保拿到的 attrGroups 数据是最新的
        LayerLens_DisplayItemDetail *detail = [LayerLens_DisplayItemDetail new];
        detail.displayItemOid = modification.targetOid;
        detail.attributesGroupList = [LayerLens_AttrGroupsMaker attrGroupsForLayer:layer];
        
        NSString *version = modification.clientReadableVersion;
        if (version.length > 0 && [version layerlens_numbericOSVersion] >= 10004) {
            LayerLens_CustomAttrGroupsMaker *maker = [[LayerLens_CustomAttrGroupsMaker alloc] initWithLayer:layer];
            [maker execute];
            detail.customAttrGroupList = [maker getGroups];
        }
        
        detail.frameValue = [NSValue valueWithCGRect:layer.frame];
        detail.boundsValue = [NSValue valueWithCGRect:layer.bounds];
        detail.hiddenValue = [NSNumber numberWithBool:layer.isHidden];
        detail.alphaValue = @(layer.opacity);
        completion(detail, error);
    });
}


+ (void)handlePatchWithTasks:(NSArray<LayerLens_StaticAsyncUpdateTask *> *)tasks block:(void (^)(LayerLens_DisplayItemDetail *data))block {
    if (!block) {
        NSAssert(NO, @"");
        return;
    }
    [tasks enumerateObjectsUsingBlock:^(LayerLens_StaticAsyncUpdateTask * _Nonnull task, NSUInteger idx, BOOL * _Nonnull stop) {
        LayerLens_DisplayItemDetail *itemDetail = [LayerLens_DisplayItemDetail new];
        itemDetail.displayItemOid = task.oid;
        id object = [NSObject layerlens_objectWithOid:task.oid];
        if (!object || ![object isKindOfClass:[CALayer class]]) {
            block(itemDetail);
            return;
        }
        
        CALayer *layer = object;
        if (task.taskType == LayerLens_StaticAsyncUpdateTaskTypeSoloScreenshot) {
            UIImage *image = [layer layerlens_soloScreenshotWithLowQuality:NO];
            itemDetail.soloScreenshot = image;
        } else if (task.taskType == LayerLens_StaticAsyncUpdateTaskTypeGroupScreenshot) {
            UIImage *image = [layer layerlens_groupScreenshotWithLowQuality:NO];
            itemDetail.groupScreenshot = image;
        }
        block(itemDetail);
    }];
}

@end

