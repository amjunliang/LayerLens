//
//  LLEAppDelegate.m
//  LayerLensExample
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LLEAppDelegate.h"
#import "LLESceneDelegate.h"

@implementation LLEAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    return YES;
}

// iOS 27 起未采用场景生命周期的 App 启动即被终止, 界面由 LLESceneDelegate 创建
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:connectingSceneSession.role];
    configuration.delegateClass = LLESceneDelegate.class;
    return configuration;
}

@end
