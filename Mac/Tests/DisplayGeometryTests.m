#import <Foundation/Foundation.h>
#import "display_geometry.h"

static NSDictionary *Display(NSString *backlight) {
    NSMutableDictionary *value = [@{
        @"displays": @[@{
            @"primary": @YES,
            @"nativeSize": @[@1179, @2556],
            @"pointScale": @3,
            @"displayId": @1,
            @"nativeOrientation": @"rot0",
            @"currentOrientation": @"rot0",
        }],
        @"orientation": @{
            @"currentDeviceOrientation": @"portrait",
            @"currentDeviceNonFlatOrientation": @"portrait",
        },
    } mutableCopy];
    if (backlight) value[@"backlightState"] = backlight;
    return value;
}

int main(void) { @autoreleasepool {
    IPBDisplayInfo info = {0};
    NSCAssert(ipbParseDisplayInfo(Display(@"off"), &info), @"Sleeping display should parse");
    NSCAssert(info.backlightKnown && !info.backlightOn && ipbDisplayNeedsWake(info), @"Sleeping display must wake before input");
    NSCAssert(ipbParseDisplayInfo(Display(@"activeOn"), &info), @"Awake display should parse");
    NSCAssert(info.backlightKnown && info.backlightOn && !ipbDisplayNeedsWake(info), @"Awake display must not toggle");
    NSCAssert(ipbParseDisplayInfo(Display(nil), &info), @"Missing backlight should remain unknown");
    NSCAssert(!info.backlightKnown && !ipbDisplayNeedsWake(info), @"Unknown backlight must never toggle");
    puts("PASS display state: cached backlight safely gates input wake");
}}
