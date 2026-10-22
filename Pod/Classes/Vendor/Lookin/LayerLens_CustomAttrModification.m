//
//  LayerLens_CustomAttrModification.m
//  LayerLens_Shared
//
//  Created by likaimacbookhome on 2023/11/4.
//

#import "LayerLens_CustomAttrModification.h"

@implementation LayerLens_CustomAttrModification

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeInteger:self.attrType forKey:@"attrType"];
    [aCoder encodeObject:self.value forKey:@"value"];
    [aCoder encodeObject:self.customSetterID forKey:@"customSetterID"];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super init]) {
        self.attrType = [aDecoder decodeIntegerForKey:@"attrType"];
        self.value = [aDecoder decodeObjectForKey:@"value"];
        self.customSetterID = [aDecoder decodeObjectForKey:@"customSetterID"];
    }
    return self;
}

+ (BOOL)supportsSecureCoding {
    return YES;
}

@end

