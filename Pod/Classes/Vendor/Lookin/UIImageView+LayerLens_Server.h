
//
//  UIImageView+LayerLens_Server.h
//  LayerLens_Server
//
//  Created by Li Kai on 2019/9/18.
//  https://lookin.work
//

#import <UIKit/UIKit.h>

@interface UIImageView (LayerLens_Server)

- (NSString *)layerlens_imageSourceName;
- (NSNumber *)layerlens_imageViewOidIfHasImage;

@end

