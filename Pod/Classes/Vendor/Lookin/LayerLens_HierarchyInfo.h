
//
//  LayerLens_DisplayInfo.h
//  WeRead
//
//  Created by Li Kai on 2018/10/22.
//  Copyright © 2018年 tencent. All rights reserved.
//



#import "LayerLens_Defines.h"
#import "TargetConditionals.h"
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#elif TARGET_OS_MAC
#import <Appkit/Appkit.h>
#endif

@class LayerLens_DisplayItem, LayerLens_AttributesGroup, LayerLens_AppInfo;

@interface LayerLens_HierarchyInfo : NSObject <NSSecureCoding, NSCopying>

#if TARGET_OS_IPHONE

/// version 可能为 nil，此时说明 Client 版本号 < 1.0.4
+ (instancetype)staticInfoWithLayerLensVersion:(NSString *)version;

+ (instancetype)exportedInfo;

#endif

/// 这里其实就是顶端的那几个 UIWindow
@property(nonatomic, copy) NSArray<LayerLens_DisplayItem *> *displayItems;

@property(nonatomic, copy) NSDictionary<NSString *, id> *colorAlias;

@property(nonatomic, copy) NSArray<NSString *> *collapsedClassList;

@property(nonatomic, strong) LayerLens_AppInfo *appInfo;

@property(nonatomic, assign) int serverVersion;

@end

