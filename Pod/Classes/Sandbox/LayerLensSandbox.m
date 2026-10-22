//
//  LayerLensSandbox.m
//  LayerLens
//
//  Created by YueYou on 10/22/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LayerLensSandbox.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <sqlite3.h>
#import <zlib.h>

// 读取, 打包和上传都在内存中完成, 限制大小避免 App 被系统杀掉
static const unsigned long long kLayerLensSandboxMaxFileSize = 256 * 1024 * 1024;
// 单个数据库单元格的最大长度, 超出部分截断
static const NSUInteger kLayerLensSandboxCellLimit = 2000;

@implementation LayerLensSandbox

+ (unsigned long long)maxFileSize {
    return kLayerLensSandboxMaxFileSize;
}

#pragma mark - Path

+ (NSString *)rootPath {
    return [NSHomeDirectory() stringByStandardizingPath];
}

/// 相对路径转为绝对路径, 超出主目录时返回 nil
+ (nullable NSString *)absolutePath:(NSString *)path error:(NSError **)error {
    NSString *root = [self rootPath];
    NSString *result = [[root stringByAppendingPathComponent:path ?: @""] stringByStandardizingPath];
    if ([result isEqualToString:root] || [result hasPrefix:[root stringByAppendingString:@"/"]]) {
        return result;
    }
    [self setError:error status:403 message:@"Path is outside the sandbox"];
    return nil;
}

+ (NSString *)relativePath:(NSString *)path {
    NSString *root = [self rootPath];
    return path.length > root.length ? [path substringFromIndex:root.length + 1] : @"";
}

+ (void)setError:(NSError **)error status:(NSInteger)status message:(NSString *)message {
    if (error) {
        *error = [NSError errorWithDomain:@"LayerLensSandbox" code:status userInfo:@{NSLocalizedDescriptionKey: message ?: @""}];
    }
}

/// 存在且类型符合时返回 YES
+ (BOOL)checkPath:(NSString *)path directory:(BOOL)directory error:(NSError **)error {
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory]) {
        [self setError:error status:404 message:@"File not found"];
        return NO;
    }
    if (isDirectory != directory) {
        [self setError:error status:400 message:directory ? @"Not a directory" : @"Is a directory"];
        return NO;
    }
    return YES;
}

#pragma mark - List

+ (NSDictionary *)listDirectory:(NSString *)path error:(NSError **)error {
    NSString *absolute = [self absolutePath:path error:error];
    if (!absolute || ![self checkPath:absolute directory:YES error:error]) {
        return nil;
    }
    NSArray<NSURLResourceKey> *keys = @[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLFileSizeKey, NSURLContentModificationDateKey];
    NSError *listError = nil;
    NSArray<NSURL *> *urls = [NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:absolute] includingPropertiesForKeys:keys options:0 error:&listError];
    if (!urls) {
        [self setError:error status:500 message:listError.localizedDescription ?: @"List failed"];
        return nil;
    }
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        NSDictionary<NSURLResourceKey, id> *values = [url resourceValuesForKeys:keys error:nil];
        BOOL link = [values[NSURLIsSymbolicLinkKey] boolValue];
        // 符号链接按指向的目标显示
        NSDictionary<NSURLResourceKey, id> *target = link ? [url.URLByResolvingSymlinksInPath resourceValuesForKeys:keys error:nil] : values;
        NSDate *modified = target[NSURLContentModificationDateKey] ?: values[NSURLContentModificationDateKey] ?: [NSDate distantPast];
        [entries addObject:@{
            @"name": url.lastPathComponent ?: @"",
            @"dir": @([target[NSURLIsDirectoryKey] boolValue]),
            @"size": target[NSURLFileSizeKey] ?: @0,
            @"modified": @((long long)(modified.timeIntervalSince1970 * 1000)),
            @"link": @(link),
        }];
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        if ([a[@"dir"] boolValue] != [b[@"dir"] boolValue]) {
            return [a[@"dir"] boolValue] ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a[@"name"] localizedStandardCompare:b[@"name"]];
    }];
    return @{@"root": [self rootPath], @"path": [self relativePath:absolute], @"entries": entries};
}

#pragma mark - File

