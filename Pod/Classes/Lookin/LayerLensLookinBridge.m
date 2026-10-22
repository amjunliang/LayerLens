//
//  LayerLensLookinBridge.m
//  LayerLens
//
//  Created by YueYou on 10/12/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LayerLensLookinBridge.h"
#import "LayerLens.h"
#import "LayerLensLookinSerializer.h"
#import "LayerLens_HierarchyDisplayItemsMaker.h"
#import "LayerLens_AttrGroupsMaker.h"
#import "LayerLens_CustomAttrGroupsMaker.h"
#import "LayerLens_EventHandlerMaker.h"
#import "LayerLens_InbuiltAttrModificationHandler.h"
#import "LayerLens_DisplayItem.h"
#import "LayerLens_DisplayItemDetail.h"
#import "LayerLens_AttributeModification.h"
#import "LayerLens_DashboardBlueprint.h"
#import "NSObject+LayerLens_Server.h"
#import "CALayer+LayerLens_Server.h"
#import <sys/utsname.h>

@implementation LayerLensLookinBridge

+ (NSString *)instanceId {
    static NSString *identifier = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        identifier = [NSUUID UUID].UUIDString;
    });
    return identifier;
}

+ (NSDictionary *)appInfo {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    struct utsname systemInfo;
    uname(&systemInfo);
    UIScreen *screen = UIScreen.mainScreen;
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    // 缺少版本号或构建号时只显示有的部分
    NSString *shortVersion = info[@"CFBundleShortVersionString"] ?: @"";
    NSString *build = info[@"CFBundleVersion"] ?: @"";
    NSString *version = build.length && shortVersion.length ? [NSString stringWithFormat:@"%@ (%@)", shortVersion, build] : (shortVersion.length ? shortVersion : build);
    return @{
        @"apiVersion": @(LayerLensAPIVersion),
        @"podVersion": LayerLensVersion,
        @"instanceId": [self instanceId],
        @"appName": info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: @"",
        @"bundleId": NSBundle.mainBundle.bundleIdentifier ?: @"",
        @"version": version,
        @"device": [NSString stringWithUTF8String:systemInfo.machine] ?: @"",
        // 模拟器上为模拟器名称, 真机为用户设置的设备名(iOS 16 起无权限时为通用名称)
        @"deviceName": environment[@"SIMULATOR_DEVICE_NAME"] ?: UIDevice.currentDevice.name ?: @"",
        @"os": [NSString stringWithFormat:@"%@ %@", UIDevice.currentDevice.systemName, UIDevice.currentDevice.systemVersion],
        @"screen": @[@(screen.bounds.size.width), @(screen.bounds.size.height)],
        @"scale": @(screen.scale),
        // 仅模拟器有值, Mac App 据此匹配模拟器和实时画面
        @"simulatorUDID": environment[@"SIMULATOR_UDID"] ?: @"",
        // 在后台但没被挂起(如 Xcode 调试中)时仍能响应, 网页据此标记在后台
        @"foreground": @(UIApplication.sharedApplication.applicationState != UIApplicationStateBackground),
#if TARGET_OS_SIMULATOR
        // 编译时的源文件路径, 模拟器与 Mac 共用文件系统, Mac App 据此找到对应的 Xcode 工作区
        @"sourceFile": @(__FILE__),
#endif
    };
}

+ (NSArray<NSDictionary *> *)hierarchy {
    NSArray<LayerLens_DisplayItem *> *items = [LayerLens_HierarchyDisplayItemsMaker itemsWithScreenshots:NO attrList:NO lowImageQuality:NO readCustomInfo:YES saveCustomSetter:YES];
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:items.count];
    for (LayerLens_DisplayItem *item in items) {
        [result addObject:[LayerLensLookinSerializer nodeFromDisplayItem:item parentRect:CGRectZero]];
    }
    return result;
}

+ (NSDictionary *)detailWithOid:(unsigned long)oid {
    CALayer *layer = [self layerWithOid:oid];
    if (!layer) {
        return nil;
    }
    NSArray *groups = [LayerLens_AttrGroupsMaker attrGroupsForLayer:layer];
    LayerLens_CustomAttrGroupsMaker *maker = [[LayerLens_CustomAttrGroupsMaker alloc] initWithLayer:layer];
    [maker execute];
    NSArray *events = layer.layerlens_hostView ? [LayerLens_EventHandlerMaker makeForView:layer.layerlens_hostView] : nil;

    return @{
        @"oid": @(oid),
        @"rect": [LayerLensLookinSerializer JSONValueFromValue:[NSValue valueWithCGRect:[LayerLensLookinSerializer screenRectOfLayer:layer]] attrType:LayerLens_AttrTypeCGRect],
        @"frame": [LayerLensLookinSerializer JSONValueFromValue:[NSValue valueWithCGRect:layer.frame] attrType:LayerLens_AttrTypeCGRect],
        @"hidden": @(layer.isHidden),
        @"alpha": @(layer.opacity),
        @"groups": [LayerLensLookinSerializer attrGroupsFromGroups:groups custom:NO],
        @"customGroups": [LayerLensLookinSerializer attrGroupsFromGroups:[maker getGroups] custom:YES],
        @"events": [LayerLensLookinSerializer eventHandlersFromHandlers:events],
    };
}

