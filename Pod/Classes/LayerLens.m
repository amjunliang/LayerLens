//
//  LayerLens.m
//  LayerLens
//
//  Created by YueYou on 10/12/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LayerLens.h"
#import "LayerLensHTTPServer.h"
#import "LayerLensRouter.h"
#import "LayerLensAPIController.h"
#import "LayerLensLookinBridge.h"
#import <UIKit/UIKit.h>

NSString * const LayerLensVersion = @"0.2.0";
const NSInteger LayerLensAPIVersion = 1;

#if DEBUG
// Mac App 扫描同一范围, 两端需保持一致
static const uint16_t kLayerLensDefaultPort = 9527;
static const NSInteger kLayerLensPortAttempts = 10;
#endif

@interface LayerLens ()

@property (nonatomic, strong) LayerLensRouter *router;
@property (nonatomic, strong) LayerLensAPIController *apiController;
@property (nonatomic, strong) LayerLensHTTPServer *server;

@end

@implementation LayerLens

#if DEBUG
+ (void)load {
    // 与 Lookin 一致, 集成即启动; 延后到主线程以免在 +load 阶段创建网络对象
    dispatch_async(dispatch_get_main_queue(), ^{
        [[LayerLens sharedInstance] start];
    });
}
#endif

+ (instancetype)sharedInstance {
    static LayerLens *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[LayerLens alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _router = [[LayerLensRouter alloc] init];
        _apiController = [[LayerLensAPIController alloc] init];
        [_apiController registerRoutesToRouter:_router];
        _server = [[LayerLensHTTPServer alloc] initWithRouter:_router];
    }
    return self;
}

- (void)start {
#if DEBUG
    // 挂起期间系统会回收监听端口, 回到前台时重新监听
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(restart) name:UIApplicationWillEnterForegroundNotification object:nil];
    [self startServer];
#endif
}

#if DEBUG
- (void)restart {
    [self.server stop];
    [self startServer];
}

- (void)startServer {
    // 只监听本机地址: 模拟器与 Mac 共用回环, 真机经 USB(usbmuxd) 转发到设备回环
    [self.server startWithLoopbackOnly:YES startPort:kLayerLensDefaultPort attempts:kLayerLensPortAttempts completion:^(uint16_t port, NSError *error) {
        if (error) {
            NSLog(@"[LayerLens] Start failed: %@", error.localizedDescription);
            return;
        }
        NSLog(@"[LayerLens] Running on port %u, open the LayerLens Mac app to inspect", port);
    }];
}
#endif

@end
