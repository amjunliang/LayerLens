//
//  LayerLens_CustomAttrSetterManager.h
//  LayerLens_Server
//
//  Created by likai.123 on 2023/11/4.
//

#import <UIKit/UIKit.h>

typedef void(^LayerLens_StringSetter)(NSString *);
typedef void(^LayerLens_NumberSetter)(NSNumber *);
typedef void(^LayerLens_BoolSetter)(BOOL);
typedef void(^LayerLens_ColorSetter)(UIColor *);
typedef void(^LayerLens_EnumSetter)(NSString *);
typedef void(^LayerLens_RectSetter)(CGRect);
typedef void(^LayerLens_SizeSetter)(CGSize);
typedef void(^LayerLens_PointSetter)(CGPoint);
typedef void(^LayerLens_InsetsSetter)(UIEdgeInsets);

@interface LayerLens_CustomAttrSetterManager : NSObject

+ (instancetype)sharedInstance;

- (void)removeAll;

- (void)saveStringSetter:(LayerLens_StringSetter)setter uniqueID:(NSString *)uniqueID;
- (LayerLens_StringSetter)getStringSetterWithID:(NSString *)uniqueID;

- (void)saveNumberSetter:(LayerLens_NumberSetter)setter uniqueID:(NSString *)uniqueID;
- (LayerLens_NumberSetter)getNumberSetterWithID:(NSString *)uniqueID;

- (void)saveBoolSetter:(LayerLens_BoolSetter)setter uniqueID:(NSString *)uniqueID;
- (LayerLens_BoolSetter)getBoolSetterWithID:(NSString *)uniqueID;

- (void)saveColorSetter:(LayerLens_ColorSetter)setter uniqueID:(NSString *)uniqueID;
- (LayerLens_ColorSetter)getColorSetterWithID:(NSString *)uniqueID;

- (void)saveEnumSetter:(LayerLens_EnumSetter)setter uniqueID:(NSString *)uniqueID;
- (LayerLens_EnumSetter)getEnumSetterWithID:(NSString *)uniqueID;

- (void)saveRectSetter:(LayerLens_RectSetter)setter uniqueID:(NSString *)uniqueID;
- (LayerLens_RectSetter)getRectSetterWithID:(NSString *)uniqueID;

- (void)saveSizeSetter:(LayerLens_SizeSetter)setter uniqueID:(NSString *)uniqueID;
- (LayerLens_SizeSetter)getSizeSetterWithID:(NSString *)uniqueID;

- (void)savePointSetter:(LayerLens_PointSetter)setter uniqueID:(NSString *)uniqueID;
- (LayerLens_PointSetter)getPointSetterWithID:(NSString *)uniqueID;

- (void)saveInsetsSetter:(LayerLens_InsetsSetter)setter uniqueID:(NSString *)uniqueID;
- (LayerLens_InsetsSetter)getInsetsSetterWithID:(NSString *)uniqueID;

@end

