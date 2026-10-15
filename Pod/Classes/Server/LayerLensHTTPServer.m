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
@property (nonatomic, assign, readwrite) uint16_t port;

@end

@implementation LayerLensHTTPServer

- (instancetype)initWithRouter:(LayerLensRouter *)router {
    if (self = [super init]) {
        _router = router;
        _queue = dispatch_queue_create("com.layerlens.server", DISPATCH_QUEUE_SERIAL);
        _connections = [NSMutableArray array];
    }
    return self;
}

- (BOOL)isRunning {
    return self.listener != nil && self.port > 0;
}

#pragma mark - Listener

- (void)startWithLoopbackOnly:(BOOL)loopbackOnly startPort:(uint16_t)startPort attempts:(NSInteger)attempts completion:(void (^)(uint16_t, NSError *))completion {
    dispatch_async(self.queue, ^{
        self.stopped = NO;
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
        [self waitCloseOnConnection:connection];
        return;
    }
    nw_connection_send(connection, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        nw_connection_cancel(connection);
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
