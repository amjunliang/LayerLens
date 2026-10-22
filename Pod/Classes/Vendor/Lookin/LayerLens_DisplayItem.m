
//
//  LayerLens_DisplayItem.m
//  qmuidemo
//
//  Created by Li Kai on 2018/11/15.
//  Copyright © 2018 QMUI Team. All rights reserved.
//

#import "LayerLens_DisplayItem.h"
#import "LayerLens_AttributesGroup.h"
#import "LayerLens_AttributesSection.h"
#import "LayerLens_Attribute.h"
#import "LayerLens_EventHandler.h"
#import "LayerLens_IvarTrace.h"
#import "Color+LayerLens_Shared.h"
#import "NSArray+LayerLens_Shared.h"
#import "NSObject+LayerLens_Shared.h"
#import "LayerLens_DashboardBlueprint.h"

#if TARGET_OS_IPHONE
#import "UIColor+LayerLens_Server.h"
#import "UIImage+LayerLens_Server.h"
#elif TARGET_OS_MAC
#endif

@interface LayerLens_DisplayItem ()

@property(nonatomic, assign, readwrite) CGRect frameToRoot;
@property(nonatomic, assign, readwrite) BOOL inNoPreviewHierarchy;
@property(nonatomic, assign) NSInteger indentLevel;
@property(nonatomic, assign, readwrite) BOOL isExpandable;
@property(nonatomic, assign, readwrite) BOOL inHiddenHierarchy;
@property(nonatomic, assign, readwrite) BOOL displayingInHierarchy;

@end

@implementation LayerLens_DisplayItem

#pragma mark - <NSCopying>

- (id)copyWithZone:(NSZone *)zone {
    LayerLens_DisplayItem *newDisplayItem = [[LayerLens_DisplayItem allocWithZone:zone] init];
    newDisplayItem.subitems = [self.subitems layerlens_map:^id(NSUInteger idx, LayerLens_DisplayItem *value) {
        return value.copy;
    }];
    newDisplayItem.customInfo = self.customInfo.copy;
    newDisplayItem.isHidden = self.isHidden;
    newDisplayItem.alpha = self.alpha;
    newDisplayItem.frame = self.frame;
    newDisplayItem.bounds = self.bounds;
    newDisplayItem.soloScreenshot = self.soloScreenshot;
    newDisplayItem.groupScreenshot = self.groupScreenshot;
    newDisplayItem.viewObject = self.viewObject.copy;
    newDisplayItem.layerObject = self.layerObject.copy;
    newDisplayItem.hostViewControllerObject = self.hostViewControllerObject.copy;
    newDisplayItem.attributesGroupList = [self.attributesGroupList layerlens_map:^id(NSUInteger idx, LayerLens_AttributesGroup *value) {
        return value.copy;
    }];
    newDisplayItem.customAttrGroupList = [self.customAttrGroupList layerlens_map:^id(NSUInteger idx, LayerLens_AttributesGroup *value) {
        return value.copy;
    }];
    newDisplayItem.eventHandlers = [self.eventHandlers layerlens_map:^id(NSUInteger idx, LayerLens_EventHandler *value) {
        return value.copy;
    }];
    newDisplayItem.shouldCaptureImage = self.shouldCaptureImage;
    newDisplayItem.representedAsKeyWindow = self.representedAsKeyWindow;
    newDisplayItem.customDisplayTitle = self.customDisplayTitle;
    newDisplayItem.danceuiSource = self.danceuiSource;
    [newDisplayItem _updateDisplayingInHierarchyProperty];
    return newDisplayItem;
}
#pragma mark - <NSCoding>

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:self.customInfo forKey:@"customInfo"];
    [aCoder encodeObject:self.subitems forKey:@"subitems"];
    [aCoder encodeBool:self.isHidden forKey:@"hidden"];
    [aCoder encodeFloat:self.alpha forKey:@"alpha"];
    [aCoder encodeObject:self.viewObject forKey:@"viewObject"];
    [aCoder encodeObject:self.layerObject forKey:@"layerObject"];
    [aCoder encodeObject:self.hostViewControllerObject forKey:@"hostViewControllerObject"];
    [aCoder encodeObject:self.attributesGroupList forKey:@"attributesGroupList"];
    [aCoder encodeObject:self.customAttrGroupList forKey:@"customAttrGroupList"];
    [aCoder encodeBool:self.representedAsKeyWindow forKey:@"representedAsKeyWindow"];
    [aCoder encodeObject:self.eventHandlers forKey:@"eventHandlers"];
    [aCoder encodeBool:self.shouldCaptureImage forKey:@"shouldCaptureImage"];
    if (self.screenshotEncodeType == LayerLens_DisplayItemImageEncodeTypeNSData) {
        [aCoder encodeObject:[self.soloScreenshot layerlens_encodedObjectWithType:LayerLens_CodingValueTypeImage] forKey:@"soloScreenshot"];
        [aCoder encodeObject:[self.groupScreenshot layerlens_encodedObjectWithType:LayerLens_CodingValueTypeImage] forKey:@"groupScreenshot"];
    } else if (self.screenshotEncodeType == LayerLens_DisplayItemImageEncodeTypeImage) {
        [aCoder encodeObject:self.soloScreenshot forKey:@"soloScreenshot"];
        [aCoder encodeObject:self.groupScreenshot forKey:@"groupScreenshot"];
    }
    [aCoder encodeObject:self.customDisplayTitle forKey:@"customDisplayTitle"];
    [aCoder encodeObject:self.danceuiSource forKey:@"danceuiSource"];
