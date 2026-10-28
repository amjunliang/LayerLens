//
//  LayerLensNetworkRecorder.h
//  LayerLens
//
//  Created by YueYou on 10/22/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 抓包记录: 只作为发给 Mac 的缓冲, Mac 取走并保存后释放; 较大的内容存到缓存目录, 只保留本次启动的数据.
/// 是否抓包由 Mac 端同步并保存在本机, 默认关闭, 开启时冷启动即开始记录.
/// 所有状态只在内部串行队列上读写, 记录方法任意线程可调用
@interface LayerLensNetworkRecorder : NSObject

/// 上次保存的抓包开关, 启动时据此决定是否安装 hook
@property (class, nonatomic, readonly) BOOL captureEnabledAtLaunch;
@property (nonatomic, readonly) BOOL capturing;
/// Mac 未连接期间超出上限而丢弃的请求数, 清空或关闭抓包时归零
@property (atomic, readonly) NSUInteger droppedCount;

/// 有变化的请求在内部队列回调, 每 200ms 最多一次, 同一请求只带最新的列表字段
@property (nonatomic, copy, nullable) void (^onFlush)(NSArray<NSDictionary *> *records);
/// 清空后在内部队列回调
@property (nonatomic, copy, nullable) void (^onClear)(void);

+ (instancetype)sharedRecorder;

#pragma mark - 由 LayerLensNetworkHooks 调用

/// 创建任务时带的上传内容: NSData 或文件 NSURL
- (void)setUploadBody:(id)body forTask:(NSURLSessionTask *)task;
/// 任务以 completionHandler 接收结果, 此后忽略代理的结束回调, 以 completionHandler 的为准
- (void)markHandlerTask:(NSURLSessionTask *)task;
- (void)taskDidResume:(NSURLSessionTask *)task;
- (void)task:(NSURLSessionTask *)task didReceiveData:(NSData *)data;
/// data 不为空时替换已累积的数据; fromHandler 表示来自 completionHandler
- (void)task:(NSURLSessionTask *)task didCompleteWithData:(nullable NSData *)data error:(nullable NSError *)error fromHandler:(BOOL)fromHandler;

#pragma mark - 查询

/// 序号大于 since 的请求的列表字段, 以及当前序号
- (void)recordsSince:(uint64_t)since completion:(void (^)(NSArray<NSDictionary *> *records))completion;
/// 不存在时为 nil
- (void)detailForIdentifier:(uint64_t)identifier completion:(void (^)(NSDictionary * _Nullable detail))completion;
/// side 为 req 或 res; 没有内容时 data 为 nil, message 为原因
- (void)bodyForIdentifier:(uint64_t)identifier side:(NSString *)side completion:(void (^)(NSData * _Nullable data, NSString *contentType, NSString * _Nullable message))completion;
/// 请求和响应内容中包含关键词的请求 id; query 以 \\ 开头为正则, 否则以 | 分隔多个关键词, 均不区分大小写.
/// 二进制内容不参与; 正则无效时 identifiers 为 nil.
/// candidates 不为空时只查找这些请求; 同一 client 发起新的查找时, 未完成的旧查找提前结束并返回空数组
- (void)searchBodiesWithQuery:(NSString *)query candidates:(nullable NSArray<NSNumber *> *)candidates client:(nullable NSString *)client completion:(void (^)(NSArray<NSNumber *> * _Nullable identifiers))completion;
/// 导出 HAR 1.2, identifiers 为空时导出全部; 文本内容原样写入, 其他以 base64 写入
- (void)HARWithIdentifiers:(nullable NSArray<NSNumber *> *)identifiers completion:(void (^)(NSData *data))completion;
- (void)clear;

#pragma mark - 由 Mac 端调用

/// 保存开关; 开启时安装 hook, 关闭时清空缓冲. 开启前已创建的带代理的会话收不到响应内容
- (void)setCapturing:(BOOL)capturing;
/// Mac 已保存的请求, 从缓冲中释放; 未结束的请求不释放
- (void)releaseIdentifiers:(NSArray<NSNumber *> *)identifiers;

@end

NS_ASSUME_NONNULL_END
