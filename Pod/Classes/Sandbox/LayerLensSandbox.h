//
//  LayerLensSandbox.h
//  LayerLens
//
//  Created by YueYou on 10/22/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 沙盒文件访问, 路径均为相对 App 主目录(NSHomeDirectory)的路径, 超出主目录的路径一律拒绝.
/// 方法均为同步调用, 由调用方放到后台队列; 失败时 error 的 code 为对应的 HTTP 状态码
@interface LayerLensSandbox : NSObject

/// 单个文件读取, 打包和上传的大小上限
@property (class, nonatomic, readonly) unsigned long long maxFileSize;

/// 目录内容: {"root"(主目录绝对路径), "path", "entries": [{"name", "dir", "size", "modified"(毫秒), "link"}]}, 目录在前
+ (nullable NSDictionary *)listDirectory:(NSString *)path error:(NSError **)error;

/// 读取文件, limit 大于 0 时只读开头这么多字节; total 为文件大小
+ (nullable NSData *)readFile:(NSString *)path limit:(unsigned long long)limit total:(nullable unsigned long long *)total error:(NSError **)error;

/// 按扩展名推断的 MIME 类型
+ (NSString *)contentTypeForPath:(NSString *)path;

/// 把文件或目录打包成 zip(不压缩)
+ (nullable NSData *)zipItem:(NSString *)path error:(NSError **)error;

/// plist 转成可 JSON 序列化的对象, NSData 与 NSDate 转成字符串
+ (nullable id)propertyList:(NSString *)path error:(NSError **)error;

/// SQLite 数据库: table 为空时返回 {"tables": [{"name", "count"}]}, 否则返回 {"columns", "rows", "total"}
+ (nullable NSDictionary *)queryDatabase:(NSString *)path table:(nullable NSString *)table offset:(NSInteger)offset limit:(NSInteger)limit error:(NSError **)error;

/// 写入 directory 下名为 name 的文件, 已存在时覆盖
+ (BOOL)writeData:(NSData *)data directory:(NSString *)directory name:(NSString *)name error:(NSError **)error;

/// 删除文件或目录, 不允许删除主目录本身
+ (BOOL)removeItem:(NSString *)path error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
