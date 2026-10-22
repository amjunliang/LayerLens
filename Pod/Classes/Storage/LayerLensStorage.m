//
//  LayerLensStorage.m
//  LayerLens
//
//  Created by YueYou on 10/22/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LayerLensStorage.h"

static const unsigned long long kLayerLensStorageLimit = 300 * 1024 * 1024;
// 清理到上限的 90%, 避免刚清完又超出
static const double kLayerLensStorageTrimRatio = 0.9;
// 两次检查的最小间隔
static const int64_t kLayerLensStorageCheckDelay = 10 * NSEC_PER_SEC;
// 这段时间内修改过的文件视为仍在使用(当天的日志, 进行中的请求), 不删除
static const NSTimeInterval kLayerLensStorageActiveInterval = 60;

@implementation LayerLensStorage

+ (unsigned long long)limit {
    return kLayerLensStorageLimit;
}

+ (NSString *)rootDirectory {
    static NSString *root = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
        root = [caches stringByAppendingPathComponent:@"LayerLens"];
    });
    return root;
}

+ (NSString *)directoryNamed:(NSString *)name {
    return [[self rootDirectory] stringByAppendingPathComponent:name];
}

+ (dispatch_queue_t)queue {
    static dispatch_queue_t queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.layerlens.storage", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

+ (void)didWrite {
    static BOOL scheduled = NO;
    dispatch_async([self queue], ^{
        if (scheduled) {
            return;
        }
        scheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kLayerLensStorageCheckDelay), [self queue], ^{
            scheduled = NO;
            [self trim];
        });
    });
}

+ (void)trim {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *root = [NSURL fileURLWithPath:[self rootDirectory] isDirectory:YES];
    NSArray<NSURLResourceKey> *keys = @[NSURLIsRegularFileKey, NSURLFileAllocatedSizeKey, NSURLContentModificationDateKey];
    NSDirectoryEnumerator<NSURL *> *enumerator = [manager enumeratorAtURL:root includingPropertiesForKeys:keys options:0 errorHandler:nil];
    NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
    unsigned long long total = 0;
    for (NSURL *url in enumerator) {
        NSDictionary<NSURLResourceKey, id> *values = [url resourceValuesForKeys:keys error:nil];
        if (![values[NSURLIsRegularFileKey] boolValue]) {
            continue;
        }
        unsigned long long size = [values[NSURLFileAllocatedSizeKey] unsignedLongLongValue];
        total += size;
        [files addObject:@{@"url": url, @"size": @(size), @"date": values[NSURLContentModificationDateKey] ?: [NSDate distantPast]}];
    }
    if (total <= kLayerLensStorageLimit) {
        return;
    }
    [files sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"date"] compare:b[@"date"]];
    }];
    unsigned long long target = (unsigned long long)(kLayerLensStorageLimit * kLayerLensStorageTrimRatio);
    NSDate *activeSince = [NSDate dateWithTimeIntervalSinceNow:-kLayerLensStorageActiveInterval];
    for (NSDictionary *file in files) {
        if (total <= target || [file[@"date"] compare:activeSince] == NSOrderedDescending) {
            break;
        }
        if ([manager removeItemAtURL:file[@"url"] error:nil]) {
            total -= [file[@"size"] unsignedLongLongValue];
        }
    }
}

@end
