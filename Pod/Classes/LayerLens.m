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
#import "LayerLensLogger.h"
#import "LayerLensNetworkHooks.h"
#import "LayerLensNetworkRecorder.h"
#import <UIKit/UIKit.h>

NSString * const LayerLensVersion = @"0.7.0";
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
@property (nonatomic, strong) dispatch_source_t heartbeatTimer;

@end

@implementation LayerLens

#if DEBUG
+ (void)load {
    // 尽早替换 NSURLSession 的实现, 以记录启动阶段的请求
    [LayerLensNetworkHooks install];
    // 与 Lookin 一致, 集成即启动; 延后到主线程以免在 +load 阶段创建网络对象
    dispatch_async(dispatch_get_main_queue(), ^{
        // 热重载注入的动态库会再带一份本类并再次执行 +load, 各镜像的静态变量互不相通;
        // 用主线程字典做进程级标记, 整个进程只启动一个服务, 避免占用多个端口在 Mac 端出现重复的 App
        NSMutableDictionary *store = NSThread.mainThread.threadDictionary;
        static NSString * const startedKey = @"LayerLensServerStarted";
        if ([store[startedKey] boolValue]) {
            return;
        }
        store[startedKey] = @YES;
        [[LayerLens sharedInstance] start];
    });
}
#endif

+ (void)log:(NSString *)message {
#if DEBUG
    [LayerLensLogger.sharedLogger log:message];
#endif
}

+ (NSString *)logDirectory {
    return LayerLensLogger.sharedLogger.directory;
}

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
    // 挂起期间系统可能回收监听端口, 回到前台时检查并按需重新监听; 不重启服务, 以免断开网页的事件流
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(willEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
    // 进入后台后很快被挂起, 事件流不会断开, 主动告知网页 App 不在前台
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(didEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(didBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    __weak typeof(self) weakSelf = self;
    LayerLensLogger.sharedLogger.onFlush = ^(NSArray<NSDictionary *> *entries) {
        [weakSelf.server broadcastEvent:@"logs" channel:@"logs" objectBlock:^id{
            return @{@"entries": entries};
        }];
    };
    LayerLensNetworkRecorder.sharedRecorder.onFlush = ^(NSArray<NSDictionary *> *records) {
        [weakSelf.server broadcastEvent:@"network" channel:@"network" objectBlock:^id{
            return @{@"records": records};
        }];
    };
    LayerLensNetworkRecorder.sharedRecorder.onClear = ^{
        [weakSelf.server broadcastEvent:@"clear" channel:@"network" objectBlock:^id{
            return @{};
        }];
    };
    // 日志流心跳: Mac 端据此发现静默失效的连接(如锁屏期间被系统回收)并重新连接; 没有连接时不发送
    self.heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(self.heartbeatTimer, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), 15 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(self.heartbeatTimer, ^{
        for (NSString *channel in @[@"logs", @"network"]) {
            [weakSelf.server broadcastEvent:@"ping" channel:channel objectBlock:^id{
                return @{};
            }];
        }
    });
    dispatch_resume(self.heartbeatTimer);
    [self startServer];
#endif
}

#if DEBUG
- (void)willEnterForeground {
    [self.server resumeIfNeeded];
}

- (void)didEnterBackground {
    [self.server broadcastEvent:@"state" object:@{@"foreground": @NO}];
}

- (void)didBecomeActive {
    [self.server broadcastEvent:@"state" object:@{@"foreground": @YES}];
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

void LayerLensLog(NSString *format, ...) {
#if DEBUG
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    [LayerLens log:message];
#endif
}
