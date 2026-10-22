//
//  LayerLensLogger.h
//  LayerLens
//
//  Created by YueYou on 10/22/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 日志记录: 内存中保留最近的日志供 Mac 端连上时补齐, 同时按天写入设备上的日志文件.
/// 日志条目为 {"s": 序号, "t": 毫秒时间戳, "m": 内容}, 所有状态只在内部串行队列上读写
@interface LayerLensLogger : NSObject

/// 设备上的日志目录, 每天一个文件
@property (nonatomic, copy, readonly) NSString *directory;
/// 有新日志时在内部队列回调, 每 100ms 最多一次, 一次带上这段时间内的所有条目
@property (nonatomic, copy, nullable) void (^onFlush)(NSArray<NSDictionary *> *entries);

+ (instancetype)sharedLogger;

/// 任意线程可调用
- (void)log:(NSString *)message;

/// 序号大于 since 的缓冲条目, 在内部队列回调; 回调中发出的响应早于之后的 onFlush, 接收方按序号去重即可
- (void)entriesSince:(uint64_t)since completion:(void (^)(NSArray<NSDictionary *> *entries))completion;

/// 日志文件列表, 按修改时间从新到旧: {"name", "size", "modified"(毫秒)}
- (void)filesWithCompletion:(void (^)(NSArray<NSDictionary *> *files))completion;

/// 读取日志文件的一段, 文件不存在时 data 为 nil; total 为文件当前大小
- (void)readFile:(NSString *)name offset:(unsigned long long)offset length:(NSUInteger)length completion:(void (^)(NSData * _Nullable data, unsigned long long total))completion;

@end

NS_ASSUME_NONNULL_END
