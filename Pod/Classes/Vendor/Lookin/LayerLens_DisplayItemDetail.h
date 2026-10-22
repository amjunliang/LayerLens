
//
//  LayerLens_DisplayItemDetail.h
//  Lookin
//
//  Created by Li Kai on 2019/2/19.
//  https://lookin.work
//

#import "LayerLens_Defines.h"

@class LayerLens_AttributesGroup;
@class LayerLens_DisplayItem;

@interface LayerLens_DisplayItemDetail : NSObject <NSSecureCoding>

@property(nonatomic, assign) unsigned long displayItemOid;

@property(nonatomic, strong) LayerLens_Image *groupScreenshot;

@property(nonatomic, strong) LayerLens_Image *soloScreenshot;

@property(nonatomic, strong) NSValue *frameValue;

@property(nonatomic, strong) NSValue *boundsValue;

@property(nonatomic, strong) NSNumber *hiddenValue;

@property(nonatomic, strong) NSNumber *alphaValue;

@property(nonatomic, copy) NSString *customDisplayTitle;

@property(nonatomic, copy) NSString *danceUISource;

@property(nonatomic, copy) NSArray<LayerLens_AttributesGroup *> *attributesGroupList;
@property(nonatomic, copy) NSArray<LayerLens_AttributesGroup *> *customAttrGroupList;

/// 注意 nil 和空数组的区别：nil 表示该属性无意义，空数组表示 subviews 为空
/// Client 1.0.7 & Server 1.2.7 开始支持该属性
/// 默认为 nil
@property(nonatomic, copy) NSArray<LayerLens_DisplayItem *> *subitems;

/// 当 Server 找不到 task 对应的图层时，会返回一个特殊的 LayerLens_DisplayItemDetail 对象，这个对象会被设置 displayItemOid 和 failureCode，其中 failureCode 会被置为 -1
/// Client 1.0.7 & Server 1.2.7 开始支持该属性
/// 默认为 0
@property(nonatomic, assign) NSInteger failureCode;

@end

