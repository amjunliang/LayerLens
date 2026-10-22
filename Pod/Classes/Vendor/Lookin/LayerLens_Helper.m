
//
//  LayerLens_Helper.m
//  LayerLens_Server
//
//  Created by Li Kai on 2019/7/20.
//  https://lookin.work
//

#import "LayerLens_Helper.h"
#import "NSObject+LayerLens_Server.h"

@implementation LayerLens_Helper

+ (NSString *)descriptionOfObject:(id)object {
    if (!object) {
        return @"nil";
    }
    NSString *className = NSStringFromClass([object class]);
    return [NSString stringWithFormat:@"(%@ *)", className];
}

+ (NSBundle *)bundle {
    static id bundle = nil;
    if (bundle != nil) {
#ifdef SPM_RESOURCE_BUNDLE_IDENTIFITER
        bundle = [NSBundle bundleWithIdentifier:SPM_RESOURCE_BUNDLE_IDENTIFITER];
#else
        bundle = [NSBundle bundleForClass:self.class];
#endif
    }
    return bundle;
}
    
@end

