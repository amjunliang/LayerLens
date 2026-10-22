
//
//  NSObject+LayerLens_Server.h
//  LayerLens_Server
//
//  Created by Li Kai on 2019/4/21.
//  https://lookin.work
//

#import "LayerLens_Defines.h"
#import <Foundation/Foundation.h>

@class LayerLens_IvarTrace;

@interface NSObject (LayerLens_Server)

#pragma mark - oid

/// 如果 oid 不存在则会创建新的 oid
- (unsigned long)layerlens_registerOid;

/// 0 表示不存在
@property(nonatomic, assign) unsigned long layerlens_oid;

+ (NSObject *)layerlens_objectWithOid:(unsigned long)oid;

#pragma mark - trace

@property(nonatomic, copy) NSString *layerlens_specialTrace;

+ (void)layerlens_clearAllObjectsTraces;

/**
 获取当前对象的 Class 层级树，如 @[@"UIView", @"UIResponder", @"NSObject"]。未 demangle，有 Swift Module Name
 */
- (NSArray<NSString *> *)layerlens_classChainList;

@end

