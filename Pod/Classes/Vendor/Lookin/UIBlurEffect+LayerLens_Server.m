
//
//  UIBlurEffect+LayerLens_Server.m
//  LayerLens_Server
//
//  Created by Li Kai on 2019/10/8.
//  https://lookin.work
//

#import "UIBlurEffect+LayerLens_Server.h"
#import "NSObject+LayerLens_Shared.h"
#import <objc/runtime.h>

@implementation UIBlurEffect (LayerLens_Server)

#ifdef LAYERLENS_SERVER_DISABLE_HOOK

- (void)setLayerlens_effectStyleNumber:(NSNumber *)layerlens_effectStyleNumber {
}

- (NSNumber *)layerlens_effectStyleNumber {
    return nil;
}

#else

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method oriMethod = class_getClassMethod([self class], @selector(effectWithStyle:));
        Method newMethod = class_getClassMethod([self class], @selector(layerlens_effectWithStyle:));
        method_exchangeImplementations(oriMethod, newMethod);
    });
}

+ (UIBlurEffect *)layerlens_effectWithStyle:(UIBlurEffectStyle)style {
    id effect = [self layerlens_effectWithStyle:style];
    if ([effect respondsToSelector:@selector(setLayerlens_effectStyleNumber:)]) {
        [effect setLayerlens_effectStyleNumber:@(style)];
    }
    return effect;
}

- (void)setLayerlens_effectStyleNumber:(NSNumber *)layerlens_effectStyleNumber {
    [self layerlens_bindObject:layerlens_effectStyleNumber forKey:@"layerlens_effectStyleNumber"];
}

- (NSNumber *)layerlens_effectStyleNumber {
    return [self layerlens_getBindObjectForKey:@"layerlens_effectStyleNumber"];
}

#endif /* LAYERLENS_SERVER_DISABLE_HOOK */

@end