#if TARGET_OS_IPHONE
    [aCoder encodeCGRect:self.frame forKey:@"frame"];
    [aCoder encodeCGRect:self.bounds forKey:@"bounds"];
    [aCoder encodeObject:self.backgroundColor.layerlens_rgbaComponents forKey:@"backgroundColor"];
    
#elif TARGET_OS_MAC
    [aCoder encodeRect:self.frame forKey:@"frame"];
    [aCoder encodeRect:self.bounds forKey:@"bounds"];
    [aCoder encodeObject:self.backgroundColor.layerlens_rgbaComponents forKey:@"backgroundColor"];
#endif
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super init]) {
        self.customInfo = [aDecoder decodeObjectForKey:@"customInfo"];
        self.subitems = [aDecoder decodeObjectForKey:@"subitems"];
        self.isHidden = [aDecoder decodeBoolForKey:@"hidden"];
        self.alpha = [aDecoder decodeFloatForKey:@"alpha"];
        self.viewObject = [aDecoder decodeObjectForKey:@"viewObject"];
        self.layerObject = [aDecoder decodeObjectForKey:@"layerObject"];
        self.hostViewControllerObject = [aDecoder decodeObjectForKey:@"hostViewControllerObject"];
        self.attributesGroupList = [aDecoder decodeObjectForKey:@"attributesGroupList"];
        self.customAttrGroupList = [aDecoder decodeObjectForKey:@"customAttrGroupList"];
        self.representedAsKeyWindow = [aDecoder decodeBoolForKey:@"representedAsKeyWindow"];
        
        id soloScreenshotObj = [aDecoder decodeObjectForKey:@"soloScreenshot"];
        if (soloScreenshotObj) {
            if ([soloScreenshotObj isKindOfClass:[NSData class]]) {
                self.soloScreenshot = [soloScreenshotObj layerlens_decodedObjectWithType:LayerLens_CodingValueTypeImage];
            } else if ([soloScreenshotObj isKindOfClass:[LayerLens_Image class]]) {
                self.soloScreenshot = soloScreenshotObj;
            } else {
                NSAssert(NO, @"");
            }
        }
        
        id groupScreenshotObj = [aDecoder decodeObjectForKey:@"groupScreenshot"];
        if (groupScreenshotObj) {
            if ([groupScreenshotObj isKindOfClass:[NSData class]]) {
                self.groupScreenshot = [groupScreenshotObj layerlens_decodedObjectWithType:LayerLens_CodingValueTypeImage];
            } else if ([groupScreenshotObj isKindOfClass:[LayerLens_Image class]]) {
                self.groupScreenshot = groupScreenshotObj;
            } else {
                NSAssert(NO, @"");
            }            
        }
        
        self.eventHandlers = [aDecoder decodeObjectForKey:@"eventHandlers"];
        /// this property was added in LayerLens_Server 1.1.3
        self.shouldCaptureImage = [aDecoder containsValueForKey:@"shouldCaptureImage"] ? [aDecoder decodeBoolForKey:@"shouldCaptureImage"] : YES;
        self.customDisplayTitle = [aDecoder decodeObjectForKey:@"customDisplayTitle"];
        self.danceuiSource = [aDecoder decodeObjectForKey:@"danceuiSource"];
#if TARGET_OS_IPHONE
        self.frame = [aDecoder decodeCGRectForKey:@"frame"];
        self.bounds = [aDecoder decodeCGRectForKey:@"bounds"];
        self.backgroundColor = [UIColor layerlens_colorFromRGBAComponents:[aDecoder decodeObjectForKey:@"backgroundColor"]];
#elif TARGET_OS_MAC
        self.frame = [aDecoder decodeRectForKey:@"frame"];
        self.bounds = [aDecoder decodeRectForKey:@"bounds"];
        self.backgroundColor = [NSColor layerlens_colorFromRGBAComponents:[aDecoder decodeObjectForKey:@"backgroundColor"]];
        
#endif
        [self _updateDisplayingInHierarchyProperty];
    }
    return self;
}

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)init {
    if (self = [super init]) {
        /// 在手机端，displayItem 被创建时会调用这个方法
        [self _updateDisplayingInHierarchyProperty];
    }
    return self;
}

