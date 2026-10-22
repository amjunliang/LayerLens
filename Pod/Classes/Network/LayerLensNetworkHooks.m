//
//  LayerLensNetworkHooks.m
//  LayerLens
//
//  Created by YueYou on 10/22/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LayerLensNetworkHooks.h"
#import "LayerLensNetworkRecorder.h"
#import <objc/runtime.h>

typedef void (^LayerLensDataHandler)(NSData *data, NSURLResponse *response, NSError *error);
typedef void (^LayerLensDownloadHandler)(NSURL *location, NSURLResponse *response, NSError *error);

static NSMutableSet<NSString *> *LayerLensHookedMethods;
static NSLock *LayerLensHookLock;

// 实际实现该方法的类: 从 cls 向上找, 直到父类的实现不同
static Class LayerLensMethodOwner(Class cls, SEL sel) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        return Nil;
    }
    Class owner = cls;
    Class superclass = class_getSuperclass(owner);
    while (superclass && class_getInstanceMethod(superclass, sel) == method) {
        owner = superclass;
        superclass = class_getSuperclass(owner);
    }
    return owner;
}

// 替换实际实现所在类的方法, 同一实现只替换一次; factory 根据原实现生成新的 block
static void LayerLensHookMethod(Class cls, SEL sel, id (^factory)(IMP original)) {
    Class owner = LayerLensMethodOwner(cls, sel);
    if (!owner) {
        return;
    }
    NSString *key = [NSString stringWithFormat:@"%@|%@", NSStringFromClass(owner), NSStringFromSelector(sel)];
    [LayerLensHookLock lock];
    if (![LayerLensHookedMethods containsObject:key]) {
        [LayerLensHookedMethods addObject:key];
        Method method = class_getInstanceMethod(owner, sel);
        method_setImplementation(method, imp_implementationWithBlock(factory(method_getImplementation(method))));
    }
    [LayerLensHookLock unlock];
}

// 子类实现中调用 super 时只记录一次
static BOOL LayerLensEnter(NSString *key) {
    NSMutableDictionary *store = NSThread.currentThread.threadDictionary;
    if (store[key]) {
        return NO;
    }
    store[key] = @YES;
    return YES;
}

static void LayerLensLeave(NSString *key) {
    [NSThread.currentThread.threadDictionary removeObjectForKey:key];
}

static BOOL LayerLensIsProxyClass(Class cls) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        if (current == NSProxy.class) {
            return YES;
        }
    }
    return NO;
}

@implementation LayerLensNetworkHooks

