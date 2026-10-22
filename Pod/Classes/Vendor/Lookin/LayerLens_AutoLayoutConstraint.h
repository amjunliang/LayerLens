
//
//  LayerLens_AutoLayoutConstraint.h
//  Lookin
//
//  Created by Li Kai on 2019/9/28.
//  https://lookin.work
//



#import "LayerLens_Defines.h"

@class LayerLens_Object;

typedef NS_ENUM(NSInteger, LayerLens_ConstraintItemType) {
    LayerLens_ConstraintItemTypeUnknown,
    LayerLens_ConstraintItemTypeNil,
    LayerLens_ConstraintItemTypeView,
    LayerLens_ConstraintItemTypeSelf,
    LayerLens_ConstraintItemTypeSuper,
    LayerLens_ConstraintItemTypeLayoutGuide
};

@interface LayerLens_AutoLayoutConstraint : NSObject <NSSecureCoding>

#if TARGET_OS_IPHONE
+ (instancetype)instanceFromNSConstraint:(NSLayoutConstraint *)constraint isEffective:(BOOL)isEffective firstItemType:(LayerLens_ConstraintItemType)firstItemType secondItemType:(LayerLens_ConstraintItemType)secondItemType;
#endif

@property(nonatomic, assign) BOOL effective;
@property(nonatomic, assign) BOOL active;
@property(nonatomic, assign) BOOL shouldBeArchived;
@property(nonatomic, strong) LayerLens_Object *firstItem;
@property(nonatomic, assign) LayerLens_ConstraintItemType firstItemType;
/// iOS 里的 NSLayoutAttribute，注意 iOS 和 macOS 虽然都有 NSLayoutAttribute 但是 value 非常不同，因此这里使用 NSInteger 避免混淆
@property(nonatomic, assign) NSInteger firstAttribute;
@property(nonatomic, assign) NSLayoutRelation relation;
@property(nonatomic, strong) LayerLens_Object *secondItem;
@property(nonatomic, assign) LayerLens_ConstraintItemType secondItemType;
/// iOS 里的 NSLayoutAttribute，注意 iOS 和 macOS 虽然都有 NSLayoutAttribute 但是 value 非常不同，因此这里使用 NSInteger 避免混淆
@property(nonatomic, assign) NSInteger secondAttribute;
@property(nonatomic, assign) CGFloat multiplier;
@property(nonatomic, assign) CGFloat constant;
@property(nonatomic, assign) CGFloat priority;
@property(nonatomic, copy) NSString *identifier;

@end

