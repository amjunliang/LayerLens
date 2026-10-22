
//
//  LayerLens_Object.m
//  Lookin
//
//  Created by Li Kai on 2019/4/20.
//  https://lookin.work
//

#import "LayerLens_Object.h"
#import "LayerLens_IvarTrace.h"
#import "NSArray+LayerLens_Shared.h"
#import "NSString+LayerLens_Shared.h"

#if TARGET_OS_IPHONE
#import "NSObject+LayerLens_Server.h"
#endif

@implementation LayerLens_Object

#if TARGET_OS_IPHONE
+ (instancetype)instanceWithObject:(NSObject *)object {
    LayerLens_Object *lookinObj = [LayerLens_Object new];
    lookinObj.oid = [object layerlens_registerOid];
    
    lookinObj.memoryAddress = [NSString stringWithFormat:@"%p", object];
    lookinObj.classChainList = [object layerlens_classChainList];
    
    lookinObj.specialTrace = object.layerlens_specialTrace;
    lookinObj.ivarTraces = object.layerlens_ivarTraces;
    
    return lookinObj;
}
#endif

#pragma mark - <NSCopying>

- (id)copyWithZone:(NSZone *)zone {
    LayerLens_Object *newObject = [[LayerLens_Object allocWithZone:zone] init];
    newObject.oid = self.oid;
    newObject.memoryAddress = self.memoryAddress;
    newObject.classChainList = self.classChainList;
    newObject.specialTrace = self.specialTrace;
    newObject.ivarTraces = [self.ivarTraces layerlens_map:^id(NSUInteger idx, LayerLens_IvarTrace *value) {
        return value.copy;
    }];
    return newObject;
}

#pragma mark - <NSSecureCoding>

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:@(self.oid) forKey:@"oid"];
    [aCoder encodeObject:self.memoryAddress forKey:@"memoryAddress"];
    [aCoder encodeObject:self.classChainList forKey:@"classChainList"];
    [aCoder encodeObject:self.specialTrace forKey:@"specialTrace"];
    [aCoder encodeObject:self.ivarTraces forKey:@"ivarTraces"];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super init]) {
        self.oid = [(NSNumber *)[aDecoder decodeObjectForKey:@"oid"] unsignedLongValue];
        self.memoryAddress = [aDecoder decodeObjectForKey:@"memoryAddress"];
        self.classChainList = [aDecoder decodeObjectForKey:@"classChainList"];
        self.specialTrace = [aDecoder decodeObjectForKey:@"specialTrace"];
        self.ivarTraces = [aDecoder decodeObjectForKey:@"ivarTraces"];
    }
    return self;
}

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (NSString *)rawClassName {
    return self.classChainList.firstObject;
}

@end

