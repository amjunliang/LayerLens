
//
//  UIColor+LayerLens_Server.h
//  LayerLens_Server
//
//  Created by Li Kai on 2019/6/5.
//  https://lookin.work
//

#import <UIKit/UIKit.h>

@interface UIColor (LayerLens_Server)

- (NSArray<NSNumber *> *)layerlens_rgbaComponents;
+ (instancetype)layerlens_colorFromRGBAComponents:(NSArray<NSNumber *> *)components;

- (NSString *)layerlens_rgbaString;
- (NSString *)layerlens_hexString;

/// will check if the argument is a real CGColor
+ (UIColor *)layerlens_colorWithCGColor:(CGColorRef)cgColor;

@end

