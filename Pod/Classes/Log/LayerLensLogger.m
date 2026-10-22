//
//  LayerLensLogger.m
//  LayerLens
//
//  Created by YueYou on 10/22/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LayerLensLogger.h"

// Mac 端连上前的日志只保留最近这些条, 内存有上限
static const NSUInteger kLayerLensLogBufferLimit = 5000;
// 单条日志的最大长度, 超出部分截断
static const NSUInteger kLayerLensLogMessageLimit = 100 * 1024;
static const NSUInteger kLayerLensLogFileKeep = 7;
static const int64_t kLayerLensLogFlushDelay = 100 * NSEC_PER_MSEC;

@interface LayerLensLogger ()

@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *buffer;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *pending;
@property (nonatomic, assign) uint64_t seq;
@property (nonatomic, assign) BOOL flushScheduled;
@property (nonatomic, strong, nullable) NSFileHandle *fileHandle;
@property (nonatomic, copy, nullable) NSString *fileDay;
@property (nonatomic, strong) NSDateFormatter *dayFormatter;
@property (nonatomic, strong) NSDateFormatter *timeFormatter;

@end

@implementation LayerLensLogger

+ (instancetype)sharedLogger {
    static LayerLensLogger *logger = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logger = [[LayerLensLogger alloc] init];
    });
    return logger;
}

- (instancetype)init {
    if (self = [super init]) {
        _queue = dispatch_queue_create("com.layerlens.log", DISPATCH_QUEUE_SERIAL);
        _buffer = [NSMutableArray array];
        _pending = [NSMutableArray array];
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
        _directory = [caches stringByAppendingPathComponent:@"LayerLens/Logs"];
        _dayFormatter = [self formatterWithFormat:@"yyyy-MM-dd"];
        _timeFormatter = [self formatterWithFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    }
    return self;
}

- (NSDateFormatter *)formatterWithFormat:(NSString *)format {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = format;
    return formatter;
}

#pragma mark - Log

- (void)log:(NSString *)message {
    if (![message isKindOfClass:NSString.class] || message.length == 0) {
        return;
    }
    NSDate *date = [NSDate date];
    if (message.length > kLayerLensLogMessageLimit) {
        message = [[message substringToIndex:kLayerLensLogMessageLimit] stringByAppendingString:@"… (truncated)"];
    }
    dispatch_async(self.queue, ^{
        self.seq += 1;
        NSDictionary *entry = @{@"s": @(self.seq), @"t": @((long long)(date.timeIntervalSince1970 * 1000)), @"m": message, @"d": date};
        [self.buffer addObject:entry];
        if (self.buffer.count > kLayerLensLogBufferLimit) {
            [self.buffer removeObjectsInRange:NSMakeRange(0, self.buffer.count - kLayerLensLogBufferLimit)];
        }
        [self.pending addObject:entry];
        if (!self.flushScheduled) {
            self.flushScheduled = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kLayerLensLogFlushDelay), self.queue, ^{
                [self flush];
            });
        }
    });
}

// 合并写文件并推送, 不逐行同步到磁盘
- (void)flush {
    self.flushScheduled = NO;
    if (self.pending.count == 0) {
        return;
    }
    NSArray<NSDictionary *> *entries = self.pending;
    self.pending = [NSMutableArray array];

    NSMutableString *text = [NSMutableString string];
    for (NSDictionary *entry in entries) {
        [text appendFormat:@"[%@] %@\n", [self.timeFormatter stringFromDate:entry[@"d"]], entry[@"m"]];
    }
    [self writeText:text date:entries.lastObject[@"d"]];

    if (self.onFlush) {
        self.onFlush([self publicEntries:entries]);
    }
}

// 去掉内部使用的 NSDate, 只留可序列化的字段
- (NSArray<NSDictionary *> *)publicEntries:(NSArray<NSDictionary *> *)entries {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:entries.count];
    for (NSDictionary *entry in entries) {
        [result addObject:@{@"s": entry[@"s"], @"t": entry[@"t"], @"m": entry[@"m"]}];
    }
    return result;
}

