
//
//  LayerLens_Tuples.m
//  Lookin
//
//  Created by Li Kai on 2019/8/14.
//  https://lookin.work
//



#import "LayerLens_Tuple.h"

@implementation LayerLens_TwoTuple

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:self.first forKey:@"first"];
    [aCoder encodeObject:self.second forKey:@"second"];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super init]) {
        self.first = [aDecoder decodeObjectForKey:@"first"];
        self.second = [aDecoder decodeObjectForKey:@"second"];
    }
    return self;
}

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (NSUInteger)hash {
    return self.first.hash ^ self.second.hash;
}

- (BOOL)isEqual:(id)object {
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[LayerLens_TwoTuple class]]) {
        return NO;
    }
    LayerLens_TwoTuple *comparedObj = object;
    if ([self.first isEqual:comparedObj.first] && [self.second isEqual:comparedObj.second]) {
        return YES;
    }
    return NO;
}

@end

@implementation LayerLens_StringTwoTuple

+ (instancetype)tupleWithFirst:(NSString *)firstString second:(NSString *)secondString {
    LayerLens_StringTwoTuple *tuple = [LayerLens_StringTwoTuple new];
    tuple.first = firstString;
    tuple.second = secondString;
    return tuple;
}

#pragma mark - <NSCopying>

- (id)copyWithZone:(NSZone *)zone {
    LayerLens_StringTwoTuple *newTuple = [[LayerLens_StringTwoTuple allocWithZone:zone] init];
    newTuple.first = self.first;
    newTuple.second = self.second;
    return newTuple;
}

#pragma mark - <NSCoding>

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:self.first forKey:@"first"];
    [aCoder encodeObject:self.second forKey:@"second"];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super init]) {
        self.first = [aDecoder decodeObjectForKey:@"first"];
        self.second = [aDecoder decodeObjectForKey:@"second"];
    }
    return self;
}

+ (BOOL)supportsSecureCoding {
    return YES;
}

@end

