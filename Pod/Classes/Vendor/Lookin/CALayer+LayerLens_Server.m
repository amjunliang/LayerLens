
//
//  UIView+LayerLens_Mobile.m
//  WeRead
//
//  Created by Li Kai on 2018/11/30.
//  Copyright © 2018 tencent. All rights reserved.
//

#import "CALayer+LayerLens_Server.h"
#import "LayerLens_HierarchyDisplayItemsMaker.h"
#import "LayerLens_DisplayItem.h"
#import <objc/runtime.h>
#import "LayerLens_IvarTrace.h"
#import "LayerLens_ServerDefines.h"
#import "UIColor+LayerLens_Server.h"
#import "LayerLens_MultiplatformAdapter.h"

@implementation CALayer (LayerLens_Server)

- (UIWindow *)layerlens_window {
    CALayer *layer = self;
    while (layer) {
        UIView *hostView = layer.layerlens_hostView;
        if (hostView.window) {
            return hostView.window;
        } else if ([hostView isKindOfClass:[UIWindow class]]) {
            return (UIWindow *)hostView;
        }
        layer = layer.superlayer;
    }
    return nil;
}

- (CGRect)layerlens_frameInWindow:(UIWindow *)window {
    UIWindow *selfWindow = [self layerlens_window];
    if (!selfWindow) {
        return CGRectZero;
    }
    
    CGRect rectInSelfWindow = [selfWindow.layer convertRect:self.frame fromLayer:self.superlayer];
    CGRect rectInWindow = [window convertRect:rectInSelfWindow fromWindow:selfWindow];
    return rectInWindow;
}

#pragma mark - Host View

- (UIView *)layerlens_hostView {
    if (self.delegate && [self.delegate isKindOfClass:UIView.class]) {
        UIView *view = (UIView *)self.delegate;
        if (view.layer == self) {
            return view;
        }
    }
    return nil;
}

#pragma mark - Screenshot

- (UIImage *)layerlens_groupScreenshotWithLowQuality:(BOOL)lowQuality {
    
    CGFloat screenScale = [LayerLens_MultiplatformAdapter mainScreenScale];
    CGFloat pixelWidth = self.frame.size.width * screenScale;
    CGFloat pixelHeight = self.frame.size.height * screenScale;
    if (pixelWidth <= 0 || pixelHeight <= 0) {
        return nil;
    }
    
    CGFloat renderScale = lowQuality ? 1 : 0;
    CGFloat maxLength = MAX(pixelWidth, pixelHeight);
    if (maxLength > LayerLens_NodeImageMaxLengthInPx) {
        // 确保最终绘制出的图片长和宽都不能超过 LayerLens_NodeImageMaxLengthInPx
        // 如果算出的 renderScale 大于 1 则取 1，因为似乎用 1 渲染的速度要比一个别的奇怪的带小数点的数字要更快
        renderScale = MIN(screenScale * LayerLens_NodeImageMaxLengthInPx / maxLength, 1);
    }
    
    CGSize contextSize = self.frame.size;
    if (contextSize.width <= 0 || contextSize.height <= 0 || contextSize.width > 20000 || contextSize.height > 20000) {
        NSLog(@"LayerLens_Server - Failed to capture screenshot. Invalid context size: %@ x %@", @(contextSize.width), @(contextSize.height));
        return nil;
    }
    UIGraphicsBeginImageContextWithOptions(contextSize, NO, renderScale);
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (self.layerlens_hostView && !self.layerlens_hostView.layerlens_isChildrenViewOfTabBar) {
        [self.layerlens_hostView drawViewHierarchyInRect:CGRectMake(0, 0, self.frame.size.width, self.frame.size.height) afterScreenUpdates:YES];
    } else {
        [self renderInContext:context];
    }
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (UIImage *)layerlens_soloScreenshotWithLowQuality:(BOOL)lowQuality {
    if (!self.sublayers.count) {
        return nil;
    }
    
    CGFloat screenScale = [LayerLens_MultiplatformAdapter mainScreenScale];
    CGFloat pixelWidth = self.frame.size.width * screenScale;
    CGFloat pixelHeight = self.frame.size.height * screenScale;
    if (pixelWidth <= 0 || pixelHeight <= 0) {
        return nil;
    }
    
    CGFloat renderScale = lowQuality ? 1 : 0;
    CGFloat maxLength = MAX(pixelWidth, pixelHeight);
    if (maxLength > LayerLens_NodeImageMaxLengthInPx) {
        // 确保最终绘制出的图片长和宽都不能超过 LayerLens_NodeImageMaxLengthInPx
        // 如果算出的 renderScale 大于 1 则取 1，因为似乎用 1 渲染的速度要比一个别的奇怪的带小数点的数字要更快
        renderScale = MIN(screenScale * LayerLens_NodeImageMaxLengthInPx / maxLength, 1);
    }
    
    if (self.sublayers.count) {
        NSArray<CALayer *> *sublayers = [self.sublayers copy];
        NSMutableArray<CALayer *> *visibleSublayers = [NSMutableArray arrayWithCapacity:sublayers.count];
        [sublayers enumerateObjectsUsingBlock:^(__kindof CALayer * _Nonnull sublayer, NSUInteger idx, BOOL * _Nonnull stop) {
            if (!sublayer.hidden) {
                sublayer.hidden = YES;
                [visibleSublayers addObject:sublayer];
            }
        }];
        
        CGSize contextSize = self.frame.size;
        if (contextSize.width <= 0 || contextSize.height <= 0 || contextSize.width > 20000 || contextSize.height > 20000) {
            NSLog(@"LayerLens_Server - Failed to capture screenshot. Invalid context size: %@ x %@", @(contextSize.width), @(contextSize.height));
            return nil;
        }
        
        UIGraphicsBeginImageContextWithOptions(contextSize, NO, renderScale);
        CGContextRef context = UIGraphicsGetCurrentContext();
        if (self.layerlens_hostView && !self.layerlens_hostView.layerlens_isChildrenViewOfTabBar) {
            [self.layerlens_hostView drawViewHierarchyInRect:CGRectMake(0, 0, self.frame.size.width, self.frame.size.height) afterScreenUpdates:YES];
        } else {
            [self renderInContext:context];
        }
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        
        [visibleSublayers enumerateObjectsUsingBlock:^(CALayer * _Nonnull sublayer, NSUInteger idx, BOOL * _Nonnull stop) {
            sublayer.hidden = NO;
        }];
        
        return image;
    }
    return nil;
}

- (NSArray<NSArray<NSString *> *> *)layerlens_relatedClassChainList {
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:2];
    if (self.layerlens_hostView) {
        [array addObject:[CALayer layerlens_getClassListOfObject:self.layerlens_hostView endingClass:@"UIView"]];
        UIViewController* vc = [self.layerlens_hostView layerlens_findHostViewController];
        if (vc) {
            [array addObject:[CALayer layerlens_getClassListOfObject:vc endingClass:@"UIViewController"]];
        }
    } else {
        [array addObject:[CALayer layerlens_getClassListOfObject:self endingClass:@"CALayer"]];
    }
    return array.copy;
}

