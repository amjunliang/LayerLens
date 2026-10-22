
//
//  LayerLens_DisplayInfo.m
//  WeRead
//
//  Created by Li Kai on 2018/10/22.
//  Copyright © 2018年 tencent. All rights reserved.
//

#import <objc/runtime.h>
#import "LayerLens_HierarchyInfo.h"
#import "LayerLens_AttributesGroup.h"
#import "LayerLens_DisplayItem.h"
#import "LayerLens_AppInfo.h"
#import "NSArray+LayerLens_Shared.h"
#import "NSString+LayerLens_Shared.h"

#if TARGET_OS_IPHONE
#import "LayerLens_HierarchyDisplayItemsMaker.h"
#import "LayerLens_ConfigManager.h"
#import "LayerLens_CustomAttrSetterManager.h"
#endif

@implementation LayerLens_HierarchyInfo

#if TARGET_OS_IPHONE

+ (instancetype)staticInfoWithLayerLensVersion:(NSString *)version {
    BOOL readCustomInfo = NO;
    // Client 1.0.4 开始支持 customInfo
    if (version && [version layerlens_numbericOSVersion] >= 10004) {
        readCustomInfo = YES;
    }
    
    [[LayerLens_CustomAttrSetterManager sharedInstance] removeAll];
    
    LayerLens_HierarchyInfo *info = [LayerLens_HierarchyInfo new];
    info.serverVersion = LAYERLENS_SERVER_VERSION;
    info.displayItems = [LayerLens_HierarchyDisplayItemsMaker itemsWithScreenshots:NO attrList:NO lowImageQuality:NO readCustomInfo:readCustomInfo saveCustomSetter:YES];
    info.appInfo = [LayerLens_AppInfo currentInfoWithScreenshot:NO icon:YES localIdentifiers:nil];
    info.collapsedClassList = [LayerLens_ConfigManager collapsedClassList];
    info.colorAlias = [LayerLens_ConfigManager colorAlias];
    return info;
}

+ (instancetype)exportedInfo {
    LayerLens_HierarchyInfo *info = [LayerLens_HierarchyInfo new];
    info.serverVersion = LAYERLENS_SERVER_VERSION;
    info.displayItems = [LayerLens_HierarchyDisplayItemsMaker itemsWithScreenshots:YES attrList:YES lowImageQuality:YES readCustomInfo:YES saveCustomSetter:NO];
    info.appInfo = [LayerLens_AppInfo currentInfoWithScreenshot:NO icon:YES localIdentifiers:nil];
    info.collapsedClassList = [LayerLens_ConfigManager collapsedClassList];
    info.colorAlias = [LayerLens_ConfigManager colorAlias];
    return info;
}

#endif

#pragma mark - <NSSecureCoding>

static NSString * const LayerLens_HierarchyInfoCodingKey_DisplayItems = @"1";
static NSString * const LayerLens_HierarchyInfoCodingKey_AppInfo = @"2";
static NSString * const LayerLens_HierarchyInfoCodingKey_ColorAlias = @"3";
static NSString * const LayerLens_HierarchyInfoCodingKey_CollapsedClassList = @"4";

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:self.displayItems forKey:LayerLens_HierarchyInfoCodingKey_DisplayItems];
    [aCoder encodeObject:self.colorAlias forKey:LayerLens_HierarchyInfoCodingKey_ColorAlias];
    [aCoder encodeObject:self.collapsedClassList forKey:LayerLens_HierarchyInfoCodingKey_CollapsedClassList];
    [aCoder encodeObject:self.appInfo forKey:LayerLens_HierarchyInfoCodingKey_AppInfo];
    [aCoder encodeInt:self.serverVersion forKey:@"serverVersion"];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super init]) {
        self.displayItems = [aDecoder decodeObjectForKey:LayerLens_HierarchyInfoCodingKey_DisplayItems];
        self.colorAlias = [aDecoder decodeObjectForKey:LayerLens_HierarchyInfoCodingKey_ColorAlias];
        self.collapsedClassList = [aDecoder decodeObjectForKey:LayerLens_HierarchyInfoCodingKey_CollapsedClassList];
        self.appInfo = [aDecoder decodeObjectForKey:LayerLens_HierarchyInfoCodingKey_AppInfo];
        self.serverVersion = [aDecoder decodeIntForKey:@"serverVersion"];
    }
    return self;
}

+ (BOOL)supportsSecureCoding {
    return YES;
}

#pragma mark - <NSCopying>

- (id)copyWithZone:(NSZone *)zone {
    LayerLens_HierarchyInfo *newAppInfo = [[LayerLens_HierarchyInfo allocWithZone:zone] init];
    newAppInfo.serverVersion = self.serverVersion;
    newAppInfo.appInfo = self.appInfo.copy;
    newAppInfo.collapsedClassList = self.collapsedClassList;
    newAppInfo.colorAlias = self.colorAlias;
    newAppInfo.displayItems = [self.displayItems layerlens_map:^id(NSUInteger idx, LayerLens_DisplayItem *oldItem) {
        return oldItem.copy;
    }];
    
    return newAppInfo;
}

@end

