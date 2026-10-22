
//
//  LayerLens_AttributesGroup.h
//  Lookin
//
//  Created by Li Kai on 2018/11/19.
//  https://lookin.work
//



#import <Foundation/Foundation.h>
#import "LayerLens_AttrIdentifiers.h"

@class LayerLens_AttributesSection;

/**
 In Lookin, a LayerLens_AttributesGroup instance will be rendered as a property card.
 
 When isUserCustom is false: two LayerLens_AttributesGroup instances will be regard as equal when they has the same LayerLens_AttrGroupIdentifier.
 When isUserCustom is true: two LayerLens_AttributesGroup instances will be regard as equal when they has the same title.
 当 isUserCustom 为 false 时：若两个 attrGroup 有相同的 LayerLens_AttrGroupIdentifier，则 isEqual: 返回 YES
 */
@interface LayerLens_AttributesGroup : NSObject <NSSecureCoding, NSCopying>

/// 只有在 identifier 为 custom 时，才存在该值
@property(nonatomic, copy) NSString *userCustomTitle;

@property(nonatomic, copy) LayerLens_AttrGroupIdentifier identifier;

@property(nonatomic, copy) NSArray<LayerLens_AttributesSection *> *attrSections;

/// 如果是 custom 则返回 userCustomTitle，如果不是 custom 则返回 identifier
- (NSString *)uniqueKey;

- (BOOL)isUserCustom;

@end