+ (NSData *)screenshotWithOid:(unsigned long)oid solo:(BOOL)solo soloLayers:(BOOL)soloLayers {
    CALayer *layer = [self layerWithOid:oid];
    if (!layer || CGRectIsEmpty(layer.bounds)) {
        return nil;
    }
    // 拉取层级后视图可能已移出 window(如列表页被回收), 此时 drawViewHierarchyInRect 会把视图挪到临时 window,
    // 遇到 VC 父子关系不一致时 UIKit 直接 abort, 已离开 window 的视图不再截图; UIWindow 自身的 window 为 nil, 需排除
    UIView *hostView = layer.layerlens_hostView;
    if (hostView && ![hostView isKindOfClass:UIWindow.class] && !hostView.window) {
        return nil;
    }
    UIImage *image = solo ? [self soloScreenshotOfLayer:layer hideLayers:soloLayers] : [self groupScreenshotOfLayer:layer];
    return image ? UIImagePNGRepresentation(image) : nil;
}

/// App 不在前台(切换 App、进入后台)时 drawViewHierarchyInRect:afterScreenUpdates:YES 会把视图挪到临时的 _UISnapshotWindow,
/// 触发 willMoveToSuperview 等回调, 遇到 MJRefresh 这类在回调里移除 KVO 的视图会直接崩溃; 此时改用 renderInContext, 不移动视图
+ (UIImage *)groupScreenshotOfLayer:(CALayer *)layer {
    if ([self canDrawHierarchyOfLayer:layer]) {
        return [layer layerlens_groupScreenshotWithLowQuality:NO];
    }
    CGSize size = layer.frame.size;
    if (size.width <= 0 || size.height <= 0 || size.width > 20000 || size.height > 20000) {
        return nil;
    }
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    [layer renderInContext:UIGraphicsGetCurrentContext()];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

+ (BOOL)canDrawHierarchyOfLayer:(CALayer *)layer {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        return NO;
    }
    UIView *view = layer.layerlens_hostView;
    UIWindow *window = [view isKindOfClass:UIWindow.class] ? (UIWindow *)view : view.window;
    if (!window) {
        // 纯 CALayer 由 Lookin 走 renderInContext, 不受影响
        return YES;
    }
    if (@available(iOS 13.0, *)) {
        return window.windowScene.activationState == UISceneActivationStateForegroundActive;
    }
    return YES;
}

+ (void)modifyWithOid:(unsigned long)oid attrId:(NSString *)attrId attrType:(NSInteger)attrType value:(id)value completion:(void (^)(NSDictionary *, NSString *))completion {
    CALayer *layer = [self layerWithOid:oid];
    if (!layer) {
        completion(nil, @"Object not found, please refresh");
        return;
    }
    SEL setter = [LayerLens_DashboardBlueprint setterWithAttrID:attrId];
    SEL getter = [LayerLens_DashboardBlueprint getterWithAttrID:attrId];
    if (!setter) {
        completion(nil, @"Attribute is read-only");
        return;
    }

    BOOL supported = NO;
    id modificationValue = [LayerLensLookinSerializer modificationValueFromJSONValue:value attrType:attrType supported:&supported];
    if (!supported) {
        completion(nil, @"Unsupported value");
        return;
    }

    NSObject *target = [LayerLens_DashboardBlueprint isUIViewPropertyWithAttrID:attrId] ? layer.layerlens_hostView : layer;
    if (!target) {
        completion(nil, @"Target not found");
        return;
    }

    LayerLens_AttributeModification *modification = [[LayerLens_AttributeModification alloc] init];
    modification.targetOid = [target layerlens_registerOid];
    modification.setterSelector = setter;
    modification.getterSelector = getter;
    modification.attrType = attrType;
    modification.value = modificationValue;

    [LayerLens_InbuiltAttrModificationHandler handleModification:modification completion:^(LayerLens_DisplayItemDetail *data, NSError *error) {
        NSString *message = error ? (error.localizedRecoverySuggestion ?: error.localizedDescription) : nil;
        completion([self detailWithOid:oid], message);
    }];
}

+ (NSObject *)objectWithOid:(unsigned long)oid {
    return [NSObject layerlens_objectWithOid:oid];
}

+ (unsigned long)nodeOidForObject:(NSObject *)object {
    if ([object isKindOfClass:UIView.class]) {
        return [((UIView *)object).layer layerlens_registerOid];
    }
    return [object layerlens_registerOid];
}

#pragma mark - Private

// 与 Lookin 的 solo 截图相同: 临时隐藏单独绘制的子层后整体截图; 没有要隐藏的子层时与 group 等价
+ (UIImage *)soloScreenshotOfLayer:(CALayer *)layer hideLayers:(BOOL)hideLayers {
    NSMutableArray<CALayer *> *hiddenSublayers = [NSMutableArray array];
    for (CALayer *sublayer in [layer.sublayers copy]) {
        if (!sublayer.hidden && (hideLayers || sublayer.layerlens_hostView)) {
            sublayer.hidden = YES;
            [hiddenSublayers addObject:sublayer];
        }
    }
    UIImage *image = [self groupScreenshotOfLayer:layer];
    for (CALayer *sublayer in hiddenSublayers) {
        sublayer.hidden = NO;
    }
    return image;
}

+ (CALayer *)layerWithOid:(unsigned long)oid {
    NSObject *object = [NSObject layerlens_objectWithOid:oid];
    if ([object isKindOfClass:UIView.class]) {
        return ((UIView *)object).layer;
    }
    return [object isKindOfClass:CALayer.class] ? (CALayer *)object : nil;
}

@end
