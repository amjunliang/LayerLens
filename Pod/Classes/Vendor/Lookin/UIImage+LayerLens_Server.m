
//
//  UIImage+LayerLens_Server.m
//  LayerLens_Server
//
//  Created by Li Kai on 2019/5/14.
//  https://lookin.work
//

#import <objc/runtime.h>
#import "UIImage+LayerLens_Server.h"
#import "LayerLens_ServerDefines.h"

@implementation UIImage (LayerLens_Server)

#ifdef LAYERLENS_SERVER_DISABLE_HOOK

- (void)setLayerlens_imageSourceName:(NSString *)layerlens_imageSourceName {
}

- (NSString *)layerlens_imageSourceName {
    return nil;
}

#else

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method oriMethod = class_getClassMethod([self class], @selector(imageNamed:));
        Method newMethod = class_getClassMethod([self class], @selector(layerlens_imageNamed:));
        method_exchangeImplementations(oriMethod, newMethod);
        
        oriMethod = class_getClassMethod([self class], @selector(imageWithContentsOfFile:));
        newMethod = class_getClassMethod([self class], @selector(layerlens_imageWithContentsOfFile:));
        method_exchangeImplementations(oriMethod, newMethod);
        
        oriMethod = class_getClassMethod([self class], @selector(imageNamed:inBundle:compatibleWithTraitCollection:));
        newMethod = class_getClassMethod([self class], @selector(layerlens_imageNamed:inBundle:compatibleWithTraitCollection:));
        method_exchangeImplementations(oriMethod, newMethod);
        
        if (@available(iOS 13.0, tvOS 13.0, watchOS 6.0, *)) {
            oriMethod = class_getClassMethod([self class], @selector(imageNamed:inBundle:withConfiguration:));
            newMethod = class_getClassMethod([self class], @selector(layerlens_imageNamed:inBundle:withConfiguration:));
            method_exchangeImplementations(oriMethod, newMethod);
        }
    });
}

+ (nullable UIImage *)layerlens_imageNamed:(NSString *)name inBundle:(nullable NSBundle *)bundle withConfiguration:(nullable UIImageConfiguration *)configuration API_AVAILABLE(ios(13.0),tvos(13.0),watchos(6.0))
{
    UIImage *image = [self layerlens_imageNamed:name inBundle:bundle withConfiguration:configuration];
    image.layerlens_imageSourceName = name;
    return image;
}

+ (nullable UIImage *)layerlens_imageNamed:(NSString *)name inBundle:(nullable NSBundle *)bundle compatibleWithTraitCollection:(nullable UITraitCollection *)traitCollection API_AVAILABLE(ios(8.0))
{
    UIImage *image = [self layerlens_imageNamed:name inBundle:bundle compatibleWithTraitCollection:traitCollection];
    image.layerlens_imageSourceName = name;
    return image;
}

+ (UIImage *)layerlens_imageNamed:(NSString *)name {
    UIImage *image = [self layerlens_imageNamed:name];
    image.layerlens_imageSourceName = name;
    return image;
}

+ (UIImage *)layerlens_imageWithContentsOfFile:(NSString *)path {
    UIImage *image = [self layerlens_imageWithContentsOfFile:path];
    
    NSString *fileName = [[path componentsSeparatedByString:@"/"].lastObject componentsSeparatedByString:@"."].firstObject;
    image.layerlens_imageSourceName = fileName;
    return image;
}

- (void)setLayerlens_imageSourceName:(NSString *)layerlens_imageSourceName {
    [self layerlens_bindObject:layerlens_imageSourceName.copy forKey:@"layerlens_imageSourceName"];
}

- (NSString *)layerlens_imageSourceName {
    return [self layerlens_getBindObjectForKey:@"layerlens_imageSourceName"];
}

#endif /* LAYERLENS_SERVER_DISABLE_HOOK */

- (NSData *)layerlens_data {
    return UIImagePNGRepresentation(self);
}

@end

