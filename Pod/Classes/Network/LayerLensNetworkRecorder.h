//
//  LayerLensNetworkRecorder.h
//  LayerLens
//
//  Created by YueYou on 10/22/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 抓包记录: 内存中保留最近的请求, 较大的内容存到缓存目录; 只保留本次启动的数据.
/// 所有状态只在内部串行队列上读写, 记录方法任意线程可调用
@interface LayerLensNetworkRecorder : NSObject

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
/// 导出 HAR 1.2, identifiers 为空时导出全部; 文本内容原样写入, 其他以 base64 写入
- (void)HARWithIdentifiers:(nullable NSArray<NSNumber *> *)identifiers completion:(void (^)(NSData *data))completion;
- (void)clear;

@end

NS_ASSUME_NONNULL_END
