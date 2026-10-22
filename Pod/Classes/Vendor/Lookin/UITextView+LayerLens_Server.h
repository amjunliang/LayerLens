
//
//  UITextView+LayerLens_Server.h
//  LayerLens_Server
//
//  Created by Li Kai on 2019/2/26.
//  https://lookin.work
//

#import <UIKit/UIKit.h>

@interface UITextView (LayerLens_Server)

@property(nonatomic, assign) CGFloat layerlens_fontSize;

- (NSString *)layerlens_fontName;

@end

