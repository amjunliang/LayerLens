
//
//  UIView+LayerLens_Mobile.h
//  WeRead
//
//  Created by Li Kai on 2018/11/30.
//  Copyright © 2018 tencent. All rights reserved.
//

#import "LayerLens_Defines.h"
#import "TargetConditionals.h"
#import <UIKit/UIKit.h>

@interface CALayer (LayerLens_Server)

/// 如果 myView.layer == myLayer，则 myLayer.layerlens_hostView 会返回 myView
@property(nonatomic, readonly, weak) UIView *layerlens_hostView;

- (UIWindow *)layerlens_window;

- (CGRect)layerlens_frameInWindow:(UIWindow *)window;

- (UIImage *)layerlens_groupScreenshotWithLowQuality:(BOOL)lowQuality;
/// 当没有 sublayers 时，该方法返回 nil
- (UIImage *)layerlens_soloScreenshotWithLowQuality:(BOOL)lowQuality;

/// 获取和该对象有关的对象的 Class 层级树
- (NSArray<NSArray<NSString *> *> *)layerlens_relatedClassChainList;

- (NSArray<NSString *> *)layerlens_selfRelation;

@property(nonatomic, strong) UIColor *layerlens_backgroundColor;
@property(nonatomic, strong) UIColor *layerlens_borderColor;
@property(nonatomic, strong) UIColor *layerlens_shadowColor;
@property(nonatomic, assign) CGFloat layerlens_shadowOffsetWidth;
@property(nonatomic, assign) CGFloat layerlens_shadowOffsetHeight;

@end

