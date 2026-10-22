
//
//  LayerLens_TraceManager.h
//  LayerLens_Server
//
//  Created by Li Kai on 2019/5/5.
//  https://lookin.work
//



#import <Foundation/Foundation.h>

@class LayerLens_IvarTrace;

@interface LayerLens_TraceManager : NSObject

+ (instancetype)sharedInstance;

- (void)reload;

- (void)addSearchTarger:(id)target;

@end

