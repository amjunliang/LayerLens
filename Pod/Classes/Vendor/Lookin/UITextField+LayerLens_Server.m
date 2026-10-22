
//
//  UITextField+LayerLens_Server.m
//  LayerLens_Server
//
//  Created by Li Kai on 2019/2/26.
//  https://lookin.work
//

#import "UITextField+LayerLens_Server.h"

@implementation UITextField (LayerLens_Server)

- (CGFloat)layerlens_fontSize {
    return self.font.pointSize;
}
- (void)setLayerlens_fontSize:(CGFloat)layerlens_fontSize {
    UIFont *font = [self.font fontWithSize:layerlens_fontSize];
    self.font = font;
}

- (NSString *)layerlens_fontName {
    return self.font.fontName;
}

@end

