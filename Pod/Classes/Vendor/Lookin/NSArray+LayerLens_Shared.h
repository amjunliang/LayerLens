
//
//  NSArray+Lookin.h
//  Lookin
//
//  Created by Li Kai on 2018/9/3.
//  https://lookin.work
//

#import "LayerLens_Defines.h"



#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface NSArray<__covariant ValueType> (LayerLens_Shared)

/**
 初始化一个新的 NSArray 并返回，新数组的长度为 count，如果当前数组长度比 count 小则会补充新元素（被补充的元素由 addBlock 返回），如果当前数组长度比 count 大则会舍弃多余的元素，被舍弃的元素会作为参数传入 removeBlock。最终，新数组的所有元素均会作为参数被传入 doBlock。
 */
- (NSArray<ValueType> *)layerlens_resizeWithCount:(NSUInteger)count add:(ValueType (^)(NSUInteger idx))addBlock remove:(void (^)(NSUInteger idx, ValueType obj))removeBlock doNext:(void (^)(NSUInteger idx, ValueType obj))doBlock __attribute__((warn_unused_result));

+ (NSArray *)layerlens_arrayWithCount:(NSUInteger)count block:(id (^)(NSUInteger idx))block;

/**
 检查 index 位置是否有元素存在
 */
- (BOOL)layerlens_hasIndex:(NSInteger)index;

- (NSArray *)layerlens_map:(id (^)(NSUInteger idx, ValueType value))block;

- (NSArray<ValueType> *)layerlens_filter:(BOOL (^)( ValueType obj))block;

- (ValueType)layerlens_firstFiltered:(BOOL (^)(ValueType obj))block;

/// 返回最后一个 block 返回 YES 的元素
- (ValueType)layerlens_lastFiltered:(BOOL (^)(ValueType obj))block;

- (id)layerlens_reduce:(id (^)(id accumulator, NSUInteger idx, ValueType obj))block;

- (CGFloat)layerlens_reduceCGFloat:(CGFloat (^)(CGFloat accumulator, NSUInteger idx, ValueType obj))block initialAccumlator:(CGFloat)initialAccumlator;
- (NSInteger)layerlens_reduceInteger:(NSInteger (^)(NSInteger accumulator, NSUInteger idx, ValueType obj))block initialAccumlator:(NSInteger)initialAccumlator;

- (BOOL)layerlens_all:(BOOL (^)(ValueType obj))block;

- (BOOL)layerlens_any:(BOOL (^)(ValueType obj))block;

- (NSArray<ValueType> *)layerlens_arrayByRemovingObject:(ValueType)obj;

- (NSArray<ValueType> *)layerlens_nonredundantArray;

- (ValueType)layerlens_safeObjectAtIndex:(NSInteger)idx;

/// 字符串长度从短到长，即 length 小的字符串的 idx 更小
- (NSArray<ValueType> *)layerlens_sortedArrayByStringLength;

@end

@interface NSMutableArray<ValueType> (LayerLens_Shared)

/**
 如果当前数组长度比 count 小则会补充新元素（被补充的元素由 addBlock 返回），如果当前数组长度比 count 大则多余的元素会被作为参数传入 notDequeued。然后从 idx 为 0 算起，前 count 个元素会被作为参数传入 doBlock
 */
- (void)layerlens_dequeueWithCount:(NSUInteger)count add:(ValueType (^)(NSUInteger idx))addBlock notDequeued:(void (^)(NSUInteger idx, ValueType obj))notDequeuedBlock doNext:(void (^)(NSUInteger idx, ValueType obj))doBlock;

- (void)layerlens_removeObjectsPassingTest:(BOOL (^)(NSUInteger idx, ValueType obj))block;

@end

