
//
//  UIVisualEffectView+LayerLens_Server.m
//  LayerLens_Server
//
//  Created by Li Kai on 2019/10/8.
//  https://lookin.work
//

#import "UIVisualEffectView+LayerLens_Server.h"
#import "UIBlurEffect+LayerLens_Server.h"

@implementation UIVisualEffectView (LayerLens_Server)

- (void)setLayerlens_blurEffectStyleNumber:(NSNumber *)layerlens_blurEffectStyleNumber {
    UIBlurEffectStyle style = [layerlens_blurEffectStyleNumber integerValue];
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:style];
    self.effect = effect;
}

- (NSNumber *)layerlens_blurEffectStyleNumber {
    UIVisualEffect *effect = self.effect;
    if (![effect isKindOfClass:[UIBlurEffect class]]) {
        return nil;
    }
    UIBlurEffect *blurEffect = (UIBlurEffect *)effect;
    return blurEffect.layerlens_effectStyleNumber;
}

@end

