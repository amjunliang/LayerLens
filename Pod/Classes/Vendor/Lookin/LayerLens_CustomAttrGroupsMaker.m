//
//  LayerLens_CustomAttrGroupsMaker.m
//  LayerLens_Server
//
//  Created by LikaiMacStudioWork on 2023/10/31.
//

#import "LayerLens_CustomAttrGroupsMaker.h"
#import "LayerLens_AttrGroupsMaker.h"
#import "LayerLens_AttributesGroup.h"
#import "LayerLens_AttributesSection.h"
#import "LayerLens_Attribute.h"
#import "LayerLens_DashboardBlueprint.h"
#import "LayerLens_IvarTrace.h"
#import "UIColor+LayerLens_Server.h"
#import "LayerLens_ServerDefines.h"
#import "LayerLens_CustomAttrSetterManager.h"

@interface LayerLens_CustomAttrGroupsMaker ()

/// key 是 section title
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<LayerLens_Attribute *> *> *sectionAndAttrs;

@property(nonatomic, copy) NSString *resolvedCustomDisplayTitle;
@property(nonatomic, copy) NSString *resolvedDanceUISource;
@property(nonatomic, strong) NSMutableArray *resolvedGroups;

@property(nonatomic, weak) CALayer *layer;

@end

@implementation LayerLens_CustomAttrGroupsMaker

- (instancetype)initWithLayer:(CALayer *)layer {
    if (self = [super init]) {
        self.sectionAndAttrs = [NSMutableDictionary dictionary];
        self.layer = layer;
    }
    return self;
}

- (void)execute {
    if (!self.layer) {
        NSAssert(NO, @"");
        return;
    }
    NSMutableArray<NSString *> *selectors = [NSMutableArray array];
    [selectors addObject:@"layerlens_customDebugInfos"];
    for (int i = 0; i < 5; i++) {
        [selectors addObject:[NSString stringWithFormat:@"layerlens_customDebugInfos_%@", @(i)]];
    }
    
    for (NSString *name in selectors) {
        [self makeAttrsForViewOrLayer:self.layer selectorName:name];
        
        UIView *view = self.layer.layerlens_hostView;
        if (view) {
            [self makeAttrsForViewOrLayer:view selectorName:name];
        }
    }
    
    if ([self.sectionAndAttrs count] == 0) {
        return;
    }
    NSMutableArray<LayerLens_AttributesGroup *> *groups = [NSMutableArray array];
    [self.sectionAndAttrs enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull groupTitle, NSMutableArray<LayerLens_Attribute *> * _Nonnull attrs, BOOL * _Nonnull stop) {
        LayerLens_AttributesGroup *group = [LayerLens_AttributesGroup new];
        group.userCustomTitle = groupTitle;
        group.identifier = LayerLens_AttrGroup_UserCustom;
        
        NSMutableArray<LayerLens_AttributesSection *> *sections = [NSMutableArray array];
        [attrs enumerateObjectsUsingBlock:^(LayerLens_Attribute * _Nonnull attr, NSUInteger idx, BOOL * _Nonnull stop) {
            LayerLens_AttributesSection *sec = [LayerLens_AttributesSection new];
            sec.identifier = LayerLens_AttrSec_UserCustom;
            sec.attributes = @[attr];
            [sections addObject:sec];
        }];
        
        group.attrSections = sections;
        [groups addObject:group];
    }];
    [groups sortedArrayUsingComparator:^NSComparisonResult(LayerLens_AttributesGroup *obj1, LayerLens_AttributesGroup *obj2) {
        return [obj1.userCustomTitle compare:obj2.userCustomTitle];
    }];
    
    self.resolvedGroups = groups;
}

