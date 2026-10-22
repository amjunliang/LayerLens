
//
//  LayerLens_AttributesSection.m
//  Lookin
//
//  Created by Li Kai on 2019/3/2.
//  https://lookin.work
//



#import "LayerLens_AttributesSection.h"
#import "LayerLens_Attribute.h"

#import "NSArray+LayerLens_Shared.h"

@implementation LayerLens_AttributesSection

#pragma mark - <NSCopying>

- (id)copyWithZone:(NSZone *)zone {
    LayerLens_AttributesSection *newSection = [[LayerLens_AttributesSection allocWithZone:zone] init];
    newSection.identifier = self.identifier;
    newSection.attributes = [self.attributes layerlens_map:^id(NSUInteger idx, LayerLens_Attribute *value) {
        return value.copy;
    }];
    return newSection;
}

#pragma mark - <NSCoding>

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:self.identifier forKey:@"identifier"];
    [aCoder encodeObject:self.attributes forKey:@"attributes"];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super init]) {
        self.identifier = [aDecoder decodeObjectForKey:@"identifier"];
        self.attributes = [aDecoder decodeObjectForKey:@"attributes"];
    }
    return self;
}

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (BOOL)isUserCustom {
    return [self.identifier isEqualToString:LayerLens_AttrSec_UserCustom];
}

@end

