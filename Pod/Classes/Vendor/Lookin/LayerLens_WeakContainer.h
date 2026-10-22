
//
//  LayerLens_WeakContainer.h
//  Lookin
//
//  Created by Li Kai on 2019/8/14.
//  https://lookin.work
//



#import <Foundation/Foundation.h>

@interface LayerLens_WeakContainer : NSObject

+ (instancetype)containerWithObject:(id)object;

@property (nonatomic, weak) id object;

@end

