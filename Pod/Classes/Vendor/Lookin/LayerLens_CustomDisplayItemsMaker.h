
//
//  LayerLens_CustomDisplayItemsMaker.h
//  LayerLens_Server
//
//  Created by likai.123 on 2023/11/1.
//

#import <UIKit/UIKit.h>

@class LayerLens_DisplayItem;

@interface LayerLens_CustomDisplayItemsMaker : NSObject

- (instancetype)initWithLayer:(CALayer *)layer saveAttrSetter:(BOOL)saveAttrSetter;

- (NSArray<LayerLens_DisplayItem *> *)make;

@end

