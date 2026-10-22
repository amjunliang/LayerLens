//
//  LayerLensHTTPServer.m
//  LayerLens
//
//  Created by YueYou on 10/12/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LayerLensHTTPServer.h"
#import "LayerLensRouter.h"
#import "LayerLensHTTPRequest.h"
#import "LayerLensHTTPResponse.h"
#import <Network/Network.h>

@interface LayerLensHTTPServer ()

@property (nonatomic, strong) LayerLensRouter *router;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong, nullable) nw_listener_t listener;
//正在启动(尚未 ready)的监听器, 创建后即持有, stop 时一并取消
@property (nonatomic, strong, nullable) nw_listener_t pendingListener;
//已停止: 阻止停止后的 ready 回调和换端口重试
@property (nonatomic, assign) BOOL stopped;
@property (nonatomic, strong) NSMutableArray<nw_connection_t> *connections;
//保持打开的事件流连接, 按频道分组, 用于推送事件
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<nw_connection_t> *> *streamConnections;
@property (nonatomic, assign, readwrite) uint16_t port;
//最近一次启动的参数, 监听失效后按原参数重新监听
@property (nonatomic, assign) BOOL loopbackOnly;
@property (nonatomic, assign) uint16_t startPort;
@property (nonatomic, assign) NSInteger attempts;
@property (nonatomic, copy, nullable) void (^startCompletion)(uint16_t, NSError *);

@end

@implementation LayerLensHTTPServer

- (instancetype)initWithRouter:(LayerLensRouter *)router {
    if (self = [super init]) {
        _router = router;
        _queue = dispatch_queue_create("com.layerlens.server", DISPATCH_QUEUE_SERIAL);
        _connections = [NSMutableArray array];
        _streamConnections = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)isRunning {
    return self.listener != nil && self.port > 0;
}

#pragma mark - Listener

- (void)startWithLoopbackOnly:(BOOL)loopbackOnly startPort:(uint16_t)startPort attempts:(NSInteger)attempts completion:(void (^)(uint16_t, NSError *))completion {
    dispatch_async(self.queue, ^{
        // 已在监听或正在启动时忽略, 重复调用不会再占一个端口
        if (!self.stopped && (self.listener || self.pendingListener)) {
            return;
        }
        self.stopped = NO;
        self.loopbackOnly = loopbackOnly;
        self.startPort = startPort;
        self.attempts = attempts;
        self.startCompletion = completion;
        [self tryListenWithLoopbackOnly:loopbackOnly port:startPort remaining:attempts completion:completion];
    });
}

- (void)tryListenWithLoopbackOnly:(BOOL)loopbackOnly port:(uint16_t)port remaining:(NSInteger)remaining completion:(void (^)(uint16_t, NSError *))completion {
    if (self.stopped) {
        return;
    }
    if (remaining <= 0) {
        NSError *error = [NSError errorWithDomain:@"LayerLens" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No available port"}];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion ? completion(0, error) : nil;
        });
        return;
    }

    nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_parameters_set_reuse_local_address(parameters, true);

    NSString *portString = [NSString stringWithFormat:@"%u", port];
    nw_listener_t listener = nil;
    if (loopbackOnly) {
        nw_endpoint_t endpoint = nw_endpoint_create_host("127.0.0.1", portString.UTF8String);
        nw_parameters_set_local_endpoint(parameters, endpoint);
        listener = nw_listener_create(parameters);
    } else {
        listener = nw_listener_create_with_port(portString.UTF8String, parameters);
    }
    if (!listener) {
        [self tryListenWithLoopbackOnly:loopbackOnly port:port + 1 remaining:remaining - 1 completion:completion];
        return;
    }

    __weak typeof(self) weakSelf = self;
    __block BOOL finished = NO;
    self.pendingListener = listener;
    nw_listener_set_queue(listener, self.queue);
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
        [weakSelf acceptConnection:connection];
    });
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (finished) {
            // 就绪后失效(如挂起期间被系统回收): 丢弃监听器并重新监听, 已有连接不受影响.
            // 该回调可能晚于回到前台的通知, 所以这里也要重新监听; 延迟一下, 避免连续失效时空转
            if ((state == nw_listener_state_failed || state == nw_listener_state_cancelled) && self.listener == listener) {
                NSLog(@"[LayerLens] Listener invalidated: %@", error ? @(nw_error_get_error_code(error)) : @"cancelled");
                self.listener = nil;
                self.port = 0;
                if (state == nw_listener_state_failed) {
                    nw_listener_cancel(listener);
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)), self.queue, ^{
                    [weakSelf resumeIfNeeded];
                });
            }
            return;
        }
        //服务已释放或已停止: 取消这个监听器, 不再占用端口
        if (!self || self.stopped) {
            finished = YES;
            nw_listener_cancel(listener);
            return;
        }
        if (state == nw_listener_state_ready) {
            finished = YES;
            if (self.pendingListener == listener) {
                self.pendingListener = nil;
            }
            self.listener = listener;
            self.port = nw_listener_get_port(listener);
            uint16_t readyPort = self.port;
            dispatch_async(dispatch_get_main_queue(), ^{
                completion ? completion(readyPort, nil) : nil;
            });
        } else if (state == nw_listener_state_failed) {
            // 端口被占用等情况, 换下一个端口
            finished = YES;
            nw_listener_cancel(listener);
            if (self.pendingListener == listener) {
                self.pendingListener = nil;
            }
            [self tryListenWithLoopbackOnly:loopbackOnly port:port + 1 remaining:remaining - 1 completion:completion];
        }
    });
    nw_listener_start(listener);
}

