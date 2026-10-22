
//
//  NSObject+LayerLens_Server.m
//  LayerLens_Server
//
//  Created by Li Kai on 2019/4/21.
//  https://lookin.work
//

#import "NSObject+LayerLens_Shared.h"
#import "NSObject+LayerLens_Server.h"
#import "LayerLens_ServerDefines.h"
#import "LayerLens_ObjectRegistry.h"
#import <objc/runtime.h>

@implementation NSObject (LayerLens_Server)

#pragma mark - oid

- (unsigned long)layerlens_registerOid {
    if (!self.layerlens_oid) {
        unsigned long oid = [[LayerLens_ObjectRegistry sharedInstance] addObject:self];
        self.layerlens_oid = oid;
    }
    return self.layerlens_oid;
}

- (void)setLayerlens_oid:(unsigned long)layerlens_oid {
    [self layerlens_bindObject:@(layerlens_oid) forKey:@"layerlens_oid"];
}

- (unsigned long)layerlens_oid {
    NSNumber *number = [self layerlens_getBindObjectForKey:@"layerlens_oid"];
    return [number unsignedLongValue];
}

+ (NSObject *)layerlens_objectWithOid:(unsigned long)oid {
    return [[LayerLens_ObjectRegistry sharedInstance] objectWithOid:oid];
}

#pragma mark - trace

- (void)setLayerlens_ivarTraces:(NSArray<LayerLens_IvarTrace *> *)layerlens_ivarTraces {
    [self layerlens_bindObject:layerlens_ivarTraces.copy forKey:@"layerlens_ivarTraces"];
    
    if (layerlens_ivarTraces) {
        [[NSObject layerlens_allObjectsWithTraces] addPointer:(void *)self];
    }
}

- (NSArray<LayerLens_IvarTrace *> *)layerlens_ivarTraces {
    return [self layerlens_getBindObjectForKey:@"layerlens_ivarTraces"];
}

- (void)setLayerlens_specialTrace:(NSString *)layerlens_specialTrace {
    [self layerlens_bindObject:layerlens_specialTrace forKey:@"layerlens_specialTrace"];
    if (layerlens_specialTrace) {
        [[NSObject layerlens_allObjectsWithTraces] addPointer:(void *)self];
    }
}
- (NSString *)layerlens_specialTrace {
    return [self layerlens_getBindObjectForKey:@"layerlens_specialTrace"];
}

+ (void)layerlens_clearAllObjectsTraces {
    [[[NSObject layerlens_allObjectsWithTraces] allObjects] enumerateObjectsUsingBlock:^(NSObject * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        obj.layerlens_ivarTraces = nil;
        obj.layerlens_specialTrace = nil;
    }];
    [NSObject layerlens_allObjectsWithTraces].count = 0;
}

+ (NSPointerArray *)layerlens_allObjectsWithTraces {
    static dispatch_once_t onceToken;
    static NSPointerArray *layerlens_allObjectsWithTraces = nil;
    dispatch_once(&onceToken,^{
        layerlens_allObjectsWithTraces = [NSPointerArray weakObjectsPointerArray];
    });
    return layerlens_allObjectsWithTraces;
}

- (NSArray<NSString *> *)layerlens_classChainList {
    NSMutableArray<NSString *> *classChainList = [NSMutableArray array];
    Class currentClass = self.class;
    
    while (currentClass) {
        NSString *currentClassName = NSStringFromClass(currentClass);
        if (currentClassName) {
            [classChainList addObject:currentClassName];
        }
        currentClass = [currentClass superclass];
    }
    return classChainList.copy;
}

@end

