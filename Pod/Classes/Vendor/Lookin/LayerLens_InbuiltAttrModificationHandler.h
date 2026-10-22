
//
//  LayerLens_InbuiltAttrModificationHandler.h
//  LayerLens_Server
//
//  Created by Li Kai on 2019/6/12.
//  https://lookin.work
//

#import <Foundation/Foundation.h>

@class LayerLens_AttributeModification, LayerLens_DisplayItemDetail, LayerLens_StaticAsyncUpdateTask;

@interface LayerLens_InbuiltAttrModificationHandler : NSObject

+ (void)handleModification:(LayerLens_AttributeModification *)modification completion:(void (^)(LayerLens_DisplayItemDetail *data, NSError *error))completion;

+ (void)handlePatchWithTasks:(NSArray<LayerLens_StaticAsyncUpdateTask *> *)tasks block:(void (^)(LayerLens_DisplayItemDetail *data))block;

@end

