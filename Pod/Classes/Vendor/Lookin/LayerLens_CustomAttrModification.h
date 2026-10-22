//
//  LayerLens_CustomAttrModification.h
//  LayerLens_Shared
//
//  Created by likaimacbookhome on 2023/11/4.
//

#import <Foundation/Foundation.h>
#import "LayerLens_AttrType.h"

@interface LayerLens_CustomAttrModification : NSObject <NSSecureCoding>

@property(nonatomic, assign) LayerLens_AttrType attrType;
@property(nonatomic, copy) NSString *customSetterID;
@property(nonatomic, strong) id value;

@end

