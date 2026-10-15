//
//  LLESceneDelegate.m
//  LayerLensExample
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LLESceneDelegate.h"
#import "LLEListViewController.h"

@implementation LLESceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:UIWindowScene.class]) {
        return;
    }
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:[[LLEListViewController alloc] init]];
    UITabBarController *tabBar = [[UITabBarController alloc] init];
    navigation.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Views" image:[UIImage systemImageNamed:@"square.stack.3d.up"] tag:0];
    tabBar.viewControllers = @[navigation];
    self.window.rootViewController = tabBar;
    [self.window makeKeyAndVisible];
}

@end
