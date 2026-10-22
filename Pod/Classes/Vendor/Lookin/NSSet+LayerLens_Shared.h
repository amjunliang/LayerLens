
//
//  NSSet+Lookin.h
//  Lookin
//
//  Created by Li Kai on 2019/1/13.
//  https://lookin.work
//

#import "LayerLens_Defines.h"



#import "TargetConditionals.h"
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#elif TARGET_OS_MAC
#import <Appkit/Appkit.h>
#endif

@interface NSSet<__covariant ValueType> (LayerLens_Shared)

- (NSSet *)layerlens_map:(id (^)(ValueType obj))block;

- (ValueType)layerlens_firstFiltered:(BOOL (^)(ValueType obj))block;

- (NSSet<ValueType> *)layerlens_filter:(BOOL (^)(ValueType obj))block;


/**
 是否有任何一个元素满足某条件
 @note 元素将被依次传入 block 里，如果任何一个 block 返回 YES，则该方法返回 YES。如果所有 block 均返回 NO，则该方法返回 NO。
 */
- (BOOL)layerlens_any:(BOOL (^)(ValueType obj))block;

@end