- (LayerLens_Object *)displayingObject {
    return self.viewObject ? : self.layerObject;
}

- (void)setAttributesGroupList:(NSArray<LayerLens_AttributesGroup *> *)attributesGroupList {
    _attributesGroupList = attributesGroupList;
    
    [_attributesGroupList enumerateObjectsUsingBlock:^(LayerLens_AttributesGroup * _Nonnull group, NSUInteger idx, BOOL * _Nonnull stop) {
        [group.attrSections enumerateObjectsUsingBlock:^(LayerLens_AttributesSection * _Nonnull section, NSUInteger idx, BOOL * _Nonnull stop) {
            [section.attributes enumerateObjectsUsingBlock:^(LayerLens_Attribute * _Nonnull attr, NSUInteger idx, BOOL * _Nonnull stop) {
                attr.targetDisplayItem = self;
            }];
        }];
    }];
}

- (void)setCustomAttrGroupList:(NSArray<LayerLens_AttributesGroup *> *)customAttrGroupList {
    _customAttrGroupList = customAttrGroupList;
    // 传进来的时候就已经排好序了
    [customAttrGroupList enumerateObjectsUsingBlock:^(LayerLens_AttributesGroup * _Nonnull group, NSUInteger idx, BOOL * _Nonnull stop) {
        [group.attrSections enumerateObjectsUsingBlock:^(LayerLens_AttributesSection * _Nonnull section, NSUInteger idx, BOOL * _Nonnull stop) {
            [section.attributes enumerateObjectsUsingBlock:^(LayerLens_Attribute * _Nonnull attr, NSUInteger idx, BOOL * _Nonnull stop) {
                attr.targetDisplayItem = self;
            }];
        }];
    }];
}

- (void)setSubitems:(NSArray<LayerLens_DisplayItem *> *)subitems {
    [_subitems enumerateObjectsUsingBlock:^(LayerLens_DisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        obj.superItem = nil;
    }];
    
    _subitems = subitems;
    
    self.isExpandable = (subitems.count > 0);
    
    [subitems enumerateObjectsUsingBlock:^(LayerLens_DisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        NSAssert(!obj.superItem, @"");
        obj.superItem = self;
        
        [obj _updateInHiddenHierarchyProperty];
        [obj _updateDisplayingInHierarchyProperty];
    }];
}

- (void)setIsExpandable:(BOOL)isExpandable {
    if (_isExpandable == isExpandable) {
        return;
    }
    _isExpandable = isExpandable;
    [self _notifyDelegatesWith:LayerLens_DisplayItemProperty_IsExpandable];
}