- (void)makeAttrsForViewOrLayer:(id)viewOrLayer selectorName:(NSString *)selectorName {
    if (!viewOrLayer || !selectorName.length) {
        return;
    }
    if (![viewOrLayer isKindOfClass:[UIView class]] && ![viewOrLayer isKindOfClass:[CALayer class]]) {
        return;
    }
    SEL selector = NSSelectorFromString(selectorName);
    if (![viewOrLayer respondsToSelector:selector]) {
        return;
    }
    NSMethodSignature *signature = [viewOrLayer methodSignatureForSelector:selector];
    if (signature.numberOfArguments > 2) {
        NSAssert(NO, @"LayerLens_Server - There should be no explicit parameters.");
        return;
    }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:viewOrLayer];
    [invocation setSelector:selector];
    [invocation invoke];
    
    // 小心这里的内存管理
    NSDictionary<NSString *, id> * __unsafe_unretained tempRawData;
    [invocation getReturnValue:&tempRawData];
    if (!tempRawData || ![tempRawData isKindOfClass:[NSDictionary class]]) {
        return;
    }
    
    NSDictionary<NSString *, id> *rawData = tempRawData;
    NSArray *rawProperties = rawData[@"properties"];
    
    NSString *customTitle = rawData[@"title"];
    if (customTitle && [customTitle isKindOfClass:[NSString class]] && customTitle.length > 0) {
        self.resolvedCustomDisplayTitle = customTitle;
    }
    
    NSString *danceSource = rawData[@"layerlens_source"];
    if (danceSource && [danceSource isKindOfClass:[NSString class]] && danceSource.length > 0) {
        self.resolvedDanceUISource = danceSource;
    }
    
    [self makeAttrsFromRawProperties:rawProperties];
}

- (void)makeAttrsFromRawProperties:(NSArray *)rawProperties {
    if (!rawProperties || ![rawProperties isKindOfClass:[NSArray class]]) {
        return;
    }
    
    for (NSDictionary<NSString *, id> *dict in rawProperties) {
        NSString *groupTitle;
        LayerLens_Attribute *attr = [LayerLens_CustomAttrGroupsMaker attrFromRawDict:dict saveCustomSetter:YES groupTitle:&groupTitle];
        if (!attr) {
            continue;
        }
        if (!self.sectionAndAttrs[groupTitle]) {
            self.sectionAndAttrs[groupTitle] = [NSMutableArray array];
        }
        [self.sectionAndAttrs[groupTitle] addObject:attr];
    }
}

