//
//  LayerLensStorage.h
//  LayerLens
//
//  Created by YueYou on 10/22/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// LayerLens 在设备上的缓存统一放在 Caches/LayerLens 下, 日志与抓包数据共用一个总大小上限.
/// 超出时按修改时间从旧到新删除文件, 最近仍在写入的文件不删除
@interface LayerLensStorage : NSObject

/// 所有缓存的总上限
@property (class, nonatomic, assign, readonly) unsigned long long limit;

/// 缓存根目录下的子目录路径, 不负责创建
+ (NSString *)directoryNamed:(NSString *)name;

/// 写入文件后调用, 合并为一次延后的检查, 任意线程可调用
+ (void)didWrite;

@end

NS_ASSUME_NONNULL_END