- (void)resumeIfNeeded {
    dispatch_async(self.queue, ^{
        if (self.stopped || self.pendingListener || self.attempts <= 0) {
            return;
        }
        if (self.listener) {
            [self verifyListener:self.listener];
            return;
        }
        [self tryListenWithLoopbackOnly:self.loopbackOnly port:self.startPort remaining:self.attempts completion:self.startCompletion];
    });
}

// 真机锁屏期间系统会回收监听 socket, 但监听器仍停留在 ready, 不会收到失效回调.
// 回到前台时连接一次自己的端口, 连不上则丢弃监听器并重新监听
- (void)verifyListener:(nw_listener_t)listener {
    NSString *portString = [NSString stringWithFormat:@"%u", self.port];
    nw_endpoint_t endpoint = nw_endpoint_create_host("127.0.0.1", portString.UTF8String);
    nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_connection_t probe = nw_connection_create(endpoint, parameters);
    __weak typeof(self) weakSelf = self;
    __block BOOL finished = NO;
    void (^finish)(BOOL) = ^(BOOL alive) {
        if (finished) {
            return;
        }
        finished = YES;
        nw_connection_cancel(probe);
        __strong typeof(weakSelf) self = weakSelf;
        if (alive || !self || self.stopped || self.listener != listener) {
            return;
        }
        NSLog(@"[LayerLens] Listener on port %u is dead, restarting", self.port);
        self.listener = nil;
        self.port = 0;
        nw_listener_cancel(listener);
        [self tryListenWithLoopbackOnly:self.loopbackOnly port:self.startPort remaining:self.attempts completion:self.startCompletion];
    };
    nw_connection_set_queue(probe, self.queue);
    nw_connection_set_state_changed_handler(probe, ^(nw_connection_state_t state, nw_error_t error) {
        if (state == nw_connection_state_ready) {
            finish(YES);
        } else if (state == nw_connection_state_waiting || state == nw_connection_state_failed) {
            // 端口无人监听时连接进入 waiting(ECONNREFUSED)
            finish(NO);
        }
    });
    nw_connection_start(probe);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), self.queue, ^{
        finish(NO);
    });
}

- (void)stop {
    dispatch_async(self.queue, ^{
        self.stopped = YES;
        if (self.pendingListener) {
            nw_listener_cancel(self.pendingListener);
            self.pendingListener = nil;
        }
        if (self.listener) {
            nw_listener_cancel(self.listener);
            self.listener = nil;
        }
        for (nw_connection_t connection in [self.connections copy]) {
            nw_connection_cancel(connection);
        }
        [self.connections removeAllObjects];
        [self.streamConnections removeAllObjects];
        self.port = 0;
    });
}

#pragma mark - Connection

