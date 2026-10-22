
//
//  Color+Lookin.m
//  LayerLens_Shared
//
//  Created by 李凯 on 2022/4/2.
//

#import "Image+LayerLens_Shared.h"

#if TARGET_OS_IPHONE

#elif TARGET_OS_MAC

@implementation NSColor (LayerLens_Shared)

+ (instancetype)layerlens_colorFromRGBAComponents:(NSArray<NSNumber *> *)components {
    if (!components) {
        return nil;
    }
    if (components.count != 4) {
        NSAssert(NO, @"");
        return nil;
    }
    NSColor *color = [NSColor colorWithRed:components[0].doubleValue green:components[1].doubleValue blue:components[2].doubleValue alpha:components[3].doubleValue];
    return color;
}

- (NSArray<NSNumber *> *)layerlens_rgbaComponents {
    NSColor *rgbColor = [self colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CGFloat r, g, b, a;
    [rgbColor getRed:&r green:&g blue:&b alpha:&a];
    NSArray<NSNumber *> *rgba = @[@(r), @(g), @(b), @(a)];
    return rgba;
}

@end

#endif