+ (NSData *)readFile:(NSString *)path limit:(unsigned long long)limit total:(nullable unsigned long long *)total error:(NSError **)error {
    NSString *absolute = [self absolutePath:path error:error];
    if (!absolute || ![self checkPath:absolute directory:NO error:error]) {
        return nil;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:absolute];
    if (!handle) {
        [self setError:error status:403 message:@"Permission denied"];
        return nil;
    }
    unsigned long long size = [handle seekToEndOfFile];
    if (total) {
        *total = size;
    }
    unsigned long long length = limit > 0 ? MIN(limit, size) : size;
    if (length > kLayerLensSandboxMaxFileSize) {
        [handle closeFile];
        [self setError:error status:413 message:@"File is too large"];
        return nil;
    }
    [handle seekToFileOffset:0];
    NSData *data = [handle readDataOfLength:(NSUInteger)length];
    [handle closeFile];
    return data ?: [NSData data];
}

+ (NSString *)contentTypeForPath:(NSString *)path {
    NSString *extension = path.pathExtension.lowercaseString;
    if ([@[@"log", @"txt", @"md", @"csv", @"strings", @"xml", @"html", @"js", @"css"] containsObject:extension]) {
        return @"text/plain; charset=utf-8";
    }
    if ([extension isEqualToString:@"json"]) {
        return @"application/json; charset=utf-8";
    }
    UTType *type = extension.length > 0 ? [UTType typeWithFilenameExtension:extension] : nil;
    return type.preferredMIMEType ?: @"application/octet-stream";
}

#pragma mark - Zip

+ (NSData *)zipItem:(NSString *)path error:(NSError **)error {
    NSString *absolute = [self absolutePath:path error:error];
    if (!absolute) {
        return nil;
    }
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:absolute isDirectory:&isDirectory]) {
        [self setError:error status:404 message:@"File not found"];
        return nil;
    }
    NSString *baseName = [absolute isEqualToString:[self rootPath]] ? @"Sandbox" : absolute.lastPathComponent;

    // 先收集条目并计算总大小, 超出上限时不读取文件
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    unsigned long long totalSize = 0;
    NSDictionary<NSFileAttributeKey, id> *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:absolute error:nil];
    [items addObject:@{@"name": baseName, @"path": absolute, @"dir": @(isDirectory), @"modified": attributes.fileModificationDate ?: [NSDate date]}];
    if (isDirectory) {
        NSDirectoryEnumerator<NSString *> *enumerator = [NSFileManager.defaultManager enumeratorAtPath:absolute];
        for (NSString *relative in enumerator) {
            NSDictionary<NSFileAttributeKey, id> *values = enumerator.fileAttributes;
            NSString *type = values.fileType;
            // 不跟随符号链接, 避免打包到沙盒之外或循环
            if (![type isEqualToString:NSFileTypeDirectory] && ![type isEqualToString:NSFileTypeRegular]) {
                continue;
            }
            BOOL dir = [type isEqualToString:NSFileTypeDirectory];
            [items addObject:@{@"name": [baseName stringByAppendingPathComponent:relative], @"path": [absolute stringByAppendingPathComponent:relative], @"dir": @(dir), @"modified": values.fileModificationDate ?: [NSDate date]}];
            totalSize += dir ? 0 : values.fileSize;
        }
    } else {
        totalSize = attributes.fileSize;
    }
    if (totalSize > kLayerLensSandboxMaxFileSize || items.count > UINT16_MAX) {
        [self setError:error status:413 message:@"Too large to download, pick a smaller folder"];
        return nil;
    }

    NSMutableData *archive = [NSMutableData dataWithCapacity:(NSUInteger)totalSize + items.count * 128];
    NSMutableData *directory = [NSMutableData data];
    for (NSDictionary *item in items) {
        BOOL dir = [item[@"dir"] boolValue];
        NSString *name = dir ? [item[@"name"] stringByAppendingString:@"/"] : item[@"name"];
        NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        // 读不到的文件(如权限不足)打包为空文件
        NSData *content = dir ? [NSData data] : ([NSData dataWithContentsOfFile:item[@"path"] options:NSDataReadingMappedIfSafe error:nil] ?: [NSData data]);
        uint32_t dosTime = [self dosTimeFromDate:item[@"modified"]];
        uint32_t crc = (uint32_t)crc32(0, content.bytes, (uInt)content.length);
        uint32_t offset = (uint32_t)archive.length;

        [self append32:0x04034b50 to:archive];
        [self append16:20 to:archive];
        [self append16:0x0800 to:archive];
        [self append16:0 to:archive];
        [self append32:dosTime to:archive];
        [self append32:crc to:archive];
        [self append32:(uint32_t)content.length to:archive];
        [self append32:(uint32_t)content.length to:archive];
        [self append16:(uint16_t)nameData.length to:archive];
        [self append16:0 to:archive];
        [archive appendData:nameData];
        [archive appendData:content];

        [self append32:0x02014b50 to:directory];
        [self append16:(3 << 8) | 20 to:directory];
        [self append16:20 to:directory];
        [self append16:0x0800 to:directory];
        [self append16:0 to:directory];
        [self append32:dosTime to:directory];
        [self append32:crc to:directory];
        [self append32:(uint32_t)content.length to:directory];
        [self append32:(uint32_t)content.length to:directory];
        [self append16:(uint16_t)nameData.length to:directory];
        [self append16:0 to:directory];
        [self append16:0 to:directory];
        [self append16:0 to:directory];
        [self append16:0 to:directory];
        // 高 16 位为 Unix 权限, 解压后保持可读写
        [self append32:dir ? ((040755u << 16) | 0x10) : (0100644u << 16) to:directory];
        [self append32:offset to:directory];
        [directory appendData:nameData];
    }
    uint32_t directoryOffset = (uint32_t)archive.length;
    [archive appendData:directory];
    [self append32:0x06054b50 to:archive];
    [self append16:0 to:archive];
    [self append16:0 to:archive];
    [self append16:(uint16_t)items.count to:archive];
    [self append16:(uint16_t)items.count to:archive];
    [self append32:(uint32_t)directory.length to:archive];
    [self append32:directoryOffset to:archive];
    [self append16:0 to:archive];
    return archive;
}

