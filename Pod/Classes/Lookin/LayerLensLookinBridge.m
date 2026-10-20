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
#import "LKS_HierarchyDisplayItemsMaker.h"
#import "LKS_AttrGroupsMaker.h"
#import "LKS_CustomAttrGroupsMaker.h"
#import "LKS_EventHandlerMaker.h"
#import "LKS_InbuiltAttrModificationHandler.h"
#import "LookinDisplayItem.h"
#import "LookinDisplayItemDetail.h"
#import "LookinAttributeModification.h"
#import "LookinDashboardBlueprint.h"
#import "NSObject+LookinServer.h"
#import "CALayer+LookinServer.h"
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
    NSArray<LookinDisplayItem *> *items = [LKS_HierarchyDisplayItemsMaker itemsWithScreenshots:NO attrList:NO lowImageQuality:NO readCustomInfo:YES saveCustomSetter:YES];
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:items.count];
    for (LookinDisplayItem *item in items) {
        [result addObject:[LayerLensLookinSerializer nodeFromDisplayItem:item parentRect:CGRectZero]];
    }
    return result;
}

+ (NSDictionary *)detailWithOid:(unsigned long)oid {
    CALayer *layer = [self layerWithOid:oid];
    if (!layer) {
        return nil;
    }
    NSArray *groups = [LKS_AttrGroupsMaker attrGroupsForLayer:layer];
    LKS_CustomAttrGroupsMaker *maker = [[LKS_CustomAttrGroupsMaker alloc] initWithLayer:layer];
    [maker execute];
    NSArray *events = layer.lks_hostView ? [LKS_EventHandlerMaker makeForView:layer.lks_hostView] : nil;

    return @{
        @"oid": @(oid),
        @"rect": [LayerLensLookinSerializer JSONValueFromValue:[NSValue valueWithCGRect:[LayerLensLookinSerializer screenRectOfLayer:layer]] attrType:LookinAttrTypeCGRect],
        @"frame": [LayerLensLookinSerializer JSONValueFromValue:[NSValue valueWithCGRect:layer.frame] attrType:LookinAttrTypeCGRect],
        @"hidden": @(layer.isHidden),
        @"alpha": @(layer.opacity),
        @"groups": [LayerLensLookinSerializer attrGroupsFromGroups:groups custom:NO],
        @"customGroups": [LayerLensLookinSerializer attrGroupsFromGroups:[maker getGroups] custom:YES],
        @"events": [LayerLensLookinSerializer eventHandlersFromHandlers:events],
    };
}

+ (NSData *)screenshotWithOid:(unsigned long)oid solo:(BOOL)solo {
    CALayer *layer = [self layerWithOid:oid];
    if (!layer || CGRectIsEmpty(layer.bounds)) {
        return nil;
    }
    // 拉取层级后视图可能已移出 window(如列表页被回收), 此时 drawViewHierarchyInRect 会把视图挪到临时 window,
    // 遇到 VC 父子关系不一致时 UIKit 直接 abort, 已离开 window 的视图不再截图; UIWindow 自身的 window 为 nil, 需排除
    UIView *hostView = layer.lks_hostView;
    if (hostView && ![hostView isKindOfClass:UIWindow.class] && !hostView.window) {
        return nil;
    }
    // Lookin 的 solo 截图在没有 sublayer 时返回 nil, 此时 solo 与 group 等价
    BOOL useSolo = solo && layer.sublayers.count > 0;
    UIImage *image = useSolo ? [layer lks_soloScreenshotWithLowQuality:NO] : [layer lks_groupScreenshotWithLowQuality:NO];
    return image ? UIImagePNGRepresentation(image) : nil;
}

+ (void)modifyWithOid:(unsigned long)oid attrId:(NSString *)attrId attrType:(NSInteger)attrType value:(id)value completion:(void (^)(NSDictionary *, NSString *))completion {
    CALayer *layer = [self layerWithOid:oid];
    if (!layer) {
        completion(nil, @"Object not found, please refresh");
        return;
    }
    SEL setter = [LookinDashboardBlueprint setterWithAttrID:attrId];
    SEL getter = [LookinDashboardBlueprint getterWithAttrID:attrId];
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

    NSObject *target = [LookinDashboardBlueprint isUIViewPropertyWithAttrID:attrId] ? layer.lks_hostView : layer;
    if (!target) {
        completion(nil, @"Target not found");
        return;
    }

    LookinAttributeModification *modification = [[LookinAttributeModification alloc] init];
    modification.targetOid = [target lks_registerOid];
    modification.setterSelector = setter;
    modification.getterSelector = getter;
    modification.attrType = attrType;
    modification.value = modificationValue;

    [LKS_InbuiltAttrModificationHandler handleModification:modification completion:^(LookinDisplayItemDetail *data, NSError *error) {
        NSString *message = error ? (error.localizedRecoverySuggestion ?: error.localizedDescription) : nil;
        completion([self detailWithOid:oid], message);
    }];
}

+ (NSObject *)objectWithOid:(unsigned long)oid {
    return [NSObject lks_objectWithOid:oid];
}

+ (unsigned long)nodeOidForObject:(NSObject *)object {
    if ([object isKindOfClass:UIView.class]) {
        return [((UIView *)object).layer lks_registerOid];
    }
    return [object lks_registerOid];
}

#pragma mark - Private

+ (CALayer *)layerWithOid:(unsigned long)oid {
    NSObject *object = [NSObject lks_objectWithOid:oid];
    if ([object isKindOfClass:UIView.class]) {
        return ((UIView *)object).layer;
    }
    return [object isKindOfClass:CALayer.class] ? (CALayer *)object : nil;
}

@end