+ (NSArray<NSString *> *)layerlens_getClassListOfObject:(id)object endingClass:(NSString *)endingClass {
    NSArray<NSString *> *completedList = [object layerlens_classChainList];
    NSUInteger endingIdx = [completedList indexOfObject:endingClass];
    if (endingIdx != NSNotFound) {
        completedList = [completedList subarrayWithRange:NSMakeRange(0, endingIdx + 1)];
    }
    return completedList;
}

- (NSArray<NSString *> *)layerlens_selfRelation {
    NSMutableArray *array = [NSMutableArray array];
    NSMutableArray<LayerLens_IvarTrace *> *ivarTraces = [NSMutableArray array];
    if (self.layerlens_hostView) {
        UIViewController* vc = [self.layerlens_hostView layerlens_findHostViewController];
        if (vc) {
            [array addObject:[NSString stringWithFormat:@"(%@ *).view", NSStringFromClass(vc.class)]];
            
            [ivarTraces addObjectsFromArray:vc.layerlens_ivarTraces];
        }
        [ivarTraces addObjectsFromArray:self.layerlens_hostView.layerlens_ivarTraces];
    } else {
        [ivarTraces addObjectsFromArray:self.layerlens_ivarTraces];
    }
    if (ivarTraces.count) {
        [array addObjectsFromArray:[ivarTraces layerlens_map:^id(NSUInteger idx, LayerLens_IvarTrace *value) {
            return [NSString stringWithFormat:@"(%@ *) -> %@", value.hostClassName, value.ivarName];
        }]];
    }
    return array.count ? array.copy : nil;
}

- (UIColor *)layerlens_backgroundColor {
    return [UIColor layerlens_colorWithCGColor:self.backgroundColor];
}
- (void)setLayerlens_backgroundColor:(UIColor *)layerlens_backgroundColor {
    self.backgroundColor = layerlens_backgroundColor.CGColor;
}

- (UIColor *)layerlens_borderColor {
    return [UIColor layerlens_colorWithCGColor:self.borderColor];
}
- (void)setLayerlens_borderColor:(UIColor *)layerlens_borderColor {
    self.borderColor = layerlens_borderColor.CGColor;
}

- (UIColor *)layerlens_shadowColor {
    return [UIColor layerlens_colorWithCGColor:self.shadowColor];
}
- (void)setLayerlens_shadowColor:(UIColor *)layerlens_shadowColor {
    self.shadowColor = layerlens_shadowColor.CGColor;
}

- (CGFloat)layerlens_shadowOffsetWidth {
    return self.shadowOffset.width;
}
- (void)setLayerlens_shadowOffsetWidth:(CGFloat)layerlens_shadowOffsetWidth {
    self.shadowOffset = CGSizeMake(layerlens_shadowOffsetWidth, self.shadowOffset.height);
}

- (CGFloat)layerlens_shadowOffsetHeight {
    return self.shadowOffset.height;
}
- (void)setLayerlens_shadowOffsetHeight:(CGFloat)layerlens_shadowOffsetHeight {
    self.shadowOffset = CGSizeMake(self.shadowOffset.width, layerlens_shadowOffsetHeight);
}

@end

