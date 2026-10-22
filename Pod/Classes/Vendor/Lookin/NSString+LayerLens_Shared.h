
//
//  NSString+Lookin.h
//  Lookin
//
//  Created by Li Kai on 2019/5/11.
//  https://lookin.work
//

#import "LayerLens_Defines.h"



#import <Foundation/Foundation.h>

@interface NSString (LayerLens_Shared)

/**
 把 CGFloat 转成字符串，最多保留 3 位小数，转换后末尾的 0 会被删除
 如：1.2341 => @"1.234", 2.1002 => @"2.1", 3.000 => @"3"
 */
+ (NSString *)layerlens_stringFromDouble:(double)doubleValue decimal:(NSUInteger)decimal;

+ (NSString *)layerlens_stringFromRect:(CGRect)rect;

+ (NSString *)layerlens_stringFromInset:(LayerLens_Insets)insets;

+ (NSString *)layerlens_stringFromSize:(CGSize)size;

+ (NSString *)layerlens_stringFromPoint:(CGPoint)point;

+ (NSString *)layerlens_rgbaStringFromColor:(LayerLens_Color *)color;

- (NSString *)layerlens_safeInitWithUTF8String:(const char *)string;

/// 把 1.2.3 这种 String 版本号转换成数字，可用于大小比较，如 110205 代表 11.2.5 版本
- (NSInteger)layerlens_numbericOSVersion;

@end

