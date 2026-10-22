
//
//  LayerLens_HierarchyDisplayItemsMaker.m
//  LayerLens_Server
//
//  Created by Li Kai on 2019/2/19.
//  https://lookin.work
//

#import "LayerLens_HierarchyDisplayItemsMaker.h"
#import "LayerLens_DisplayItem.h"
#import "LayerLens_TraceManager.h"
#import "LayerLens_AttrGroupsMaker.h"
#import "LayerLens_EventHandlerMaker.h"
#import "LayerLens_ServerDefines.h"
#import "UIColor+LayerLens_Server.h"
#import "LayerLens_ConfigManager.h"
#import "LayerLens_CustomAttrGroupsMaker.h"
#import "LayerLens_CustomDisplayItemsMaker.h"
#import "LayerLens_CustomAttrSetterManager.h"
#import "LayerLens_MultiplatformAdapter.h"

@implementation LayerLens_HierarchyDisplayItemsMaker

+ (NSArray<LayerLens_DisplayItem *> *)itemsWithScreenshots:(BOOL)hasScreenshots attrList:(BOOL)hasAttrList lowImageQuality:(BOOL)lowQuality readCustomInfo:(BOOL)readCustomInfo saveCustomSetter:(BOOL)saveCustomSetter {
    
    [[LayerLens_TraceManager sharedInstance] reload];
    
    NSArray<UIWindow *> *windows = [LayerLens_MultiplatformAdapter allWindows];
    NSMutableArray *resultArray = [NSMutableArray arrayWithCapacity:windows.count];
    [windows enumerateObjectsUsingBlock:^(__kindof UIWindow * _Nonnull window, NSUInteger idx, BOOL * _Nonnull stop) {
        LayerLens_DisplayItem *item = [self _displayItemWithLayer:window.layer screenshots:hasScreenshots attrList:hasAttrList lowImageQuality:lowQuality readCustomInfo:readCustomInfo saveCustomSetter:saveCustomSetter];
        item.representedAsKeyWindow = window.isKeyWindow;
        if (item) {
            [resultArray addObject:item];
        }
    }];
    
    return [resultArray copy];
}

+ (LayerLens_DisplayItem *)_displayItemWithLayer:(CALayer *)layer screenshots:(BOOL)hasScreenshots attrList:(BOOL)hasAttrList lowImageQuality:(BOOL)lowQuality readCustomInfo:(BOOL)readCustomInfo saveCustomSetter:(BOOL)saveCustomSetter {
    if (!layer) {
        return nil;
    }
    
    LayerLens_DisplayItem *item = [LayerLens_DisplayItem new];
    CGRect layerFrame = layer.frame;
    UIView *hostView = layer.layerlens_hostView;
    if (hostView && hostView.superview) {
        layerFrame = [hostView.superview convertRect:layerFrame toView:nil];
    }
    if ([self validateFrame:layerFrame]) {
        item.frame = layer.frame;
    } else {
        NSLog(@"LayerLens_Server - The layer frame(%@) seems really weird. Lookin will ignore it to avoid potential render error in Lookin.", NSStringFromCGRect(layer.frame));
        item.frame = CGRectZero;
    }
    item.bounds = layer.bounds;
    if (hasScreenshots) {
        item.soloScreenshot = [layer layerlens_soloScreenshotWithLowQuality:lowQuality];
        item.groupScreenshot = [layer layerlens_groupScreenshotWithLowQuality:lowQuality];
        item.screenshotEncodeType = LayerLens_DisplayItemImageEncodeTypeNSData;
    }
    
    if (hasAttrList) {
        item.attributesGroupList = [LayerLens_AttrGroupsMaker attrGroupsForLayer:layer];
        LayerLens_CustomAttrGroupsMaker *maker = [[LayerLens_CustomAttrGroupsMaker alloc] initWithLayer:layer];
        [maker execute];
        item.customAttrGroupList = [maker getGroups];
        item.customDisplayTitle = [maker getCustomDisplayTitle];
        item.danceuiSource = [maker getDanceUISource];
    }
    
    item.isHidden = layer.isHidden;
    item.alpha = layer.opacity;
    item.layerObject = [LayerLens_Object instanceWithObject:layer];
    item.shouldCaptureImage = [LayerLens_ConfigManager shouldCaptureScreenshotOfLayer:layer];
    
    if (layer.layerlens_hostView) {
        UIView *view = layer.layerlens_hostView;
        item.viewObject = [LayerLens_Object instanceWithObject:view];
        item.eventHandlers = [LayerLens_EventHandlerMaker makeForView:view];
        item.backgroundColor = view.backgroundColor;
        
        UIViewController* vc = [view layerlens_findHostViewController];
        if (vc) {
            item.hostViewControllerObject = [LayerLens_Object instanceWithObject:vc];
        }
    } else {
        item.backgroundColor = [UIColor layerlens_colorWithCGColor:layer.backgroundColor];
    }
    
    if (layer.sublayers.count) {
        NSArray<CALayer *> *sublayers = [layer.sublayers copy];
        NSMutableArray<LayerLens_DisplayItem *> *allSubitems = [NSMutableArray arrayWithCapacity:sublayers.count];
        [sublayers enumerateObjectsUsingBlock:^(__kindof CALayer * _Nonnull sublayer, NSUInteger idx, BOOL * _Nonnull stop) {
            LayerLens_DisplayItem *sublayer_item = [self _displayItemWithLayer:sublayer screenshots:hasScreenshots attrList:hasAttrList lowImageQuality:lowQuality readCustomInfo:readCustomInfo saveCustomSetter:saveCustomSetter];
            if (sublayer_item) {
                [allSubitems addObject:sublayer_item];
            }
        }];
        item.subitems = [allSubitems copy];
    }
    if (readCustomInfo) {
        NSArray<LayerLens_DisplayItem *> *customSubitems = [[[LayerLens_CustomDisplayItemsMaker alloc] initWithLayer:layer saveAttrSetter:saveCustomSetter] make];
        if (customSubitems.count > 0) {
            if (item.subitems) {
                item.subitems = [item.subitems arrayByAddingObjectsFromArray:customSubitems];
            } else {
                item.subitems = customSubitems;
            }
        }        
    }
    
    return item;
}

