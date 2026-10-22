
//
//  Image+Lookin.m
//  LayerLens_Shared
//
//  Created by 李凯 on 2022/4/2.
//

#import "Image+LayerLens_Shared.h"

#if TARGET_OS_IPHONE

#elif TARGET_OS_MAC

@implementation NSImage (LayerLens_Client)

- (NSData *)layerlens_data {
    return [self TIFFRepresentation];
}

@end

#endif

