
//
//  LayerLens_ConfigManager.h
//  LayerLens_Server
//
//  Created by likai.123 on 2023/1/10.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface LayerLens_ConfigManager : NSObject

+ (NSArray<NSString *> *)collapsedClassList;

+ (NSDictionary<NSString *, UIColor *> *)colorAlias;

+ (BOOL)shouldCaptureScreenshotOfLayer:(CALayer *)layer;

@end

NS_ASSUME_NONNULL_END

