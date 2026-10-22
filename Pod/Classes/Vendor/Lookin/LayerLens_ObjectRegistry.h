
//
//  LayerLens_ObjectRegistry.h
//  LayerLens_Server
//
//  Created by Li Kai on 2019/4/21.
//  https://lookin.work
//

#import <Foundation/Foundation.h>

@interface LayerLens_ObjectRegistry : NSObject

+ (instancetype)sharedInstance;

- (unsigned long)addObject:(NSObject *)object;

- (NSObject *)objectWithOid:(unsigned long)oid;

@end