+ (void)install {
    // 热重载注入的镜像会再带一份本类, 用类上的关联对象作进程级标记
    @synchronized (NSURLSession.class) {
        if (objc_getAssociatedObject(NSURLSession.class, @selector(layerlens_networkHooked))) {
            return;
        }
        objc_setAssociatedObject(NSURLSession.class, @selector(layerlens_networkHooked), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    LayerLensHookedMethods = [NSMutableSet set];
    LayerLensHookLock = [[NSLock alloc] init];

    // 会话与任务的实际类是私有子类且随系统版本变化, 先创建一组不发出的任务找到它们
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    NSURL *url = [NSURL URLWithString:@"http://127.0.0.1/"];
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    NSArray<NSURLSessionTask *> *tasks = @[
        [session dataTaskWithURL:url],
        [session uploadTaskWithRequest:request fromData:[NSData data]],
        [session downloadTaskWithURL:url],
    ];
    Class sessionClass = session.class;
    NSMutableSet<Class> *taskClasses = [NSMutableSet set];
    for (NSURLSessionTask *task in tasks) {
        [taskClasses addObject:task.class];
        [task cancel];
    }
    [session invalidateAndCancel];

    for (Class cls in taskClasses) {
        [self hookResumeOfClass:cls];
    }
    [self hookTaskCreationOfClass:sessionClass];
    [self hookSessionFactory];
}

#pragma mark - Task

+ (void)hookResumeOfClass:(Class)cls {
    SEL sel = @selector(resume);
    LayerLensHookMethod(cls, sel, ^id(IMP original) {
        return ^(NSURLSessionTask *task) {
            [LayerLensNetworkRecorder.sharedRecorder taskDidResume:task];
            ((void (*)(id, SEL))original)(task, sel);
        };
    });
}

// 带 completionHandler 的任务不回调代理的数据方法, 包一层 handler 拿到结果
+ (void)hookTaskCreationOfClass:(Class)cls {
    LayerLensNetworkRecorder *recorder = LayerLensNetworkRecorder.sharedRecorder;

    SEL dataRequest = @selector(dataTaskWithRequest:completionHandler:);
    LayerLensHookMethod(cls, dataRequest, ^id(IMP original) {
        return ^NSURLSessionDataTask *(NSURLSession *session, NSURLRequest *request, LayerLensDataHandler handler) {
            if (!handler) {
                return ((NSURLSessionDataTask * (*)(id, SEL, id, id))original)(session, dataRequest, request, handler);
            }
            __block __weak NSURLSessionTask *weakTask = nil;
            NSURLSessionDataTask *task = ((NSURLSessionDataTask * (*)(id, SEL, id, id))original)(session, dataRequest, request, [self wrapDataHandler:handler task:^NSURLSessionTask *{
                return weakTask;
            }]);
            weakTask = task;
            [recorder markHandlerTask:task];
            return task;
        };
    });

    SEL dataURL = @selector(dataTaskWithURL:completionHandler:);
    LayerLensHookMethod(cls, dataURL, ^id(IMP original) {
        return ^NSURLSessionDataTask *(NSURLSession *session, NSURL *url, LayerLensDataHandler handler) {
            if (!handler) {
                return ((NSURLSessionDataTask * (*)(id, SEL, id, id))original)(session, dataURL, url, handler);
            }
            __block __weak NSURLSessionTask *weakTask = nil;
            NSURLSessionDataTask *task = ((NSURLSessionDataTask * (*)(id, SEL, id, id))original)(session, dataURL, url, [self wrapDataHandler:handler task:^NSURLSessionTask *{
                return weakTask;
            }]);
            weakTask = task;
            [recorder markHandlerTask:task];
            return task;
        };
    });

    SEL uploadData = @selector(uploadTaskWithRequest:fromData:);
    LayerLensHookMethod(cls, uploadData, ^id(IMP original) {
        return ^NSURLSessionUploadTask *(NSURLSession *session, NSURLRequest *request, NSData *body) {
            NSURLSessionUploadTask *task = ((NSURLSessionUploadTask * (*)(id, SEL, id, id))original)(session, uploadData, request, body);
            [recorder setUploadBody:body forTask:task];
            return task;
        };
    });

    SEL uploadFile = @selector(uploadTaskWithRequest:fromFile:);
    LayerLensHookMethod(cls, uploadFile, ^id(IMP original) {
        return ^NSURLSessionUploadTask *(NSURLSession *session, NSURLRequest *request, NSURL *file) {
            NSURLSessionUploadTask *task = ((NSURLSessionUploadTask * (*)(id, SEL, id, id))original)(session, uploadFile, request, file);
            [recorder setUploadBody:file forTask:task];
            return task;
        };
    });

    SEL uploadDataHandler = @selector(uploadTaskWithRequest:fromData:completionHandler:);
    LayerLensHookMethod(cls, uploadDataHandler, ^id(IMP original) {
        return ^NSURLSessionUploadTask *(NSURLSession *session, NSURLRequest *request, NSData *body, LayerLensDataHandler handler) {
            __block __weak NSURLSessionTask *weakTask = nil;
            NSURLSessionUploadTask *task = ((NSURLSessionUploadTask * (*)(id, SEL, id, id, id))original)(session, uploadDataHandler, request, body, handler ? [self wrapDataHandler:handler task:^NSURLSessionTask *{
                return weakTask;
            }] : nil);
            weakTask = task;
            [recorder setUploadBody:body forTask:task];
            if (handler) {
                [recorder markHandlerTask:task];
            }
            return task;
        };
    });

    SEL uploadFileHandler = @selector(uploadTaskWithRequest:fromFile:completionHandler:);
    LayerLensHookMethod(cls, uploadFileHandler, ^id(IMP original) {
        return ^NSURLSessionUploadTask *(NSURLSession *session, NSURLRequest *request, NSURL *file, LayerLensDataHandler handler) {
            __block __weak NSURLSessionTask *weakTask = nil;
            NSURLSessionUploadTask *task = ((NSURLSessionUploadTask * (*)(id, SEL, id, id, id))original)(session, uploadFileHandler, request, file, handler ? [self wrapDataHandler:handler task:^NSURLSessionTask *{
                return weakTask;
            }] : nil);
            weakTask = task;
            [recorder setUploadBody:file forTask:task];
            if (handler) {
                [recorder markHandlerTask:task];
            }
            return task;
        };
    });

    for (NSString *name in @[@"downloadTaskWithRequest:completionHandler:", @"downloadTaskWithURL:completionHandler:"]) {
        SEL sel = NSSelectorFromString(name);
        LayerLensHookMethod(cls, sel, ^id(IMP original) {
            return ^NSURLSessionDownloadTask *(NSURLSession *session, id target, LayerLensDownloadHandler handler) {
                if (!handler) {
                    return ((NSURLSessionDownloadTask * (*)(id, SEL, id, id))original)(session, sel, target, handler);
                }
                __block __weak NSURLSessionTask *weakTask = nil;
                NSURLSessionDownloadTask *task = ((NSURLSessionDownloadTask * (*)(id, SEL, id, id))original)(session, sel, target, ^(NSURL *location, NSURLResponse *response, NSError *error) {
                    [recorder task:weakTask didCompleteWithData:nil error:error fromHandler:YES];
                    handler(location, response, error);
                });
                weakTask = task;
                [recorder markHandlerTask:task];
                return task;
            };
        });
    }
}

+ (LayerLensDataHandler)wrapDataHandler:(LayerLensDataHandler)handler task:(NSURLSessionTask * (^)(void))task {
    return ^(NSData *data, NSURLResponse *response, NSError *error) {
        // 没有数据时传空数据, 以免使用代理回调中累积的内容
        [LayerLensNetworkRecorder.sharedRecorder task:task() didCompleteWithData:data ?: [NSData data] error:error fromHandler:YES];
        handler(data, response, error);
    };
}

#pragma mark - Delegate

+ (void)hookSessionFactory {
    SEL sel = @selector(sessionWithConfiguration:delegate:delegateQueue:);
    Method method = class_getClassMethod(NSURLSession.class, sel);
    if (!method) {
        return;
    }
    IMP original = method_getImplementation(method);
    method_setImplementation(method, imp_implementationWithBlock(^NSURLSession *(Class cls, NSURLSessionConfiguration *configuration, id delegate, NSOperationQueue *queue) {
        if (delegate) {
            [self hookDelegate:delegate];
        }
        return ((NSURLSession * (*)(id, SEL, id, id, id))original)(cls, sel, configuration, delegate, queue);
    }));
}

// 在代理类上记录数据与结束回调, 未实现的方法补上只做记录的实现
+ (void)hookDelegate:(id)delegate {
    Class cls = object_getClass(delegate);
    // NSProxy 转发给其他对象, 补上方法会截走原本要转发的回调
    if (LayerLensIsProxyClass(cls)) {
        return;
    }
    LayerLensNetworkRecorder *recorder = LayerLensNetworkRecorder.sharedRecorder;

    SEL dataSel = @selector(URLSession:dataTask:didReceiveData:);
    [self hookDelegate:delegate selector:dataSel types:"v@:@@@" factory:^id(IMP original) {
        NSString *key = @"layerlens.didReceiveData";
        return ^(id target, NSURLSession *session, NSURLSessionDataTask *task, NSData *data) {
            BOOL entered = LayerLensEnter(key);
            if (entered) {
                [recorder task:task didReceiveData:data];
            }
            if (original) {
                ((void (*)(id, SEL, id, id, id))original)(target, dataSel, session, task, data);
            }
            if (entered) {
                LayerLensLeave(key);
            }
        };
    }];

    SEL completeSel = @selector(URLSession:task:didCompleteWithError:);
    [self hookDelegate:delegate selector:completeSel types:"v@:@@@" factory:^id(IMP original) {
        return ^(id target, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
            [recorder task:task didCompleteWithData:nil error:error fromHandler:NO];
            if (original) {
                ((void (*)(id, SEL, id, id, id))original)(target, completeSel, session, task, error);
            }
        };
    }];
}

+ (void)hookDelegate:(id)delegate selector:(SEL)sel types:(const char *)types factory:(id (^)(IMP _Nullable original))factory {
    Class cls = object_getClass(delegate);
    if (class_getInstanceMethod(cls, sel)) {
        LayerLensHookMethod(cls, sel, factory);
        return;
    }
    // 通过消息转发响应的, 不补实现
    if ([delegate respondsToSelector:sel]) {
        return;
    }
    NSString *key = [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
    [LayerLensHookLock lock];
    if (![LayerLensHookedMethods containsObject:key]) {
        [LayerLensHookedMethods addObject:key];
        class_addMethod(cls, sel, imp_implementationWithBlock(factory(NULL)), types);
    }
    [LayerLensHookLock unlock];
}

@end
