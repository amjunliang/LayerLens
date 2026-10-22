
//
//  LayerLens_AttrGroupsMaker.h
//  LayerLens_Server
//
//  Created by Li Kai on 2019/6/6.
//  https://lookin.work
//

#import "LayerLens_Defines.h"

@class LayerLens_AttributesGroup;

@interface LayerLens_AttrGroupsMaker : NSObject
    
+ (NSArray<LayerLens_AttributesGroup *> *)attrGroupsForLayer:(CALayer *)layer;

@end

