
//
//  UIImage+LayerLens_Server.h
//  LayerLens_Server
//
//  Created by Li Kai on 2019/5/14.
//  https://lookin.work
//

#import <UIKit/UIKit.h>

@interface UIImage (LayerLens_Server)

/// 该方法的实现需要 Hook，因此若定义了 LAYERLENS_SERVER_DISABLE_HOOK 宏，则属性会返回 nil
@property(nonatomic, copy) NSString *layerlens_imageSourceName;

- (NSData *)layerlens_data;

@end