- (void)acceptConnection:(nw_connection_t)connection {
    [self.connections addObject:connection];
    __weak typeof(self) weakSelf = self;
    nw_connection_set_queue(connection, self.queue);
    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
        if (state == nw_connection_state_cancelled || state == nw_connection_state_failed) {
            [weakSelf.connections removeObject:connection];
            for (NSMutableArray *connections in weakSelf.streamConnections.allValues) {
                [connections removeObject:connection];
            }
        }
    });
    nw_connection_start(connection);
    [self receiveOnConnection:connection buffer:[NSMutableData data]];
}

- (void)receiveOnConnection:(nw_connection_t)connection buffer:(NSMutableData *)buffer {
    __weak typeof(self) weakSelf = self;
    nw_connection_receive(connection, 1, 64 * 1024, ^(dispatch_data_t content, nw_content_context_t context, bool isComplete, nw_error_t error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            nw_connection_cancel(connection);
            return;
        }
        if (content) {
            // dispatch_data_t 可桥接为 NSData
            [buffer appendData:(NSData *)content];
        }

        LayerLensHTTPRequest *request = nil;
        LayerLensParseResult result = [LayerLensHTTPRequest parseData:buffer request:&request];
        if (result == LayerLensParseResultDone) {
            [self handleRequest:request connection:connection];
        } else if (result == LayerLensParseResultError) {
            [self sendResponse:[LayerLensHTTPResponse errorResponse:400 message:@"Bad Request"] connection:connection];
        } else if (error || isComplete) {
            nw_connection_cancel(connection);
        } else {
            [self receiveOnConnection:connection buffer:buffer];
        }
    });
}

- (void)handleRequest:(LayerLensHTTPRequest *)request connection:(nw_connection_t)connection {
    __weak typeof(self) weakSelf = self;
    [self.router handleRequest:request responder:^(LayerLensHTTPResponse *response) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            nw_connection_cancel(connection);
            return;
        }
        dispatch_async(self.queue, ^{
            [self sendResponse:response connection:connection];
        });
    }];
}

- (void)sendResponse:(LayerLensHTTPResponse *)response connection:(nw_connection_t)connection {
    NSData *data = [response serializedData];
    dispatch_data_t content = dispatch_data_create(data.bytes, data.length, self.queue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    if (response.keepOpen) {
        nw_connection_send(connection, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false, ^(nw_error_t error) {
            if (error) {
                nw_connection_cancel(connection);
            }
        });
        NSString *channel = response.channel ?: @"events";
        NSMutableArray *connections = self.streamConnections[channel];
        if (!connections) {
            connections = [NSMutableArray array];
            self.streamConnections[channel] = connections;
        }
        [connections addObject:connection];
        [self waitCloseOnConnection:connection];
        return;
    }
    nw_connection_send(connection, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        nw_connection_cancel(connection);
    });
}

- (void)broadcastEvent:(NSString *)name object:(id)object {
    [self broadcastEvent:name channel:@"events" objectBlock:^id{
        return object;
    }];
}

- (void)broadcastEvent:(NSString *)name channel:(NSString *)channel objectBlock:(id (^)(void))objectBlock {
    dispatch_async(self.queue, ^{
        NSArray<nw_connection_t> *connections = [self.streamConnections[channel] copy];
        if (connections.count == 0) {
            return;
        }
        NSData *data = [LayerLensHTTPResponse eventDataWithName:name object:objectBlock()];
        for (nw_connection_t connection in connections) {
            dispatch_data_t content = dispatch_data_create(data.bytes, data.length, self.queue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            nw_connection_send(connection, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false, ^(nw_error_t error) {
                if (error) {
                    nw_connection_cancel(connection);
                }
            });
        }
    });
}

// 保持打开的连接: 持续读取以便浏览器关闭时及时释放
- (void)waitCloseOnConnection:(nw_connection_t)connection {
    __weak typeof(self) weakSelf = self;
    nw_connection_receive(connection, 1, 1024, ^(dispatch_data_t content, nw_content_context_t context, bool isComplete, nw_error_t error) {
        if (error || isComplete || !weakSelf) {
            nw_connection_cancel(connection);
            return;
        }
        [weakSelf waitCloseOnConnection:connection];
    });
}

@end
