
//
//  UIView+LayerLens_Server.m
//  LayerLens_Server
//
//  Created by Li Kai on 2019/3/19.
//  https://lookin.work
//

#import "UIView+LayerLens_Server.h"
#import <objc/runtime.h>
#import "LayerLens_Object.h"
#import "LayerLens_AutoLayoutConstraint.h"
#import "LayerLens_ServerDefines.h"
#import "LayerLens_MultiplatformAdapter.h"

@implementation UIView (LayerLens_Server)

- (UIViewController *)layerlens_findHostViewController {
    UIResponder *responder = [self nextResponder];
    if (!responder) {
        return nil;
    }
    if (![responder isKindOfClass:[UIViewController class]]) {
        return nil;
    }
    UIViewController *viewController = (UIViewController *)responder;
    if (viewController.view != self) {
        return nil;
    }
    return viewController;
}

- (UIView *)layerlens_subviewAtPoint:(CGPoint)point preferredClasses:(NSArray<Class> *)preferredClasses {
    BOOL isPreferredClassForSelf = [preferredClasses layerlens_any:^BOOL(Class obj) {
        return [self isKindOfClass:obj];
    }];
    if (isPreferredClassForSelf) {
        return self;
    }
    
    UIView *targetView = [self.subviews layerlens_lastFiltered:^BOOL(__kindof UIView *obj) {
        if (obj.hidden || obj.alpha <= 0.01) {
            return NO;
        }
        BOOL contains = CGRectContainsPoint(obj.frame, point);
        return contains;
    }];
    
    if (!targetView) {
        return self;
    }
    
    CGPoint newPoint = [targetView convertPoint:point fromView:self];
    targetView = [targetView layerlens_subviewAtPoint:newPoint preferredClasses:preferredClasses];
    return targetView;
}