+ (LayerLens_Attribute *)attrFromRawDict:(NSDictionary *)dict saveCustomSetter:(BOOL)saveCustomSetter groupTitle:(inout NSString **)inoutGroupTitle {
    LayerLens_Attribute *attr = [LayerLens_Attribute new];
    attr.identifier = LayerLens_Attr_UserCustom;
    
    NSString *title = dict[@"title"];
    NSString *type = dict[@"valueType"];
    NSString *section = dict[@"section"];
    id value = dict[@"value"];
    
    if (!title || ![title isKindOfClass:[NSString class]]) {
        NSLog(@"LayerLens_Server - Wrong title");
        return nil;
    }
    if (!type || ![type isKindOfClass:[NSString class]]) {
        NSLog(@"LayerLens_Server - Wrong valueType");
        return nil;
    }
    if (!section || ![section isKindOfClass:[NSString class]] || section.length == 0) {
        *inoutGroupTitle = @"Custom";
    } else {
        *inoutGroupTitle = section;
    }
    
    attr.displayTitle = title;
    
    NSString *fixedType = type.lowercaseString;
    if ([fixedType isEqualToString:@"string"]) {
        if (value != nil && ![value isKindOfClass:[NSString class]]) {
            // nil 是合法的
            NSLog(@"LayerLens_Server - Wrong value type.");
            return nil;
        }
        attr.attrType = LayerLens_AttrTypeNSString;
        attr.value = value;
        
        if (saveCustomSetter && dict[@"retainedSetter"]) {
            NSString *uniqueID = [[NSUUID new] UUIDString];
            LayerLens_StringSetter setter = dict[@"retainedSetter"];
            [[LayerLens_CustomAttrSetterManager sharedInstance] saveStringSetter:setter uniqueID:uniqueID];
            attr.customSetterID = uniqueID;
        }
        
        return attr;
    }
    
    if ([fixedType isEqualToString:@"number"]) {
        if (value == nil) {
            NSLog(@"LayerLens_Server - No value.");
            return nil;
        }
        if (![value isKindOfClass:[NSNumber class]]) {
            NSLog(@"LayerLens_Server - Wrong value type.");
            return nil;
        }
        attr.attrType = LayerLens_AttrTypeDouble;
        attr.value = value;
        
        if (saveCustomSetter && dict[@"retainedSetter"]) {
            NSString *uniqueID = [[NSUUID new] UUIDString];
            LayerLens_NumberSetter setter = dict[@"retainedSetter"];
            [[LayerLens_CustomAttrSetterManager sharedInstance] saveNumberSetter:setter uniqueID:uniqueID];
            attr.customSetterID = uniqueID;
        }
        
        return attr;
    }
        
    if ([fixedType isEqualToString:@"bool"]) {
        if (value == nil) {
            NSLog(@"LayerLens_Server - No value.");
            return nil;
        }
        if (![value isKindOfClass:[NSNumber class]]) {
            NSLog(@"LayerLens_Server - Wrong value type.");
            return nil;
        }
        attr.attrType = LayerLens_AttrTypeBOOL;
        attr.value = value;
        
        if (saveCustomSetter && dict[@"retainedSetter"]) {
            NSString *uniqueID = [[NSUUID new] UUIDString];
            LayerLens_BoolSetter setter = dict[@"retainedSetter"];
            [[LayerLens_CustomAttrSetterManager sharedInstance] saveBoolSetter:setter uniqueID:uniqueID];
            attr.customSetterID = uniqueID;
        }
        
        return attr;
    }
    
    if ([fixedType isEqualToString:@"color"]) {
        if (value != nil && ![value isKindOfClass:[UIColor class]]) {
            // nil 是合法的
            NSLog(@"LayerLens_Server - Wrong value type.");
            return nil;
        }
        attr.attrType = LayerLens_AttrTypeUIColor;
        attr.value = [(UIColor *)value layerlens_rgbaComponents];
        
        if (saveCustomSetter && dict[@"retainedSetter"]) {
            NSString *uniqueID = [[NSUUID new] UUIDString];
            LayerLens_ColorSetter setter = dict[@"retainedSetter"];
            [[LayerLens_CustomAttrSetterManager sharedInstance] saveColorSetter:setter uniqueID:uniqueID];
            attr.customSetterID = uniqueID;
        }
        
        return attr;
    }
    
    if ([fixedType isEqualToString:@"rect"]) {
        if (value == nil) {
            NSLog(@"LayerLens_Server - No value.");
            return nil;
        }
        if (![value isKindOfClass:[NSValue class]]) {
            NSLog(@"LayerLens_Server - Wrong value type.");
            return nil;
        }
        attr.attrType = LayerLens_AttrTypeCGRect;
        attr.value = value;
        
        if (saveCustomSetter && dict[@"retainedSetter"]) {
            NSString *uniqueID = [[NSUUID new] UUIDString];
            LayerLens_RectSetter setter = dict[@"retainedSetter"];
            [[LayerLens_CustomAttrSetterManager sharedInstance] saveRectSetter:setter uniqueID:uniqueID];
            attr.customSetterID = uniqueID;
        }
        
        return attr;
    }
    
    if ([fixedType isEqualToString:@"size"]) {
        if (value == nil) {
            NSLog(@"LayerLens_Server - No value.");
            return nil;
        }
        if (![value isKindOfClass:[NSValue class]]) {
            NSLog(@"LayerLens_Server - Wrong value type.");
            return nil;
        }
        attr.attrType = LayerLens_AttrTypeCGSize;
        attr.value = value;
        
        if (saveCustomSetter && dict[@"retainedSetter"]) {
            NSString *uniqueID = [[NSUUID new] UUIDString];
            LayerLens_SizeSetter setter = dict[@"retainedSetter"];
            [[LayerLens_CustomAttrSetterManager sharedInstance] saveSizeSetter:setter uniqueID:uniqueID];
            attr.customSetterID = uniqueID;
        }
        
        return attr;
    }
    
    if ([fixedType isEqualToString:@"point"]) {
        if (value == nil) {
            NSLog(@"LayerLens_Server - No value.");
            return nil;
        }
        if (![value isKindOfClass:[NSValue class]]) {
            NSLog(@"LayerLens_Server - Wrong value type.");
            return nil;
        }
        attr.attrType = LayerLens_AttrTypeCGPoint;
        attr.value = value;
        
        if (saveCustomSetter && dict[@"retainedSetter"]) {
            NSString *uniqueID = [[NSUUID new] UUIDString];
            LayerLens_PointSetter setter = dict[@"retainedSetter"];
            [[LayerLens_CustomAttrSetterManager sharedInstance] savePointSetter:setter uniqueID:uniqueID];
            attr.customSetterID = uniqueID;
        }
        
        return attr;
    }
    
    if ([fixedType isEqualToString:@"insets"]) {
        if (value == nil) {
            NSLog(@"LayerLens_Server - No value.");
            return nil;
        }
        if (![value isKindOfClass:[NSValue class]]) {
            NSLog(@"LayerLens_Server - Wrong value type.");
            return nil;
        }
        attr.attrType = LayerLens_AttrTypeUIEdgeInsets;
        attr.value = value;
        
        if (saveCustomSetter && dict[@"retainedSetter"]) {
            NSString *uniqueID = [[NSUUID new] UUIDString];
            LayerLens_InsetsSetter setter = dict[@"retainedSetter"];
            [[LayerLens_CustomAttrSetterManager sharedInstance] saveInsetsSetter:setter uniqueID:uniqueID];
            attr.customSetterID = uniqueID;
        }
        
        return attr;
    }
    
    if ([fixedType isEqualToString:@"shadow"]) {
        if (value == nil) {
            NSLog(@"LayerLens_Server - No value.");
            return nil;
        }
        if (![value isKindOfClass:[NSDictionary class]]) {
            NSLog(@"LayerLens_Server - Wrong value type.");
            return nil;
        }
        NSDictionary *shadowInfo = value;
        if (![shadowInfo[@"offset"] isKindOfClass:[NSValue class]]) {
            NSLog(@"LayerLens_Server - Wrong value. No offset.");
            return nil;
        }
        if (![shadowInfo[@"opacity"] isKindOfClass:[NSNumber class]]) {
            NSLog(@"LayerLens_Server - Wrong value. No opacity.");
            return nil;
        }
        if (![shadowInfo[@"radius"] isKindOfClass:[NSNumber class]]) {
            NSLog(@"LayerLens_Server - Wrong value. No radius.");
            return nil;
        }
        NSMutableDictionary *checkedShadowInfo = [@{
            @"offset": shadowInfo[@"offset"],
            @"opacity": shadowInfo[@"opacity"],
            @"radius": shadowInfo[@"radius"]
        } mutableCopy];
        if ([shadowInfo[@"color"] isKindOfClass:[UIColor class]]) {
            checkedShadowInfo[@"color"] = [(UIColor *)shadowInfo[@"color"] layerlens_rgbaComponents];
        }
        
        attr.attrType = LayerLens_AttrTypeShadow;
        attr.value = checkedShadowInfo;
        
        return attr;
    }
    
    if ([fixedType isEqualToString:@"enum"]) {
        if (value == nil) {
            NSLog(@"LayerLens_Server - No value.");
            return nil;
        }
        if (![value isKindOfClass:[NSString class]]) {
            NSLog(@"LayerLens_Server - Wrong value type.");
            return nil;
        }
        attr.attrType = LayerLens_AttrTypeEnumString;
        attr.value = value;
        
        NSArray<NSString *> *allEnumCases = dict[@"allEnumCases"];
        if ([allEnumCases isKindOfClass:[NSArray class]]) {
            attr.extraValue = allEnumCases;
        }
        
        if (saveCustomSetter && dict[@"retainedSetter"]) {
            NSString *uniqueID = [[NSUUID new] UUIDString];
            LayerLens_EnumSetter setter = dict[@"retainedSetter"];
            [[LayerLens_CustomAttrSetterManager sharedInstance] saveEnumSetter:setter uniqueID:uniqueID];
            attr.customSetterID = uniqueID;
        }
        
        return attr;
    }
    
    if ([fixedType isEqualToString:@"json"]) {
        if (![value isKindOfClass:[NSString class]]) {
            NSLog(@"LayerLens_Server - Wrong value type.");
            return nil;
        }
        attr.attrType = LayerLens_AttrTypeJson;
        attr.value = value;
        
        return attr;
    }
    
    NSLog(@"LayerLens_Server - Unsupported value type.");
    return nil;
}

