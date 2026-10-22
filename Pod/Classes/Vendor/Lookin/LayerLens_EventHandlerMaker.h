
//
//  LayerLens_EventHandlerMaker.h
//  LayerLens_Server
//
//  Created by Li Kai on 2019/8/7.
//  https://lookin.work
//

#import "LayerLens_Defines.h"

@class LayerLens_EventHandler;

@interface LayerLens_EventHandlerMaker : NSObject

+ (NSArray<LayerLens_EventHandler *> *)makeForView:(UIView *)view;

@end

