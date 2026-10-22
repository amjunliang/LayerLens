
//
//  LayerLens_Helper.h
//  LayerLens_Server
//
//  Created by Li Kai on 2019/7/20.
//  https://lookin.work
//

#import "LayerLens_Defines.h"



#import <Foundation/Foundation.h>

#define LayerLens_Localized(stringKey) NSLocalizedStringFromTableInBundle(stringKey, nil, [NSBundle bundleForClass:self.class], nil)

@interface LayerLens_Helper : NSObject

/// 如果 object 为 nil 则返回字符串 “nil”，否则返回字符串格式类似于 (UIView *)
+ (NSString *)descriptionOfObject:(id)object;

/// 返回当前的bundle
+ (NSBundle *)bundle;

@end

