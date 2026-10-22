
//
//  LayerLens_AttributesGroup.m
//  Lookin
//
//  Created by Li Kai on 2018/11/19.
//  https://lookin.work
//



#import "LayerLens_AttributesGroup.h"
#import "LayerLens_Attribute.h"
#import "LayerLens_AttributesSection.h"
#import "LayerLens_DashboardBlueprint.h"
#import "NSArray+LayerLens_Shared.h"

@implementation LayerLens_AttributesGroup

#pragma mark - <NSCopying>

- (id)copyWithZone:(NSZone *)zone {
    LayerLens_AttributesGroup *newGroup = [[LayerLens_AttributesGroup allocWithZone:zone] init];
    newGroup.userCustomTitle = self.userCustomTitle;
    newGroup.identifier = self.identifier;
    newGroup.attrSections = [self.attrSections layerlens_map:^id(NSUInteger idx, LayerLens_AttributesSection *value) {
        return value.copy;
    }];
    return newGroup;
}

#pragma mark - <NSCoding>

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:self.userCustomTitle forKey:@"userCustomTitle"];
    [aCoder encodeObject:self.identifier forKey:@"identifier"];
    [aCoder encodeObject:self.attrSections forKey:@"attrSections"];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super init]) {
        self.userCustomTitle = [aDecoder decodeObjectForKey:@"userCustomTitle"];
        self.identifier = [aDecoder decodeObjectForKey:@"identifier"];
        self.attrSections = [aDecoder decodeObjectForKey:@"attrSections"];
    }
    return self;
}

- (NSUInteger)hash {
    return self.uniqueKey.hash;
}

- (BOOL)isEqual:(id)object {
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[LayerLens_AttributesGroup class]]) {
        return NO;
    }
    LayerLens_AttributesGroup *targetObject = object;
    
    if (![self.identifier isEqualToString:targetObject.identifier]) {
        return false;
    }
    if ([self.identifier isEqualToString:LayerLens_AttrGroup_UserCustom]) {
        BOOL ret = [self.userCustomTitle isEqualToString:targetObject.userCustomTitle];
        return ret;
    } else {
        return true;
    }
}

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (NSString *)uniqueKey {
    if ([self.identifier isEqualToString:LayerLens_AttrGroup_UserCustom]) {
        return self.userCustomTitle;
    } else {
        return self.identifier;
    }
}

- (BOOL)isUserCustom {
    return [self.identifier isEqualToString:LayerLens_AttrSec_UserCustom];
}

@end

