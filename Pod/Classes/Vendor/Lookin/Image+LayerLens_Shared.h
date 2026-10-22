
//
//  Image+Lookin.h
//  LayerLens_Shared
//
//  Created by 李凯 on 2022/4/2.
//

#import <Foundation/Foundation.h>

#if TARGET_OS_IPHONE

#elif TARGET_OS_MAC

@interface NSImage (LayerLens_Client)

- (NSData *)layerlens_data;

@end

#endif


