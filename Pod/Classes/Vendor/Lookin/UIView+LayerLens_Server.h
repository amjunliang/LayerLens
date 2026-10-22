
//
//  UIView+LayerLens_Server.h
//  LayerLens_Server
//
//  Created by Li Kai on 2019/3/19.
//  https://lookin.work
//

#import "LayerLens_Defines.h"
#import <UIKit/UIKit.h>

@interface UIView (LayerLens_Server)

/// 如果 myViewController.view = myView，则可以通过 myView 的 layerlens_findHostViewController 方法找到 myViewController
- (UIViewController *)layerlens_findHostViewController;

/// 是否是 UITabBar 的 childrenView，如果是的话，则截图时需要强制使用 renderInContext: 的方式而非 drawViewHierarchyInRect:afterScreenUpdates: 否则在 iOS 13 上获取到的图像是空的不知道为什么
@property(nonatomic, assign) BOOL layerlens_isChildrenViewOfTabBar;

/// point 是相对于 receiver 自身的坐标系
- (UIView *)layerlens_subviewAtPoint:(CGPoint)point preferredClasses:(NSArray<Class> *)preferredClasses;

- (CGFloat)layerlens_bestWidth;
- (CGFloat)layerlens_bestHeight;
- (CGSize)layerlens_bestSize;

@property(nonatomic, assign) float layerlens_horizontalContentHuggingPriority;
@property(nonatomic, assign) float layerlens_verticalContentHuggingPriority;

@property(nonatomic, assign) float layerlens_horizontalContentCompressionResistancePriority;
@property(nonatomic, assign) float layerlens_verticalContentCompressionResistancePriority;

/// 遍历全局的 view 并给他们设置 layerlens_involvedRawConstraints 属性
+ (void)layerlens_rebuildGlobalInvolvedRawConstraints;
/// 该属性保存了牵扯到当前 view 的所有 constraints，包括那些没有生效的
@property(nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *layerlens_involvedRawConstraints;

- (NSArray<NSDictionary<NSString *, id> *> *)layerlens_constraints;

@end