- (void)setIsExpanded:(BOOL)isExpanded {
    if (_isExpanded == isExpanded) {
        return;
    }
    _isExpanded = isExpanded;
    [self.subitems enumerateObjectsUsingBlock:^(LayerLens_DisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [obj _updateDisplayingInHierarchyProperty];
    }];
    [self _notifyDelegatesWith:LayerLens_DisplayItemProperty_IsExpanded];
}

- (void)setSoloScreenshot:(LayerLens_Image *)soloScreenshot {
    if (_soloScreenshot == soloScreenshot) {
        return;
    }
    _soloScreenshot = soloScreenshot;
    [self _notifyDelegatesWith:LayerLens_DisplayItemProperty_SoloScreenshot];
}

- (void)notifySelectionChangeToDelegates {
    [self _notifyDelegatesWith:LayerLens_DisplayItemProperty_IsSelected];
}

- (void)notifyHoverChangeToDelegates {
    [self _notifyDelegatesWith:LayerLens_DisplayItemProperty_IsHovered];
}

- (void)setDoNotFetchScreenshotReason:(LayerLens_DoNotFetchScreenshotReason)doNotFetchScreenshotReason {
    if (_doNotFetchScreenshotReason == doNotFetchScreenshotReason) {
        return;
    }
    _doNotFetchScreenshotReason = doNotFetchScreenshotReason;
    [self _notifyDelegatesWith:LayerLens_DisplayItemProperty_AvoidSyncScreenshot];
}

- (void)setGroupScreenshot:(LayerLens_Image *)groupScreenshot {
    if (_groupScreenshot == groupScreenshot) {
        return;
    }
    _groupScreenshot = groupScreenshot;
    [self _notifyDelegatesWith:LayerLens_DisplayItemProperty_GroupScreenshot];
}

- (void)setDisplayingInHierarchy:(BOOL)displayingInHierarchy {
    if (_displayingInHierarchy == displayingInHierarchy) {
        return;
    }
    _displayingInHierarchy = displayingInHierarchy;
    [self.subitems enumerateObjectsUsingBlock:^(LayerLens_DisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [obj _updateDisplayingInHierarchyProperty];
    }];
    
    [self _notifyDelegatesWith:LayerLens_DisplayItemProperty_DisplayingInHierarchy];
}

- (void)_updateDisplayingInHierarchyProperty {
    if (self.superItem && (!self.superItem.displayingInHierarchy || !self.superItem.isExpanded)) {
        self.displayingInHierarchy = NO;
    } else {
        self.displayingInHierarchy = YES;
    }
}

- (void)setIsHidden:(BOOL)isHidden {
    _isHidden = isHidden;
    [self _updateInHiddenHierarchyProperty];
}

- (void)setAlpha:(float)alpha {
    _alpha = alpha;
    [self _updateInHiddenHierarchyProperty];
}

- (void)setInHiddenHierarchy:(BOOL)inHiddenHierarchy {
    if (_inHiddenHierarchy == inHiddenHierarchy) {
        return;
    }
    _inHiddenHierarchy = inHiddenHierarchy;
    [self.subitems enumerateObjectsUsingBlock:^(LayerLens_DisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [obj _updateInHiddenHierarchyProperty];
    }];
    
    [self _notifyDelegatesWith:LayerLens_DisplayItemProperty_InHiddenHierarchy];
}

- (void)_updateInHiddenHierarchyProperty {
    if (self.superItem.inHiddenHierarchy || self.isHidden || self.alpha <= 0) {
        self.inHiddenHierarchy = YES;
    } else {
        self.inHiddenHierarchy = NO;
    }
}

+ (NSArray<LayerLens_DisplayItem *> *)flatItemsFromHierarchicalItems:(NSArray<LayerLens_DisplayItem *> *)items {
    NSMutableArray *resultArray = [NSMutableArray array];
    
    [items enumerateObjectsUsingBlock:^(LayerLens_DisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if (obj.superItem) {
            obj.indentLevel = obj.superItem.indentLevel + 1;
        }
        [resultArray addObject:obj];
        if (obj.subitems.count) {
            [resultArray addObjectsFromArray:[self flatItemsFromHierarchicalItems:obj.subitems]];
        }
    }];
    
    return resultArray;
}

