
//
//  UIViewController+LayerLens_Server.m
//  LayerLens_Server
//
//  Created by Li Kai on 2019/4/22.
//  https://lookin.work
//

#import "UIViewController+LayerLens_Server.h"
#import "UIView+LayerLens_Server.h"
#import <objc/runtime.h>
#import "LayerLens_MultiplatformAdapter.h"

@implementation UIViewController (LayerLens_Server)

+ (nullable UIViewController *)layerlens_visibleViewController {
    
    UIViewController *rootViewController = [LayerLens_MultiplatformAdapter keyWindow].rootViewController;
    UIViewController *visibleViewController = [rootViewController layerlens_visibleViewControllerIfExist];
    return visibleViewController;
}

- (UIViewController *)layerlens_visibleViewControllerIfExist {
    
    if (self.presentedViewController) {
        return [self.presentedViewController layerlens_visibleViewControllerIfExist];
    }
    
    if ([self isKindOfClass:[UINavigationController class]]) {
        return [((UINavigationController *)self).visibleViewController layerlens_visibleViewControllerIfExist];
    }
    
    if ([self isKindOfClass:[UITabBarController class]]) {
        return [((UITabBarController *)self).selectedViewController layerlens_visibleViewControllerIfExist];
    }
    
    if (self.isViewLoaded && !self.view.hidden && self.view.alpha > 0.01) {
        return self;
    } else {
        return nil;
    }
}

@end