- (NSArray<LayerLens_AttributesGroup *> *)getGroups {
    return self.resolvedGroups;
}

- (NSString *)getCustomDisplayTitle {
    return self.resolvedCustomDisplayTitle;
}

- (NSString *)getDanceUISource {
    return self.resolvedDanceUISource;
}

+ (NSArray<LayerLens_AttributesGroup *> *)makeGroupsFromRawProperties:(NSArray *)rawProperties saveCustomSetter:(BOOL)saveCustomSetter {
    if (!rawProperties || ![rawProperties isKindOfClass:[NSArray class]]) {
        return nil;
    }
    // key 是 group title
    NSMutableDictionary<NSString *, NSMutableArray<LayerLens_Attribute *> *> *groupTitleAndAttrs = [NSMutableDictionary dictionary];
    
    for (NSDictionary<NSString *, id> *dict in rawProperties) {
        NSString *groupTitle;
        LayerLens_Attribute *attr = [LayerLens_CustomAttrGroupsMaker attrFromRawDict:dict saveCustomSetter:saveCustomSetter groupTitle:&groupTitle];
        if (!attr) {
            continue;
        }
        if (!groupTitleAndAttrs[groupTitle]) {
            groupTitleAndAttrs[groupTitle] = [NSMutableArray array];
        }
        [groupTitleAndAttrs[groupTitle] addObject:attr];
    }
    
    if ([groupTitleAndAttrs count] == 0) {
        return nil;
    }
    NSMutableArray<LayerLens_AttributesGroup *> *groups = [NSMutableArray array];
    [groupTitleAndAttrs enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull groupTitle, NSMutableArray<LayerLens_Attribute *> * _Nonnull attrs, BOOL * _Nonnull stop) {
        LayerLens_AttributesGroup *group = [LayerLens_AttributesGroup new];
        group.userCustomTitle = groupTitle;
        group.identifier = LayerLens_AttrGroup_UserCustom;
        
        NSMutableArray<LayerLens_AttributesSection *> *sections = [NSMutableArray array];
        [attrs enumerateObjectsUsingBlock:^(LayerLens_Attribute * _Nonnull attr, NSUInteger idx, BOOL * _Nonnull stop) {
            LayerLens_AttributesSection *sec = [LayerLens_AttributesSection new];
            sec.identifier = LayerLens_AttrSec_UserCustom;
            sec.attributes = @[attr];
            [sections addObject:sec];
        }];
        
        group.attrSections = sections;
        [groups addObject:group];
    }];
    [groups sortedArrayUsingComparator:^NSComparisonResult(LayerLens_AttributesGroup *obj1, LayerLens_AttributesGroup *obj2) {
        return [obj1.userCustomTitle compare:obj2.userCustomTitle];
    }];
    return [groups copy];
}

@end