/// 低 16 位为时间, 高 16 位为日期
+ (uint32_t)dosTimeFromDate:(NSDate *)date {
    NSDateComponents *c = [NSCalendar.currentCalendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:date];
    uint32_t time = (uint32_t)((c.hour << 11) | (c.minute << 5) | (c.second / 2));
    uint32_t day = (uint32_t)(((MAX(c.year, 1980) - 1980) << 9) | (c.month << 5) | c.day);
    return (day << 16) | time;
}

+ (void)append16:(uint16_t)value to:(NSMutableData *)data {
    uint16_t little = CFSwapInt16HostToLittle(value);
    [data appendBytes:&little length:2];
}

+ (void)append32:(uint32_t)value to:(NSMutableData *)data {
    uint32_t little = CFSwapInt32HostToLittle(value);
    [data appendBytes:&little length:4];
}

#pragma mark - Preview

+ (id)propertyList:(NSString *)path error:(NSError **)error {
    NSData *data = [self readFile:path limit:0 total:NULL error:error];
    if (!data) {
        return nil;
    }
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil];
    if (!plist) {
        [self setError:error status:422 message:@"Not a property list"];
        return nil;
    }
    return [self JSONObjectFromPropertyList:plist];
}

+ (id)JSONObjectFromPropertyList:(id)object {
    if ([object isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        [(NSDictionary *)object enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            result[[key description] ?: @""] = [self JSONObjectFromPropertyList:value];
        }];
        return result;
    }
    if ([object isKindOfClass:NSArray.class]) {
        NSMutableArray *result = [NSMutableArray array];
        for (id value in (NSArray *)object) {
            [result addObject:[self JSONObjectFromPropertyList:value]];
        }
        return result;
    }
    if ([object isKindOfClass:NSData.class]) {
        return [NSString stringWithFormat:@"<data %lu bytes>", (unsigned long)[(NSData *)object length]];
    }
    if ([object isKindOfClass:NSDate.class]) {
        return [NSISO8601DateFormatter stringFromDate:object timeZone:NSTimeZone.localTimeZone formatOptions:NSISO8601DateFormatWithInternetDateTime];
    }
    return object ?: NSNull.null;
}

+ (NSDictionary *)queryDatabase:(NSString *)path table:(NSString *)table offset:(NSInteger)offset limit:(NSInteger)limit error:(NSError **)error {
    NSString *absolute = [self absolutePath:path error:error];
    if (!absolute || ![self checkPath:absolute directory:NO error:error]) {
        return nil;
    }
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(absolute.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        [self setError:error status:422 message:db ? @(sqlite3_errmsg(db)) : @"Open failed"];
        sqlite3_close(db);
        return nil;
    }
    sqlite3_busy_timeout(db, 1000);
    NSDictionary *result = nil;
    NSString *message = nil;
    if (table.length == 0) {
        NSMutableArray *tables = [NSMutableArray array];
        NSArray *rows = [self runQuery:@"SELECT name FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name" db:db columns:NULL message:&message];
        for (NSArray *row in rows) {
            NSString *name = [row.firstObject isKindOfClass:NSString.class] ? row.firstObject : @"";
            NSArray *count = [self runQuery:[NSString stringWithFormat:@"SELECT COUNT(*) FROM %@", [self quotedName:name]] db:db columns:NULL message:NULL];
            [tables addObject:@{@"name": name, @"count": [count.firstObject firstObject] ?: @0}];
        }
        result = rows ? @{@"tables": tables} : nil;
    } else {
        NSArray *columns = nil;
        NSString *sql = [NSString stringWithFormat:@"SELECT * FROM %@ LIMIT %ld OFFSET %ld", [self quotedName:table], (long)MIN(MAX(limit, 1), 1000), (long)MAX(offset, 0)];
        NSArray *rows = [self runQuery:sql db:db columns:&columns message:&message];
        NSArray *count = [self runQuery:[NSString stringWithFormat:@"SELECT COUNT(*) FROM %@", [self quotedName:table]] db:db columns:NULL message:NULL];
        result = rows ? @{@"columns": columns ?: @[], @"rows": rows, @"total": [count.firstObject firstObject] ?: @0} : nil;
    }
    sqlite3_close(db);
    if (!result) {
        [self setError:error status:422 message:message ?: @"Query failed"];
    }
    return result;
}

