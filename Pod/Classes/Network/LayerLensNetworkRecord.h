//
//  LayerLensNetworkRecord.h
//  LayerLens
//
//  Created by YueYou on 10/22/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 请求体或响应体的保存情况
typedef NS_ENUM(NSInteger, LayerLensBodyState) {
    LayerLensBodyStateNone,
    /// 已保存, 小的在内存, 大的在缓存文件
    LayerLensBodyStateStored,
    /// 超出单个上限, 只记录大小
    LayerLensBodyStateTooLarge,
    /// 以流的方式发送, 内容无法获取
    LayerLensBodyStateStream,
    /// 来自文件上传或下载到文件
    LayerLensBodyStateFile,
};

/// 一次请求的记录, 只在 LayerLensNetworkRecorder 的内部队列上读写
@interface LayerLensNetworkRecord : NSObject

@property (nonatomic, assign) uint64_t identifier;
/// 每次变化后更新, 网页据此增量同步
@property (nonatomic, assign) uint64_t seq;
@property (nonatomic, weak, nullable) NSURLSessionTask *task;
@property (nonatomic, copy) NSString *taskType;
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic, strong) NSDate *startDate;
@property (nonatomic, strong, nullable) NSDate *endDate;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, copy, nullable) NSString *mimeType;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *responseHeaders;
@property (nonatomic, copy, nullable) NSString *errorMessage;
/// 任务已结束但还没收到结束回调的时间, 超时后按任务当前状态补记
@property (nonatomic, strong, nullable) NSDate *completedSeenDate;

@property (nonatomic, assign) LayerLensBodyState requestBodyState;
@property (nonatomic, assign) unsigned long long requestBodySize;
@property (nonatomic, strong, nullable) NSData *requestBody;
@property (nonatomic, copy, nullable) NSString *requestBodyPath;

@property (nonatomic, assign) LayerLensBodyState responseBodyState;
@property (nonatomic, assign) unsigned long long responseBodySize;
@property (nonatomic, strong, nullable) NSData *responseBody;
@property (nonatomic, copy, nullable) NSString *responseBodyPath;
/// 进行中累积的响应数据, 结束后转存
@property (nonatomic, strong, nullable) NSMutableData *receivingData;

/// 列表中显示的字段
- (NSDictionary *)summary;
/// 详情: 列表字段之外加上请求头, 响应头与两端内容的保存情况
- (NSDictionary *)detail;

@end

NS_ASSUME_NONNULL_END
