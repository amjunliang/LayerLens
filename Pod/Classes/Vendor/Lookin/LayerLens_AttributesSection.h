
//
//  LayerLens_AttributesSection.h
//  Lookin
//
//  Created by Li Kai on 2019/3/2.
//  https://lookin.work
//



#import <Foundation/Foundation.h>
#import "LayerLens_AttrIdentifiers.h"

@class LayerLens_Attribute;

typedef NS_ENUM (NSInteger, LayerLens_AttributesSectionStyle) {
    LayerLens_AttributesSectionStyleDefault,    // 每个 attr 独占一行
    LayerLens_AttributesSectionStyle0,  // frame 等卡片使用，前 4 个 attr 每行两个，之后每个 attr 在同一排，每个宽度为 1/4
    LayerLens_AttributesSectionStyle1,  // 第一个 attr 在第一排靠左，第二个 attr 在第一排靠右，之后的 attr 每个独占一行
    LayerLens_AttributesSectionStyle2   // 第一排独占一行，剩下的在同一行且均分宽度
};

@interface LayerLens_AttributesSection : NSObject <NSSecureCoding, NSCopying>

@property(nonatomic, copy) LayerLens_AttrSectionIdentifier identifier;

@property(nonatomic, copy) NSArray<LayerLens_Attribute *> *attributes;

- (BOOL)isUserCustom;

@end

