
//
//  UIImageView+LayerLens_Server.m
//  LayerLens_Server
//
//  Created by Li Kai on 2019/9/18.
//  https://lookin.work
//

#import "UIImageView+LayerLens_Server.h"
#import "UIImage+LayerLens_Server.h"
#import "NSObject+LayerLens_Server.h"

@implementation UIImageView (LayerLens_Server)

- (NSString *)layerlens_imageSourceName {
    return self.image.layerlens_imageSourceName;
}

- (NSNumber *)layerlens_imageViewOidIfHasImage {
    if (!self.image) {
        return nil;
    }
    unsigned long oid = [self layerlens_registerOid];
    return @(oid);
}

@end

