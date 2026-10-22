//
//  LayerLens_CustomAttrGroupsMaker.h
//  LayerLens_Server
//
//  Created by LikaiMacStudioWork on 2023/10/31.
//

#import "LayerLens_Defines.h"

@class LayerLens_AttributesGroup;

@interface LayerLens_CustomAttrGroupsMaker : NSObject

- (instancetype)initWithLayer:(CALayer *)layer;

- (void)execute;

- (NSArray<LayerLens_AttributesGroup *> *)getGroups;
- (NSString *)getCustomDisplayTitle;
- (NSString *)getDanceUISource;

+ (NSArray<LayerLens_AttributesGroup *> *)makeGroupsFromRawProperties:(NSArray *)rawProperties saveCustomSetter:(BOOL)saveCustomSetter;

@end

