//
//  LayerLensNetworkRecorder.m
//  LayerLens
//
//  Created by YueYou on 10/22/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LayerLensNetworkRecorder.h"
#import "LayerLensNetworkRecord.h"
#import "LayerLensNetworkHooks.h"
#import "LayerLensStorage.h"
#import "LayerLens.h"
#import <objc/runtime.h>
#import <stdatomic.h>

static const NSUInteger kLayerLensNetworkRecordLimit = 1000;
// 不超过该大小的内容留在内存, 更大的写入缓存文件
static const NSUInteger kLayerLensNetworkInlineLimit = 16 * 1024;
// 单个内容的上限, 超出只记录大小
static const unsigned long long kLayerLensNetworkBodyLimit = 5 * 1024 * 1024;
// HAR 中单个内容的上限
static const NSUInteger kLayerLensNetworkHARBodyLimit = 1024 * 1024;
static const int64_t kLayerLensNetworkFlushDelay = 200 * NSEC_PER_MSEC;
static const int64_t kLayerLensNetworkSweepInterval = 2 * NSEC_PER_SEC;
// 任务已结束但迟迟没有结束回调(如 Swift async 接口), 等这么久后按任务状态补记
static const NSTimeInterval kLayerLensNetworkCompleteGrace = 2;

static _Atomic uint64_t LayerLensNetworkNextIdentifier = 0;
static NSString * const kLayerLensNetworkCaptureKey = @"LayerLensNetworkCapture";

// 任务上的关联对象用 selector 作 key, 热重载注入的镜像与原镜像共用
#define kLayerLensTaskIdentifierKey @selector(layerlens_networkIdentifier)
#define kLayerLensTaskHandlerKey @selector(layerlens_networkHandler)
#define kLayerLensTaskUploadKey @selector(layerlens_networkUpload)

@interface LayerLensNetworkRecorder ()

@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) NSString *directory;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, LayerLensNetworkRecord *> *records;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *order;
@property (nonatomic, strong) NSMutableOrderedSet<LayerLensNetworkRecord *> *changed;
@property (nonatomic, assign) uint64_t seq;
@property (nonatomic, assign) BOOL flushScheduled;
@property (nonatomic, strong, nullable) dispatch_source_t sweepTimer;
/// 内容查找串行执行, 避免多次查找同时占用 CPU
@property (nonatomic, strong) dispatch_queue_t searchQueue;
/// client -> 最新一次查找的序号, 用于取消旧查找
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *searchGenerations;
@property (nonatomic, assign) BOOL capturing;
@property (atomic, assign) NSUInteger droppedCount;

@end

@implementation LayerLensNetworkRecorder

+ (instancetype)sharedRecorder {
    static LayerLensNetworkRecorder *recorder = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        recorder = [[LayerLensNetworkRecorder alloc] init];
    });
    return recorder;
}

- (instancetype)init {
    if (self = [super init]) {
        _queue = dispatch_queue_create("com.layerlens.network", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        _directory = [LayerLensStorage directoryNamed:@"Network"];
        _records = [NSMutableDictionary dictionary];
        _order = [NSMutableArray array];
        _changed = [NSMutableOrderedSet orderedSet];
        _searchQueue = dispatch_queue_create("com.layerlens.network.search", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        _searchGenerations = [NSMutableDictionary dictionary];
        _capturing = LayerLensNetworkRecorder.captureEnabledAtLaunch;
        // 列表只在内存中, 上次启动留下的内容已无法查看
        dispatch_async(_queue, ^{
            [NSFileManager.defaultManager removeItemAtPath:self.directory error:nil];
        });
    }
    return self;
}

+ (BOOL)captureEnabledAtLaunch {
    return [NSUserDefaults.standardUserDefaults boolForKey:kLayerLensNetworkCaptureKey];
}

- (void)setCapturing:(BOOL)capturing {
    if (_capturing == capturing) {
        return;
    }
    _capturing = capturing;
    [NSUserDefaults.standardUserDefaults setBool:capturing forKey:kLayerLensNetworkCaptureKey];
    if (capturing) {
        [LayerLensNetworkHooks install];
    } else {
        [self clear];
    }
}

- (void)releaseIdentifiers:(NSArray<NSNumber *> *)identifiers {
    dispatch_async(self.queue, ^{
        NSMutableSet<NSNumber *> *released = [NSMutableSet set];
        for (NSNumber *identifier in identifiers) {
            LayerLensNetworkRecord *record = self.records[identifier];
            if (!record.finished) {
                continue;
            }
            [self.records removeObjectForKey:identifier];
            [self.changed removeObject:record];
            [self removeFilesOfRecord:record];
            [released addObject:identifier];
        }
        if (released.count > 0) {
            [self.order filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSNumber *identifier, NSDictionary *bindings) {
                return ![released containsObject:identifier];
            }]];
        }
    });
}

