// The SDK runs on UIKit-based iOS targets only. Other platforms keep the
// public logging API available without compiling or linking the iOS inspector.
#import "LayerLens.h"
#import <TargetConditionals.h>

#if !TARGET_OS_IOS && !TARGET_OS_MACCATALYST
NSString * const LayerLensVersion = @"0.7.0";
const NSInteger LayerLensAPIVersion = 1;

@implementation LayerLens
+ (void)log:(NSString *)message {}
+ (NSString *)logDirectory { return @""; }
@end

void LayerLensLog(NSString *format, ...) {}
#endif
