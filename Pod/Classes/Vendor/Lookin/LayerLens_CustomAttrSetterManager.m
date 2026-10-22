//
//  LayerLens_CustomAttrSetterManager.m
//  LayerLens_Server
//
//  Created by likai.123 on 2023/11/4.
//

#import "LayerLens_CustomAttrSetterManager.h"

@interface LayerLens_CustomAttrSetterManager ()

@property(nonatomic, strong) NSMutableDictionary *settersMap;

@end

@implementation LayerLens_CustomAttrSetterManager

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    static LayerLens_CustomAttrSetterManager *instance = nil;
    dispatch_once(&onceToken,^{
        instance = [[super allocWithZone:NULL] init];
    });
    return instance;
}

+ (id)allocWithZone:(struct _NSZone *)zone {
    return [self sharedInstance];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.settersMap = [NSMutableDictionary new];
    }
    return self;
}

- (void)removeAll {
    [self.settersMap removeAllObjects];
}

- (void)saveStringSetter:(nonnull LayerLens_StringSetter)setter uniqueID:(nonnull NSString *)uniqueID {
    self.settersMap[uniqueID] = setter;
}

- (nullable LayerLens_StringSetter)getStringSetterWithID:(nonnull NSString *)uniqueID {
    return self.settersMap[uniqueID];
}

- (void)saveNumberSetter:(LayerLens_NumberSetter)setter uniqueID:(NSString *)uniqueID {
    self.settersMap[uniqueID] = setter;
}

- (nullable LayerLens_NumberSetter)getNumberSetterWithID:(NSString *)uniqueID {
    return self.settersMap[uniqueID];
}

- (void)saveBoolSetter:(LayerLens_BoolSetter)setter uniqueID:(NSString *)uniqueID {
    self.settersMap[uniqueID] = setter;
}

- (LayerLens_BoolSetter)getBoolSetterWithID:(NSString *)uniqueID {
    return self.settersMap[uniqueID];
}

- (void)saveColorSetter:(LayerLens_ColorSetter)setter uniqueID:(NSString *)uniqueID {
    self.settersMap[uniqueID] = setter;
}

- (LayerLens_ColorSetter)getColorSetterWithID:(NSString *)uniqueID {
    return self.settersMap[uniqueID];
}

- (void)saveEnumSetter:(LayerLens_EnumSetter)setter uniqueID:(NSString *)uniqueID {
    self.settersMap[uniqueID] = setter;
}

- (LayerLens_EnumSetter)getEnumSetterWithID:(NSString *)uniqueID {
    return self.settersMap[uniqueID];
}

- (void)saveRectSetter:(LayerLens_RectSetter)setter uniqueID:(NSString *)uniqueID {
    self.settersMap[uniqueID] = setter;
}

- (LayerLens_RectSetter)getRectSetterWithID:(NSString *)uniqueID {
    return self.settersMap[uniqueID];
}

- (void)saveSizeSetter:(LayerLens_SizeSetter)setter uniqueID:(NSString *)uniqueID {
    self.settersMap[uniqueID] = setter;
}

- (LayerLens_SizeSetter)getSizeSetterWithID:(NSString *)uniqueID {
    return self.settersMap[uniqueID];
}

- (void)savePointSetter:(LayerLens_PointSetter)setter uniqueID:(NSString *)uniqueID {
    self.settersMap[uniqueID] = setter;
}

- (LayerLens_PointSetter)getPointSetterWithID:(NSString *)uniqueID {
    return self.settersMap[uniqueID];
}

- (void)saveInsetsSetter:(LayerLens_InsetsSetter)setter uniqueID:(NSString *)uniqueID {
    self.settersMap[uniqueID] = setter;
}

- (LayerLens_InsetsSetter)getInsetsSetterWithID:(NSString *)uniqueID {
    return self.settersMap[uniqueID];
}

@end