+ (NSArray<LayerLens_DisplayItem *> *)subitemsOfLayer:(CALayer *)layer {
    if (!layer || layer.sublayers.count == 0) {
        return @[];
    }
    [[LayerLens_TraceManager sharedInstance] reload];
    
    NSMutableArray<LayerLens_DisplayItem *> *resultSubitems = [NSMutableArray array];

    NSArray<CALayer *> *sublayers = [layer.sublayers copy];
    [sublayers enumerateObjectsUsingBlock:^(__kindof CALayer * _Nonnull sublayer, NSUInteger idx, BOOL * _Nonnull stop) {
        LayerLens_DisplayItem *sublayer_item = [self _displayItemWithLayer:sublayer screenshots:NO attrList:NO lowImageQuality:NO readCustomInfo:YES saveCustomSetter:YES];
        if (sublayer_item) {
            [resultSubitems addObject:sublayer_item];
        }
    }];

    NSArray<LayerLens_DisplayItem *> *customSubitems = [[[LayerLens_CustomDisplayItemsMaker alloc] initWithLayer:layer saveAttrSetter:YES] make];
    if (customSubitems.count > 0) {
        [resultSubitems addObjectsFromArray:customSubitems];
    }
    
    return resultSubitems;
}

+ (BOOL)validateFrame:(CGRect)frame {
    return !CGRectIsNull(frame) && !CGRectIsInfinite(frame) && ![self cgRectIsNaN:frame] && ![self cgRectIsInf:frame] && ![self cgRectIsUnreasonable:frame];
}

+ (BOOL)cgRectIsNaN:(CGRect)rect {
    return isnan(rect.origin.x) || isnan(rect.origin.y) || isnan(rect.size.width) || isnan(rect.size.height);
}

+ (BOOL)cgRectIsInf:(CGRect)rect {
    return isinf(rect.origin.x) || isinf(rect.origin.y) || isinf(rect.size.width) || isinf(rect.size.height);
}

+ (BOOL)cgRectIsUnreasonable:(CGRect)rect {
    return ABS(rect.origin.x) > 100000 || ABS(rect.origin.y) > 100000 || rect.size.width < 0 || rect.size.height < 0 || rect.size.width > 100000 || rect.size.height > 100000;
}

@end