- (void)entriesSince:(uint64_t)since completion:(void (^)(NSArray<NSDictionary *> *))completion {
    dispatch_async(self.queue, ^{
        // 序号比当前还大说明对方记录的是上一次启动的进度, 全部给出
        uint64_t start = since > self.seq ? 0 : since;
        NSMutableArray *entries = [NSMutableArray array];
        for (NSDictionary *entry in self.buffer) {
            if ([entry[@"s"] unsignedLongLongValue] > start) {
                [entries addObject:entry];
            }
        }
        completion([self publicEntries:entries]);
    });
}

#pragma mark - File

- (void)writeText:(NSString *)text date:(NSDate *)date {
    NSString *day = [self.dayFormatter stringFromDate:date ?: [NSDate date]];
    if (!self.fileHandle || ![self.fileDay isEqualToString:day]) {
        [self.fileHandle closeFile];
        self.fileHandle = nil;
        NSFileManager *manager = NSFileManager.defaultManager;
        [manager createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [self.directory stringByAppendingPathComponent:[day stringByAppendingPathExtension:@"log"]];
        if (![manager fileExistsAtPath:path]) {
            [manager createFileAtPath:path contents:nil attributes:nil];
            [self removeOldFiles];
        }
        self.fileHandle = [NSFileHandle fileHandleForWritingAtPath:path];
        [self.fileHandle seekToEndOfFile];
        self.fileDay = day;
    }
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) {
        return;
    }
    @try {
        [self.fileHandle writeData:data];
    } @catch (NSException *exception) {
        // 磁盘已满等情况下放弃本次写入, 下次重新打开文件
        self.fileHandle = nil;
    }
}

- (NSArray<NSDictionary *> *)fileInfos {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *name in [manager contentsOfDirectoryAtPath:self.directory error:nil]) {
        if (![name.pathExtension isEqualToString:@"log"]) {
            continue;
        }
        NSDictionary *attributes = [manager attributesOfItemAtPath:[self.directory stringByAppendingPathComponent:name] error:nil];
        NSDate *modified = attributes.fileModificationDate ?: [NSDate distantPast];
        [files addObject:@{@"name": name, @"size": @(attributes.fileSize), @"modified": @((long long)(modified.timeIntervalSince1970 * 1000))}];
    }
    [files sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"modified"] compare:a[@"modified"]];
    }];
    return files;
}

- (void)removeOldFiles {
    NSArray<NSDictionary *> *files = [self fileInfos];
    for (NSUInteger i = kLayerLensLogFileKeep; i < files.count; i++) {
        [NSFileManager.defaultManager removeItemAtPath:[self.directory stringByAppendingPathComponent:files[i][@"name"]] error:nil];
    }
}

- (void)filesWithCompletion:(void (^)(NSArray<NSDictionary *> *))completion {
    dispatch_async(self.queue, ^{
        completion([self fileInfos]);
    });
}

- (void)readFile:(NSString *)name offset:(unsigned long long)offset length:(NSUInteger)length completion:(void (^)(NSData *, unsigned long long))completion {
    dispatch_async(self.queue, ^{
        // 只接受目录下的文件名, 防止路径穿越
        if (name.length == 0 || [name containsString:@"/"] || ![name.pathExtension isEqualToString:@"log"]) {
            completion(nil, 0);
            return;
        }
        NSString *path = [self.directory stringByAppendingPathComponent:name];
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
        if (!handle) {
            completion(nil, 0);
            return;
        }
        unsigned long long total = [handle seekToEndOfFile];
        NSData *data = [NSData data];
        if (offset < total) {
            [handle seekToFileOffset:offset];
            data = [handle readDataOfLength:(NSUInteger)MIN((unsigned long long)length, total - offset)];
        }
        [handle closeFile];
        completion(data, total);
    });
}

@end