+ (NSString *)quotedName:(NSString *)name {
    return [NSString stringWithFormat:@"\"%@\"", [name stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

/// 执行查询, 返回每行的值数组; 失败时返回 nil
+ (nullable NSArray<NSArray *> *)runQuery:(NSString *)sql db:(sqlite3 *)db columns:(NSArray **)columns message:(NSString **)message {
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &statement, NULL) != SQLITE_OK) {
        if (message) {
            *message = @(sqlite3_errmsg(db)) ?: @"Query failed";
        }
        sqlite3_finalize(statement);
        return nil;
    }
    int count = sqlite3_column_count(statement);
    if (columns) {
        NSMutableArray *names = [NSMutableArray arrayWithCapacity:count];
        for (int i = 0; i < count; i++) {
            const char *name = sqlite3_column_name(statement, i);
            [names addObject:name ? @(name) : @""];
        }
        *columns = names;
    }
    NSMutableArray *rows = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        NSMutableArray *row = [NSMutableArray arrayWithCapacity:count];
        for (int i = 0; i < count; i++) {
            [row addObject:[self valueOfStatement:statement column:i]];
        }
        [rows addObject:row];
    }
    sqlite3_finalize(statement);
    return rows;
}

+ (id)valueOfStatement:(sqlite3_stmt *)statement column:(int)column {
    switch (sqlite3_column_type(statement, column)) {
        case SQLITE_INTEGER:
            return @(sqlite3_column_int64(statement, column));
        case SQLITE_FLOAT:
            return @(sqlite3_column_double(statement, column));
        case SQLITE_TEXT: {
            const char *text = (const char *)sqlite3_column_text(statement, column);
            NSString *string = text ? @(text) : nil;
            if (!string) {
                return @"<invalid text>";
            }
            return string.length > kLayerLensSandboxCellLimit ? [[string substringToIndex:kLayerLensSandboxCellLimit] stringByAppendingString:@"…"] : string;
        }
        case SQLITE_BLOB:
            return [NSString stringWithFormat:@"<blob %d bytes>", sqlite3_column_bytes(statement, column)];
        default:
            return NSNull.null;
    }
}

#pragma mark - Modify

+ (BOOL)writeData:(NSData *)data directory:(NSString *)directory name:(NSString *)name error:(NSError **)error {
    if (name.length == 0 || [name containsString:@"/"] || [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
        [self setError:error status:400 message:@"Invalid file name"];
        return NO;
    }
    NSString *absolute = [self absolutePath:directory error:error];
    if (!absolute || ![self checkPath:absolute directory:YES error:error]) {
        return NO;
    }
    NSString *target = [absolute stringByAppendingPathComponent:name];
    BOOL isDirectory = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:target isDirectory:&isDirectory] && isDirectory) {
        [self setError:error status:409 message:@"A folder with the same name exists"];
        return NO;
    }
    NSError *writeError = nil;
    if (![data ?: [NSData data] writeToFile:target options:NSDataWritingAtomic error:&writeError]) {
        [self setError:error status:500 message:writeError.localizedDescription ?: @"Write failed"];
        return NO;
    }
    return YES;
}

+ (BOOL)removeItem:(NSString *)path error:(NSError **)error {
    NSString *absolute = [self absolutePath:path error:error];
    if (!absolute) {
        return NO;
    }
    if ([absolute isEqualToString:[self rootPath]]) {
        [self setError:error status:403 message:@"Cannot delete the sandbox root"];
        return NO;
    }
    NSError *removeError = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:absolute error:&removeError]) {
        [self setError:error status:removeError.code == NSFileNoSuchFileError ? 404 : 500 message:removeError.localizedDescription ?: @"Delete failed"];
        return NO;
    }
    return YES;
}

@end