- (CGSize)layerlens_bestSize {
    return [self sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
}

- (CGFloat)layerlens_bestWidth {
    return self.layerlens_bestSize.width;
}

- (CGFloat)layerlens_bestHeight {
    return self.layerlens_bestSize.height;
}

- (void)setLayerlens_isChildrenViewOfTabBar:(BOOL)layerlens_isChildrenViewOfTabBar {
    [self layerlens_bindBOOL:layerlens_isChildrenViewOfTabBar forKey:@"layerlens_isChildrenViewOfTabBar"];
}
- (BOOL)layerlens_isChildrenViewOfTabBar {
    return [self layerlens_getBindBOOLForKey:@"layerlens_isChildrenViewOfTabBar"];
}

- (void)setLayerlens_verticalContentHuggingPriority:(float)layerlens_verticalContentHuggingPriority {
    [self setContentHuggingPriority:layerlens_verticalContentHuggingPriority forAxis:UILayoutConstraintAxisVertical];
}
- (float)layerlens_verticalContentHuggingPriority {
    return [self contentHuggingPriorityForAxis:UILayoutConstraintAxisVertical];
}

- (void)setLayerlens_horizontalContentHuggingPriority:(float)layerlens_horizontalContentHuggingPriority {
    [self setContentHuggingPriority:layerlens_horizontalContentHuggingPriority forAxis:UILayoutConstraintAxisHorizontal];
}
- (float)layerlens_horizontalContentHuggingPriority {
    return [self contentHuggingPriorityForAxis:UILayoutConstraintAxisHorizontal];
}

- (void)setLayerlens_verticalContentCompressionResistancePriority:(float)layerlens_verticalContentCompressionResistancePriority {
    [self setContentCompressionResistancePriority:layerlens_verticalContentCompressionResistancePriority forAxis:UILayoutConstraintAxisVertical];
}
- (float)layerlens_verticalContentCompressionResistancePriority {
    return [self contentCompressionResistancePriorityForAxis:UILayoutConstraintAxisVertical];
}

- (void)setLayerlens_horizontalContentCompressionResistancePriority:(float)layerlens_horizontalContentCompressionResistancePriority {
    [self setContentCompressionResistancePriority:layerlens_horizontalContentCompressionResistancePriority forAxis:UILayoutConstraintAxisHorizontal];
}
- (float)layerlens_horizontalContentCompressionResistancePriority {
    return [self contentCompressionResistancePriorityForAxis:UILayoutConstraintAxisHorizontal];
}

+ (void)layerlens_rebuildGlobalInvolvedRawConstraints {
    [[LayerLens_MultiplatformAdapter allWindows] enumerateObjectsUsingBlock:^(__kindof UIWindow * _Nonnull window, NSUInteger idx, BOOL * _Nonnull stop) {
        [self layerlens_removeInvolvedRawConstraintsForViewsRootedByView:window];
    }];
    [[LayerLens_MultiplatformAdapter allWindows] enumerateObjectsUsingBlock:^(__kindof UIWindow * _Nonnull window, NSUInteger idx, BOOL * _Nonnull stop) {
        [self layerlens_addInvolvedRawConstraintsForViewsRootedByView:window];
    }];
}

+ (void)layerlens_addInvolvedRawConstraintsForViewsRootedByView:(UIView *)rootView {
    [rootView.constraints enumerateObjectsUsingBlock:^(__kindof NSLayoutConstraint * _Nonnull constraint, NSUInteger idx, BOOL * _Nonnull stop) {
        UIView *firstView = constraint.firstItem;
        if ([firstView isKindOfClass:[UIView class]] && ![firstView.layerlens_involvedRawConstraints containsObject:constraint]) {
            if (!firstView.layerlens_involvedRawConstraints) {
                firstView.layerlens_involvedRawConstraints = [NSMutableArray array];
            }
            [firstView.layerlens_involvedRawConstraints addObject:constraint];
        }
        
        UIView *secondView = constraint.secondItem;
        if ([secondView isKindOfClass:[UIView class]] && ![secondView.layerlens_involvedRawConstraints containsObject:constraint]) {
            if (!secondView.layerlens_involvedRawConstraints) {
                secondView.layerlens_involvedRawConstraints = [NSMutableArray array];
            }
            [secondView.layerlens_involvedRawConstraints addObject:constraint];
        }
    }];
    
    [rootView.subviews enumerateObjectsUsingBlock:^(__kindof UIView * _Nonnull subview, NSUInteger idx, BOOL * _Nonnull stop) {
        [self layerlens_addInvolvedRawConstraintsForViewsRootedByView:subview];
    }];
}

+ (void)layerlens_removeInvolvedRawConstraintsForViewsRootedByView:(UIView *)rootView {
    [rootView.layerlens_involvedRawConstraints removeAllObjects];
    [rootView.subviews enumerateObjectsUsingBlock:^(__kindof UIView * _Nonnull subview, NSUInteger idx, BOOL * _Nonnull stop) {
        [self layerlens_removeInvolvedRawConstraintsForViewsRootedByView:subview];
    }];
}

- (void)setLayerlens_involvedRawConstraints:(NSMutableArray<NSLayoutConstraint *> *)layerlens_involvedRawConstraints {
    [self layerlens_bindObject:layerlens_involvedRawConstraints forKey:@"layerlens_involvedRawConstraints"];
}

- (NSMutableArray<NSLayoutConstraint *> *)layerlens_involvedRawConstraints {
    return [self layerlens_getBindObjectForKey:@"layerlens_involvedRawConstraints"];
}

- (NSArray<LayerLens_AutoLayoutConstraint *> *)layerlens_constraints {
    /**
     - layerlens_involvedRawConstraints 保存了牵扯到了 self 的所有的 constraints（包括未生效的，但不包括 inactive 的，整个产品逻辑都是直接忽略 inactive 的 constraints）
     - 通过 constraintsAffectingLayoutForAxis 可以拿到会影响 self 布局的所有已生效的 constraints（这里称之为 effectiveConstraints）
     - 很多情况下，一条 constraint 会出现在 effectiveConstraints 里但不会出现在 layerlens_involvedRawConstraints 里，比如：
        · UIWindow 拥有 minX, minY, width, height 四个 effectiveConstraints，但 layerlens_involvedRawConstraints 为空，因为它的 constraints 属性为空（这一点不知道为啥，但 Xcode Inspector 和 Reveal 确实也不会显示这四个 constraints）
        · 如果设置了 View1 的 center 和 superview 的 center 保持一致，则 superview 的 width 和 height 也会出现在 effectiveConstraints 里，但不会出现在 layerlens_involvedRawConstraints 里（这点可以理解，毕竟这种场景下 superview 的 width 和 height 确实会影响到 View1）
     */
    NSMutableArray<NSLayoutConstraint *> *effectiveConstraints = [NSMutableArray array];
    [effectiveConstraints addObjectsFromArray:[self constraintsAffectingLayoutForAxis:UILayoutConstraintAxisHorizontal]];
    [effectiveConstraints addObjectsFromArray:[self constraintsAffectingLayoutForAxis:UILayoutConstraintAxisVertical]];
    
    NSArray<LayerLens_AutoLayoutConstraint *> *lookinConstraints = [self.layerlens_involvedRawConstraints layerlens_map:^id(NSUInteger idx, __kindof NSLayoutConstraint *constraint) {
        BOOL isEffective = [effectiveConstraints containsObject:constraint];
        if ([constraint isActive]) {
            // trying to get firstItem or secondItem of an inactive constraint may cause dangling-pointer crash
            // https://github.com/QMUI/LayerLens_Server/issues/86
            LayerLens_ConstraintItemType firstItemType = [self _layerlens_constraintItemTypeForItem:constraint.firstItem];
            LayerLens_ConstraintItemType secondItemType = [self _layerlens_constraintItemTypeForItem:constraint.secondItem];
            LayerLens_AutoLayoutConstraint *lookinConstraint = [LayerLens_AutoLayoutConstraint instanceFromNSConstraint:constraint isEffective:isEffective firstItemType:firstItemType secondItemType:secondItemType];
            return lookinConstraint;
        }
        return nil;
    }];
    return lookinConstraints.count ? lookinConstraints : nil;
}

- (LayerLens_ConstraintItemType)_layerlens_constraintItemTypeForItem:(id)item {
    if (!item) {
        return LayerLens_ConstraintItemTypeNil;
    }
    if (item == self) {
        return LayerLens_ConstraintItemTypeSelf;
    }
    if (item == self.superview) {
        return LayerLens_ConstraintItemTypeSuper;
    }
    
    // 在 runtime 时，这里会遇到的 UILayoutGuide 和 _UILayoutGuide 居然是 UIView 的子类，不知道是看错了还是有什么玄机，所以在判断是否是 UIView 之前要先判断这个
    if (@available(iOS 9.0, *)) {
        if ([item isKindOfClass:[UILayoutGuide class]]) {
            return LayerLens_ConstraintItemTypeLayoutGuide;
        }
    }
    
    NSString *className = NSStringFromClass([item class]);
    if ([className hasSuffix:@"_UILayoutGuide"]) {
        return LayerLens_ConstraintItemTypeLayoutGuide;
    }
    
    if ([item isKindOfClass:[UIView class]]) {
        return LayerLens_ConstraintItemTypeView;
    }
    
    NSAssert(NO, @"");
    return LayerLens_ConstraintItemTypeUnknown;
}

@end