#pragma mark - Record

- (void)setUploadBody:(id)body forTask:(NSURLSessionTask *)task {
    if (body && task) {
        objc_setAssociatedObject(task, kLayerLensTaskUploadKey, body, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)markHandlerTask:(NSURLSessionTask *)task {
    if (task) {
        objc_setAssociatedObject(task, kLayerLensTaskHandlerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)taskDidResume:(NSURLSessionTask *)task {
    if (!self.capturing) {
        return;
    }
    // 上传任务是数据任务的子类, 先判断; WebSocket 等其他任务不记录
    NSString *type = [task isKindOfClass:NSURLSessionUploadTask.class] ? @"upload" : [task isKindOfClass:NSURLSessionDataTask.class] ? @"data" : [task isKindOfClass:NSURLSessionDownloadTask.class] ? @"download" : nil;
    if (!type) {
        return;
    }
    uint64_t identifier = 0;
    // 暂停后再次 resume 不重复记录
    @synchronized (task) {
        if (objc_getAssociatedObject(task, kLayerLensTaskIdentifierKey)) {
            return;
        }
        identifier = atomic_fetch_add(&LayerLensNetworkNextIdentifier, 1) + 1;
        objc_setAssociatedObject(task, kLayerLensTaskIdentifierKey, @(identifier), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSURLRequest *request = task.currentRequest ?: task.originalRequest;
    id upload = objc_getAssociatedObject(task, kLayerLensTaskUploadKey);
    NSDate *date = [NSDate date];
    dispatch_async(self.queue, ^{
        LayerLensNetworkRecord *record = [[LayerLensNetworkRecord alloc] init];
        record.identifier = identifier;
        record.task = task;
        record.taskType = type;
        record.method = request.HTTPMethod ?: @"GET";
        record.url = request.URL.absoluteString ?: @"";
        record.requestHeaders = request.allHTTPHeaderFields ?: @{};
        record.startDate = date;
        NSData *body = [upload isKindOfClass:NSData.class] ? upload : request.HTTPBody;
        if (body.length > 0) {
            [self storeBody:body forRecord:record request:YES];
        } else if ([upload isKindOfClass:NSURL.class]) {
            record.requestBodyState = LayerLensBodyStateFile;
            record.requestBodySize = [[NSFileManager.defaultManager attributesOfItemAtPath:[upload path] ?: @"" error:nil] fileSize];
        } else if (request.HTTPBodyStream) {
            record.requestBodyState = LayerLensBodyStateStream;
        }
        [self addRecord:record];
    });
}

- (void)task:(NSURLSessionTask *)task didReceiveData:(NSData *)data {
    NSNumber *identifier = objc_getAssociatedObject(task, kLayerLensTaskIdentifierKey);
    if (!identifier || data.length == 0) {
        return;
    }
    dispatch_async(self.queue, ^{
        LayerLensNetworkRecord *record = self.records[identifier];
        if (!record || record.finished) {
            return;
        }
        record.responseBodySize += data.length;
        if (record.responseBodySize <= kLayerLensNetworkBodyLimit) {
            if (!record.receivingData) {
                record.receivingData = [NSMutableData data];
            }
            [record.receivingData appendData:data];
        } else {
            record.receivingData = nil;
        }
        [self markChanged:record];
    });
}

- (void)task:(NSURLSessionTask *)task didCompleteWithData:(NSData *)data error:(NSError *)error fromHandler:(BOOL)fromHandler {
    NSNumber *identifier = objc_getAssociatedObject(task, kLayerLensTaskIdentifierKey);
    if (!identifier || (!fromHandler && objc_getAssociatedObject(task, kLayerLensTaskHandlerKey))) {
        return;
    }
    NSURLResponse *response = task.response;
    NSURLRequest *request = task.currentRequest;
    int64_t sent = task.countOfBytesSent;
    int64_t received = task.countOfBytesReceived;
    dispatch_async(self.queue, ^{
        [self finishRecord:self.records[identifier] response:response request:request data:data error:error sent:sent received:received];
    });
}

- (void)finishRecord:(LayerLensNetworkRecord *)record response:(NSURLResponse *)response request:(NSURLRequest *)request data:(NSData *)data error:(NSError *)error sent:(int64_t)sent received:(int64_t)received {
    if (!record || record.finished) {
        return;
    }
    record.finished = YES;
    record.endDate = [NSDate date];
    record.mimeType = response.MIMEType;
    if ([response isKindOfClass:NSHTTPURLResponse.class]) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        record.statusCode = http.statusCode;
        record.responseHeaders = [self stringHeaders:http.allHeaderFields];
    }
    // 发出时系统会补充部分请求头, 以结束时的为准
    if (request.allHTTPHeaderFields.count > 0) {
        NSMutableDictionary *headers = [record.requestHeaders mutableCopy] ?: [NSMutableDictionary dictionary];
        [headers addEntriesFromDictionary:request.allHTTPHeaderFields];
        record.requestHeaders = headers;
    }
    if (error) {
        record.errorMessage = error.code == NSURLErrorCancelled ? @"Cancelled" : error.localizedDescription ?: @"Failed";
    }
    if (record.requestBodyState == LayerLensBodyStateStream || record.requestBodyState == LayerLensBodyStateFile) {
        record.requestBodySize = MAX(sent, 0);
    }
    if ([record.taskType isEqualToString:@"download"]) {
        record.responseBodyState = LayerLensBodyStateFile;
        record.responseBodySize = MAX(received, 0);
    } else if (data) {
        [self storeBody:data forRecord:record request:NO];
    } else if (record.receivingData) {
        [self storeBody:record.receivingData forRecord:record request:NO];
    } else if (record.responseBodySize > kLayerLensNetworkBodyLimit) {
        record.responseBodyState = LayerLensBodyStateTooLarge;
    } else if (record.responseBodySize == 0 && received > 0) {
        // 没有拿到数据回调时只记录大小
        record.responseBodySize = received;
    }
    record.receivingData = nil;
    [self markChanged:record];
}

- (NSDictionary<NSString *, NSString *> *)stringHeaders:(NSDictionary *)headers {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [headers enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        result[[key description]] = [value description];
    }];
    return result;
}

- (void)storeBody:(NSData *)data forRecord:(LayerLensNetworkRecord *)record request:(BOOL)isRequest {
    unsigned long long size = data.length;
    LayerLensBodyState state = LayerLensBodyStateNone;
    NSData *inlineData = nil;
    NSString *path = nil;
    if (size > kLayerLensNetworkBodyLimit) {
        state = LayerLensBodyStateTooLarge;
    } else if (size > kLayerLensNetworkInlineLimit) {
        state = LayerLensBodyStateStored;
        [NSFileManager.defaultManager createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:nil];
        path = [self.directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%llu-%@", record.identifier, isRequest ? @"req" : @"res"]];
        // 写入失败时详情中显示为已清理
        [data writeToFile:path atomically:NO];
        [LayerLensStorage didWrite];
    } else if (size > 0) {
        state = LayerLensBodyStateStored;
        inlineData = [data copy];
    }
    if (isRequest) {
        record.requestBodyState = state;
        record.requestBodySize = size;
        record.requestBody = inlineData;
        record.requestBodyPath = path;
    } else {
        record.responseBodyState = state;
        record.responseBodySize = size;
        record.responseBody = inlineData;
        record.responseBodyPath = path;
    }
}

- (void)addRecord:(LayerLensNetworkRecord *)record {
    self.records[@(record.identifier)] = record;
    [self.order addObject:@(record.identifier)];
    while (self.order.count > kLayerLensNetworkRecordLimit) {
        LayerLensNetworkRecord *oldest = self.records[self.order.firstObject];
        [self.order removeObjectAtIndex:0];
        if (oldest) {
            // Mac 取走的已释放, 留到这里的都是未保存就被挤掉的
            self.droppedCount += 1;
            [self.records removeObjectForKey:@(oldest.identifier)];
            [self.changed removeObject:oldest];
            [self removeFilesOfRecord:oldest];
        }
    }
    [self markChanged:record];
    [self startSweepIfNeeded];
}

- (void)removeFilesOfRecord:(LayerLensNetworkRecord *)record {
    for (NSString *path in @[record.requestBodyPath ?: @"", record.responseBodyPath ?: @""]) {
        if (path.length > 0) {
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        }
    }
}

- (void)markChanged:(LayerLensNetworkRecord *)record {
    self.seq += 1;
    record.seq = self.seq;
    [self.changed addObject:record];
    if (!self.flushScheduled) {
        self.flushScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kLayerLensNetworkFlushDelay), self.queue, ^{
            [self flush];
        });
    }
}

- (void)flush {
    self.flushScheduled = NO;
    if (self.changed.count == 0) {
        return;
    }
    NSMutableArray *summaries = [NSMutableArray arrayWithCapacity:self.changed.count];
    for (LayerLensNetworkRecord *record in self.changed) {
        [summaries addObject:[record summary]];
    }
    [self.changed removeAllObjects];
    if (self.onFlush) {
        self.onFlush(summaries);
    }
}

#pragma mark - Sweep

- (void)startSweepIfNeeded {
    if (self.sweepTimer) {
        return;
    }
    self.sweepTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_timer(self.sweepTimer, dispatch_time(DISPATCH_TIME_NOW, kLayerLensNetworkSweepInterval), kLayerLensNetworkSweepInterval, NSEC_PER_SEC / 2);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.sweepTimer, ^{
        [weakSelf sweep];
    });
    dispatch_resume(self.sweepTimer);
}

// 补记没有收到结束回调的请求, 没有进行中的请求时停止
- (void)sweep {
    BOOL pending = NO;
    NSDate *now = [NSDate date];
    for (NSNumber *identifier in [self.order copy]) {
        LayerLensNetworkRecord *record = self.records[identifier];
        if (!record || record.finished) {
            continue;
        }
        NSURLSessionTask *task = record.task;
        if (task && task.state != NSURLSessionTaskStateCompleted) {
            pending = YES;
            continue;
        }
        if (!record.completedSeenDate) {
            record.completedSeenDate = now;
        }
        if ([now timeIntervalSinceDate:record.completedSeenDate] < kLayerLensNetworkCompleteGrace) {
            pending = YES;
            continue;
        }
        NSError *error = task ? task.error : [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorUnknown userInfo:@{NSLocalizedDescriptionKey: @"Result not captured"}];
        [self finishRecord:record response:task.response request:task.currentRequest data:nil error:error sent:task.countOfBytesSent received:task.countOfBytesReceived];
    }
    if (!pending) {
        dispatch_source_cancel(self.sweepTimer);
        self.sweepTimer = nil;
    }
}

#pragma mark - Query

- (void)recordsSince:(uint64_t)since completion:(void (^)(NSArray<NSDictionary *> *))completion {
    dispatch_async(self.queue, ^{
        // 序号比当前还大说明对方记录的是上一次启动的进度, 全部给出
        uint64_t start = since > self.seq ? 0 : since;
        NSMutableArray *summaries = [NSMutableArray array];
        for (NSNumber *identifier in self.order) {
            LayerLensNetworkRecord *record = self.records[identifier];
            if (record.seq > start) {
                [summaries addObject:[record summary]];
            }
        }
        completion(summaries);
    });
}

- (void)detailForIdentifier:(uint64_t)identifier completion:(void (^)(NSDictionary *))completion {
    dispatch_async(self.queue, ^{
        completion([self.records[@(identifier)] detail]);
    });
}

- (void)bodyForIdentifier:(uint64_t)identifier side:(NSString *)side completion:(void (^)(NSData *, NSString *, NSString *))completion {
    dispatch_async(self.queue, ^{
        LayerLensNetworkRecord *record = self.records[@(identifier)];
        if (!record) {
            completion(nil, @"", @"Request not found");
            return;
        }
        BOOL isRequest = [side isEqualToString:@"req"];
        NSData *data = [self bodyOfRecord:record request:isRequest];
        NSDictionary *headers = isRequest ? record.requestHeaders : record.responseHeaders;
        NSString *contentType = [self headerNamed:@"Content-Type" in:headers] ?: (isRequest ? nil : record.mimeType) ?: @"application/octet-stream";
        if (data) {
            completion(data, contentType, nil);
            return;
        }
        NSDictionary *messages = @{@"none": @"No content", @"tooLarge": @"Content over 5 MB is not saved", @"stream": @"Sent as a stream, content is not available", @"file": @"File content is not saved", @"evicted": @"Removed by cache cleanup", @"stored": @"Removed by cache cleanup"};
        NSString *state = [record detail][isRequest ? @"reqBody" : @"resBody"];
        completion(nil, contentType, messages[state] ?: @"No content");
    });
}

- (void)searchBodiesWithQuery:(NSString *)query candidates:(NSArray<NSNumber *> *)candidates client:(NSString *)client completion:(void (^)(NSArray<NSNumber *> *))completion {
    NSRegularExpression *regex = [self searchRegexWithQuery:query];
    if (!regex) {
        completion(nil);
        return;
    }
    NSString *key = client ?: @"";
    NSUInteger generation = 0;
    @synchronized (self.searchGenerations) {
        // 只保留最近的 client, 避免页面反复刷新后无限增长
        if (self.searchGenerations.count > 32 && !self.searchGenerations[key]) {
            [self.searchGenerations removeAllObjects];
        }
        generation = self.searchGenerations[key].unsignedIntegerValue + 1;
        self.searchGenerations[key] = @(generation);
    }
    BOOL (^cancelled)(void) = ^BOOL {
        @synchronized (self.searchGenerations) {
            return self.searchGenerations[key].unsignedIntegerValue != generation;
        }
    };
    NSSet<NSNumber *> *candidateSet = candidates ? [NSSet setWithArray:candidates] : nil;
    dispatch_async(self.queue, ^{
        // 在内部队列取内容的快照, 读文件和匹配放到后台, 不阻塞记录
        NSMutableArray<NSArray *> *items = [NSMutableArray array];
        for (NSNumber *identifier in self.order) {
            if (candidateSet && ![candidateSet containsObject:identifier]) {
                continue;
            }
            LayerLensNetworkRecord *record = self.records[identifier];
            id request = record.requestBody ?: record.requestBodyPath;
            id response = record.responseBody ?: record.responseBodyPath;
            if (request || response) {
                [items addObject:@[identifier, request ?: NSNull.null, response ?: NSNull.null]];
            }
        }
        dispatch_async(self.searchQueue, ^{
            NSMutableArray<NSNumber *> *identifiers = [NSMutableArray array];
            for (NSArray *item in items) {
                if (cancelled()) {
                    completion(@[]);
                    return;
                }
                if ([self body:item[2] matches:regex] || [self body:item[1] matches:regex]) {
                    [identifiers addObject:item[0]];
                }
            }
            completion(identifiers);
        });
    });
}

- (NSRegularExpression *)searchRegexWithQuery:(NSString *)query {
    NSString *pattern = nil;
    if ([query hasPrefix:@"\\"]) {
        pattern = [query substringFromIndex:1];
    } else {
        NSMutableArray<NSString *> *terms = [NSMutableArray array];
        for (NSString *term in [query componentsSeparatedByString:@"|"]) {
            NSString *trimmed = [term stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (trimmed.length > 0) {
                [terms addObject:[NSRegularExpression escapedPatternForString:trimmed]];
            }
        }
        pattern = [terms componentsJoinedByString:@"|"];
    }
    if (pattern.length == 0) {
        return nil;
    }
    return [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
}

- (BOOL)body:(id)body matches:(NSRegularExpression *)regex {
    NSData *data = [body isKindOfClass:NSString.class] ? [NSData dataWithContentsOfFile:body] : ([body isKindOfClass:NSData.class] ? body : nil);
    if (data.length == 0) {
        return NO;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        return NO;
    }
    if ([regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)]) {
        return YES;
    }
    // JSON 中的中文常转义为 \uXXXX, 还原后再匹配一次
    if ([text containsString:@"\\u"]) {
        NSString *decoded = [text stringByApplyingTransform:@"Any-Hex/Java" reverse:YES];
        return decoded && [regex firstMatchInString:decoded options:0 range:NSMakeRange(0, decoded.length)];
    }
    return NO;
}

- (NSData *)bodyOfRecord:(LayerLensNetworkRecord *)record request:(BOOL)isRequest {
    NSData *data = isRequest ? record.requestBody : record.responseBody;
    NSString *path = isRequest ? record.requestBodyPath : record.responseBodyPath;
    if (!data && path) {
        data = [NSData dataWithContentsOfFile:path];
    }
    return data;
}

- (NSString *)headerNamed:(NSString *)name in:(NSDictionary<NSString *, NSString *> *)headers {
    for (NSString *key in headers) {
        if ([key caseInsensitiveCompare:name] == NSOrderedSame) {
            return headers[key];
        }
    }
    return nil;
}

- (void)clear {
    dispatch_async(self.queue, ^{
        [self.records removeAllObjects];
        [self.order removeAllObjects];
        [self.changed removeAllObjects];
        self.droppedCount = 0;
        [NSFileManager.defaultManager removeItemAtPath:self.directory error:nil];
        if (self.onClear) {
            self.onClear();
        }
    });
}

#pragma mark - HAR

- (void)HARWithIdentifiers:(NSArray<NSNumber *> *)identifiers completion:(void (^)(NSData *))completion {
    dispatch_async(self.queue, ^{
        NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        NSMutableArray *entries = [NSMutableArray array];
        for (NSNumber *identifier in identifiers.count > 0 ? identifiers : self.order) {
            LayerLensNetworkRecord *record = self.records[identifier];
            if (record) {
                [entries addObject:[self HAREntryOfRecord:record formatter:formatter]];
            }
        }
        NSDictionary *har = @{@"log": @{@"version": @"1.2", @"creator": @{@"name": @"LayerLens", @"version": LayerLensVersion}, @"entries": entries}};
        completion([NSJSONSerialization dataWithJSONObject:har options:0 error:nil] ?: [NSData data]);
    });
}

- (NSDictionary *)HAREntryOfRecord:(LayerLensNetworkRecord *)record formatter:(NSISO8601DateFormatter *)formatter {
    long long time = record.endDate ? (long long)([record.endDate timeIntervalSinceDate:record.startDate] * 1000) : -1;
    NSMutableDictionary *request = [@{
        @"method": record.method ?: @"GET",
        @"url": record.url ?: @"",
        @"httpVersion": @"HTTP/1.1",
        @"headers": [self HARHeaders:record.requestHeaders],
        @"queryString": [self HARQuery:record.url],
        @"cookies": @[],
        @"headersSize": @(-1),
        @"bodySize": @(record.requestBodySize),
    } mutableCopy];
    NSData *requestBody = [self bodyOfRecord:record request:YES];
    if (requestBody.length > 0 && requestBody.length <= kLayerLensNetworkHARBodyLimit) {
        NSString *text = [[NSString alloc] initWithData:requestBody encoding:NSUTF8StringEncoding];
        request[@"postData"] = @{@"mimeType": [self headerNamed:@"Content-Type" in:record.requestHeaders] ?: @"", @"text": text ?: [requestBody base64EncodedStringWithOptions:0]};
    }
    NSMutableDictionary *content = [@{@"size": @(record.responseBodySize), @"mimeType": record.mimeType ?: @""} mutableCopy];
    NSData *responseBody = [self bodyOfRecord:record request:NO];
    if (responseBody.length > 0 && responseBody.length <= kLayerLensNetworkHARBodyLimit) {
        NSString *text = [[NSString alloc] initWithData:responseBody encoding:NSUTF8StringEncoding];
        content[@"text"] = text ?: [responseBody base64EncodedStringWithOptions:0];
        if (!text) {
            content[@"encoding"] = @"base64";
        }
    }
    NSMutableDictionary *entry = [@{
        @"startedDateTime": [formatter stringFromDate:record.startDate] ?: @"",
        @"time": @(MAX(time, 0)),
        @"request": request,
        @"response": @{
            @"status": @(record.statusCode),
            @"statusText": record.statusCode > 0 ? [NSHTTPURLResponse localizedStringForStatusCode:record.statusCode] : @"",
            @"httpVersion": @"HTTP/1.1",
            @"headers": [self HARHeaders:record.responseHeaders],
            @"cookies": @[],
            @"content": content,
            @"redirectURL": [self headerNamed:@"Location" in:record.responseHeaders] ?: @"",
            @"headersSize": @(-1),
            @"bodySize": @(record.responseBodySize),
        },
        @"cache": @{},
        @"timings": @{@"send": @0, @"wait": @(MAX(time, 0)), @"receive": @0},
    } mutableCopy];
    if (record.errorMessage) {
        entry[@"_error"] = record.errorMessage;
    }
    return entry;
}

- (NSArray *)HARHeaders:(NSDictionary<NSString *, NSString *> *)headers {
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *name in [headers.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
        [result addObject:@{@"name": name, @"value": headers[name] ?: @""}];
    }
    return result;
}

- (NSArray *)HARQuery:(NSString *)url {
    NSMutableArray *result = [NSMutableArray array];
    for (NSURLQueryItem *item in [NSURLComponents componentsWithString:url ?: @""].queryItems) {
        [result addObject:@{@"name": item.name ?: @"", @"value": item.value ?: @""}];
    }
    return result;
}

@end
