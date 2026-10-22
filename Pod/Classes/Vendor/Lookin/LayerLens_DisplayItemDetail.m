
//
//  LayerLens_DisplayItemDetail.m
//  Lookin
//
//  Created by Li Kai on 2019/2/19.
//  https://lookin.work
//

#import "LayerLens_DisplayItemDetail.h"
#import "Image+LayerLens_Shared.h"

#if TARGET_OS_IPHONE
#import "UIImage+LayerLens_Server.h"
#endif

@implementation LayerLens_DisplayItemDetail

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:@(self.displayItemOid) forKey:@"displayItemOid"];
    [aCoder encodeObject:self.groupScreenshot.layerlens_data forKey:@"groupScreenshot"];
    [aCoder encodeObject:self.soloScreenshot.layerlens_data forKey:@"soloScreenshot"];
    [aCoder encodeObject:self.frameValue forKey:@"frameValue"];
    [aCoder encodeObject:self.boundsValue forKey:@"boundsValue"];
    [aCoder encodeObject:self.hiddenValue forKey:@"hiddenValue"];
    [aCoder encodeObject:self.alphaValue forKey:@"alphaValue"];
    [aCoder encodeObject:self.attributesGroupList forKey:@"attributesGroupList"];
    [aCoder encodeObject:self.customAttrGroupList forKey:@"customAttrGroupList"];
    [aCoder encodeObject:self.customDisplayTitle forKey:@"customDisplayTitle"];
    [aCoder encodeObject:self.danceUISource forKey:@"danceUISource"];
    [aCoder encodeInteger:self.failureCode forKey:@"failureCode"];
    if (self.subitems) {
        [aCoder encodeObject:self.subitems forKey:@"subitems"];
    }
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super init]) {
        self.displayItemOid = [[aDecoder decodeObjectForKey:@"displayItemOid"] unsignedLongValue];
        self.groupScreenshot = [[LayerLens_Image alloc] initWithData:[aDecoder decodeObjectForKey:@"groupScreenshot"]];
        self.soloScreenshot = [[LayerLens_Image alloc] initWithData:[aDecoder decodeObjectForKey:@"soloScreenshot"]];
        self.frameValue = [aDecoder decodeObjectForKey:@"frameValue"];
        self.boundsValue = [aDecoder decodeObjectForKey:@"boundsValue"];
        self.hiddenValue = [aDecoder decodeObjectForKey:@"hiddenValue"];
        self.alphaValue = [aDecoder decodeObjectForKey:@"alphaValue"];
        self.attributesGroupList = [aDecoder decodeObjectForKey:@"attributesGroupList"];
        self.customAttrGroupList = [aDecoder decodeObjectForKey:@"customAttrGroupList"];
        self.customDisplayTitle = [aDecoder decodeObjectForKey:@"customDisplayTitle"];
        self.danceUISource = [aDecoder decodeObjectForKey:@"danceUISource"];
        
        if ([aDecoder containsValueForKey:@"failureCode"]) {
            self.failureCode = [aDecoder decodeIntegerForKey:@"failureCode"];
        } else {
            self.failureCode = 0;
        }
        
        if ([aDecoder containsValueForKey:@"subitems"]) {
            self.subitems = [aDecoder decodeObjectForKey:@"subitems"];
        }
    }
    return self;
}

+ (BOOL)supportsSecureCoding {
    return YES;
}

@end