- (NSString *)description {
    if (self.viewObject) {
        return self.viewObject.rawClassName;
    } else if (self.layerObject) {
        return self.layerObject.rawClassName;
    } else {
        return [super description];
    }
}

- (void)setPreviewItemDelegate:(id<LayerLens_DisplayItemDelegate>)previewItemDelegate {
    _previewItemDelegate = previewItemDelegate;
    
    if (![previewItemDelegate respondsToSelector:@selector(displayItem:propertyDidChange:)]) {
        NSAssert(NO, @"");
        _previewItemDelegate = nil;
        return;
    }
    [self.previewItemDelegate displayItem:self propertyDidChange:LayerLens_DisplayItemProperty_None];
}

- (void)setRowViewDelegate:(id<LayerLens_DisplayItemDelegate>)rowViewDelegate {
    if (_rowViewDelegate == rowViewDelegate) {
        return;
    }
    _rowViewDelegate = rowViewDelegate;
    
    if (![rowViewDelegate respondsToSelector:@selector(displayItem:propertyDidChange:)]) {
        NSAssert(NO, @"");
        _rowViewDelegate = nil;
        return;
    }
    [self.rowViewDelegate displayItem:self propertyDidChange:LayerLens_DisplayItemProperty_None];
}

- (void)setFrame:(CGRect)frame {
    _frame = frame;
    [self recursivelyNotifyFrameToRootMayChange];
}

- (void)recursivelyNotifyFrameToRootMayChange {
    [self _notifyDelegatesWith:LayerLens_DisplayItemProperty_FrameToRoot];

    [self.subitems enumerateObjectsUsingBlock:^(LayerLens_DisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [obj recursivelyNotifyFrameToRootMayChange];
    }];
}

- (void)setBounds:(CGRect)bounds {
    _bounds = bounds;
    [self recursivelyNotifyFrameToRootMayChange];
}

- (void)setInNoPreviewHierarchy:(BOOL)inNoPreviewHierarchy {
    if (_inNoPreviewHierarchy == inNoPreviewHierarchy) {
        return;
    }
    _inNoPreviewHierarchy = inNoPreviewHierarchy;
    [self.subitems enumerateObjectsUsingBlock:^(LayerLens_DisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [obj _updateInNoPreviewHierarchy];
    }];
    [self _notifyDelegatesWith:LayerLens_DisplayItemProperty_InNoPreviewHierarchy];
}

- (void)setNoPreview:(BOOL)noPreview {
    _noPreview = noPreview;
    [self _updateInNoPreviewHierarchy];
}

- (void)_updateInNoPreviewHierarchy {
    if (self.superItem.inNoPreviewHierarchy || self.noPreview) {
        self.inNoPreviewHierarchy = YES;
    } else {
        self.inNoPreviewHierarchy = NO;
    }
}

- (void)_notifyDelegatesWith:(LayerLens_DisplayItemProperty)property {
    [self.previewItemDelegate displayItem:self propertyDidChange:property];
    [self.rowViewDelegate displayItem:self propertyDidChange:property];
}

- (void)setIsInSearch:(BOOL)isInSearch {
    _isInSearch = isInSearch;
    [self _notifyDelegatesWith:LayerLens_DisplayItemProperty_IsInSearch];
}

- (void)setHighlightedSearchString:(NSString *)highlightedSearchString {
    _highlightedSearchString = highlightedSearchString;
    [self _notifyDelegatesWith:LayerLens_DisplayItemProperty_HighlightedSearchString];
}

- (NSArray<LayerLens_AttributesGroup *> *)queryAllAttrGroupList {
    NSMutableArray *array = [NSMutableArray array];
    if (self.attributesGroupList) {
        [array addObjectsFromArray:self.attributesGroupList];
    }
    if (self.customAttrGroupList) {
        [array addObjectsFromArray:self.customAttrGroupList];
    }
    return array;
}

//- (void)dealloc
//{
//    NSLog(@"moss dealloc -%@", self);
//}

@end

