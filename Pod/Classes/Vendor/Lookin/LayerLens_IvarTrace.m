
//
//  LayerLens_IvarTrace.m
//  Lookin
//
//  Created by Li Kai on 2019/4/30.
//  https://lookin.work
//

#import "LayerLens_IvarTrace.h"

NSString *const LayerLens_IvarTraceRelationValue_Self = @"self";

@implementation LayerLens_IvarTrace

#pragma mark - Equal

- (NSUInteger)hash {
    return self.hostClassName.hash ^ self.ivarName.hash;
}

- (BOOL)isEqual:(id)object {
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[LayerLens_IvarTrace class]]) {
        return NO;
    }
    LayerLens_IvarTrace *comparedObj = object;
    if ([self.hostClassName isEqualToString:comparedObj.hostClassName] && [self.ivarName isEqualToString:comparedObj.ivarName]) {
        return YES;
    }
    return NO;
}

#pragma mark - <NSCopying>
    
- (id)copyWithZone:(NSZone *)zone {
    LayerLens_IvarTrace *newTrace = [[LayerLens_IvarTrace allocWithZone:zone] init];
    newTrace.relation = self.relation;
    newTrace.hostClassName = self.hostClassName;
    newTrace.ivarName = self.ivarName;
    return newTrace;
}

#pragma mark - <NSCoding>

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:self.relation forKey:@"relation"];
    [aCoder encodeObject:self.hostClassName forKey:@"hostClassName"];
    [aCoder encodeObject:self.ivarName forKey:@"ivarName"];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super init]) {
        self.relation = [aDecoder decodeObjectForKey:@"relation"];
        self.hostClassName = [aDecoder decodeObjectForKey:@"hostClassName"];
        self.ivarName = [aDecoder decodeObjectForKey:@"ivarName"];
    }
    return self;
}

+ (BOOL)supportsSecureCoding {
    return YES;
}

@end

