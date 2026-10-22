
//
//  LayerLens_CustomDisplayItemsMaker.m
//  LayerLens_Server
//
//  Created by likai.123 on 2023/11/1.
//

#import "LayerLens_CustomDisplayItemsMaker.h"
#import "CALayer+LayerLens_Server.h"
#import "LayerLens_DisplayItem.h"
#import "NSArray+LayerLens_Shared.h"
#import "LayerLens_CustomAttrGroupsMaker.h"

@interface LayerLens_CustomDisplayItemsMaker ()

@property(nonatomic, weak) CALayer *layer;
@property(nonatomic, assign) BOOL saveAttrSetter;
@property(nonatomic, strong) NSMutableArray *allSubitems;

@end

@implementation LayerLens_CustomDisplayItemsMaker

- (instancetype)initWithLayer:(CALayer *)layer saveAttrSetter:(BOOL)saveAttrSetter {
    if (self = [super init]) {
        self.layer = layer;
        self.saveAttrSetter = saveAttrSetter;
        self.allSubitems = [NSMutableArray array];
    }
    return self;
}

- (NSArray<LayerLens_DisplayItem *> *)make {
    if (!self.layer) {
        NSAssert(NO, @"");
        return nil;
    }
    NSMutableArray<NSString *> *selectors = [NSMutableArray array];
    [selectors addObject:@"layerlens_customDebugInfos"];
    for (int i = 0; i < 5; i++) {
        [selectors addObject:[NSString stringWithFormat:@"layerlens_customDebugInfos_%@", @(i)]];
    }
    
    for (NSString *name in selectors) {
        [self makeSubitemsForViewOrLayer:self.layer selectorName:name];
        
        UIView *view = self.layer.layerlens_hostView;
        if (view) {
            [self makeSubitemsForViewOrLayer:view selectorName:name];
        }
    }
    
    if (self.allSubitems.count) {
        return self.allSubitems;
    } else {
        return nil;
    }
}

- (void)makeSubitemsForViewOrLayer:(id)viewOrLayer selectorName:(NSString *)selectorName {
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
    NSDictionary<NSString *, id> *rawData = tempRawData;
    
    [self makeSubitemsFromRawData:rawData];
}

- (void)makeSubitemsFromRawData:(NSDictionary<NSString *, id> *)data {
    if (!data || ![data isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSArray *rawSubviews = data[@"subviews"];
    NSArray<LayerLens_DisplayItem *> *newSubitems = [self displayItemsFromRawArray:rawSubviews];
    if (newSubitems) {
        [self.allSubitems addObjectsFromArray:newSubitems];
    }
}

- (NSArray<LayerLens_DisplayItem *> *)displayItemsFromRawArray:(NSArray<NSDictionary *> *)rawArray {
    if (!rawArray || ![rawArray isKindOfClass:[NSArray class]]) {
        return nil;
    }
    NSArray *items = [rawArray layerlens_map:^id(NSUInteger idx, NSDictionary *rawDict) {
        if (![rawDict isKindOfClass:[NSDictionary class]]) {
            return nil;
        }
        return [self displayItemFromRawDict:rawDict];
    }];
    return items;
}

- (LayerLens_DisplayItem *)displayItemFromRawDict:(NSDictionary<NSString *, id> *)dict {
    NSString *title = dict[@"title"];
    NSString *subtitle = dict[@"subtitle"];
    NSValue *frameValue = dict[@"frameInWindow"];
    NSArray *properties = dict[@"properties"];
    NSArray *subviews = dict[@"subviews"];
    NSString *danceSource = dict[@"layerlens_source"];
    
    if (![title isKindOfClass:[NSString class]]) {
        return nil;
    }
    LayerLens_DisplayItem *newItem = [LayerLens_DisplayItem new];
    if (subviews && [subviews isKindOfClass:[NSArray class]]) {
        newItem.subitems = [self displayItemsFromRawArray:subviews];
    }
    newItem.isHidden = NO;
    newItem.alpha = 1.0;
    newItem.customInfo = [LayerLens_CustomDisplayItemInfo new];
    newItem.customInfo.title = title;
    newItem.customInfo.subtitle = subtitle;
    newItem.customInfo.frameInWindow = frameValue;
    newItem.customInfo.danceuiSource = danceSource;
    newItem.customAttrGroupList = [LayerLens_CustomAttrGroupsMaker makeGroupsFromRawProperties:properties saveCustomSetter:self.saveAttrSetter];
    
    return newItem;
}

@end

