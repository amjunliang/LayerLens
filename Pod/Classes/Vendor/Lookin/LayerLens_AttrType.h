
//
//  LayerLens_AttrIdentifiers.h
//  Lookin
//
//  Created by Li Kai on 2018/12/1.
//  https://lookin.work
//

/// 注意：新属性只能加到末尾，否则新旧版本搭配时可能有兼容问题
typedef NS_ENUM(NSInteger, LayerLens_AttrType) {
    LayerLens_AttrTypeNone,
    LayerLens_AttrTypeVoid,
    LayerLens_AttrTypeChar,
    LayerLens_AttrTypeInt,
    LayerLens_AttrTypeShort,
    LayerLens_AttrTypeLong,
    LayerLens_AttrTypeLongLong,
    LayerLens_AttrTypeUnsignedChar,
    LayerLens_AttrTypeUnsignedInt,
    LayerLens_AttrTypeUnsignedShort,
    LayerLens_AttrTypeUnsignedLong,
    LayerLens_AttrTypeUnsignedLongLong,
    LayerLens_AttrTypeFloat,
    LayerLens_AttrTypeDouble,
    LayerLens_AttrTypeBOOL,
    LayerLens_AttrTypeSel,
    LayerLens_AttrTypeClass,
    LayerLens_AttrTypeCGPoint,
    LayerLens_AttrTypeCGVector,
    LayerLens_AttrTypeCGSize,
    LayerLens_AttrTypeCGRect,
    LayerLens_AttrTypeCGAffineTransform,
    LayerLens_AttrTypeUIEdgeInsets,
    LayerLens_AttrTypeUIOffset,
    LayerLens_AttrTypeNSString,
    LayerLens_AttrTypeEnumInt,
    LayerLens_AttrTypeEnumLong,
    /// value 实际为 RGBA 数组，即 @[NSNumber, NSNumber, NSNumber, NSNumber]，NSNumber 范围是 0 ~ 1
    LayerLens_AttrTypeUIColor,
    /// 业务需要根据具体的 AttrIdentifier 来解析
    LayerLens_AttrTypeCustomObj,
    
    LayerLens_AttrTypeEnumString,
    LayerLens_AttrTypeShadow,
    LayerLens_AttrTypeJson
};

