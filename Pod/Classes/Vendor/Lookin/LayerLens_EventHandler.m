
//
//  LayerLens_EventHandler.m
//  Lookin
//
//  Created by Li Kai on 2019/8/7.
//  https://lookin.work
//



#import "LayerLens_EventHandler.h"
#import "LayerLens_Object.h"
#import "LayerLens_Tuple.h"

#import "NSArray+LayerLens_Shared.h"

@implementation LayerLens_EventHandler

#pragma mark - <NSCopying>

- (id)copyWithZone:(NSZone *)zone {
    LayerLens_EventHandler *newHandler = [[LayerLens_EventHandler allocWithZone:zone] init];
    newHandler.handlerType = self.handlerType;
    newHandler.eventName = self.eventName;
    newHandler.targetActions = [self.targetActions layerlens_map:^id(NSUInteger idx, LayerLens_StringTwoTuple *value) {
        return value.copy;
    }];
    newHandler.gestureRecognizerIsEnabled = self.gestureRecognizerIsEnabled;
    newHandler.gestureRecognizerDelegator = self.gestureRecognizerDelegator;
    newHandler.inheritedRecognizerName = self.inheritedRecognizerName;
    newHandler.recognizerIvarTraces = self.recognizerIvarTraces.copy;
    newHandler.recognizerOid = self.recognizerOid;
    return newHandler;
}

#pragma mark - <NSSecureCoding>

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeInteger:self.handlerType forKey:@"handlerType"];
    [aCoder encodeBool:self.gestureRecognizerIsEnabled forKey:@"gestureRecognizerIsEnabled"];
    [aCoder encodeObject:self.eventName forKey:@"eventName"];
    [aCoder encodeObject:self.gestureRecognizerDelegator forKey:@"gestureRecognizerDelegator"];
    [aCoder encodeObject:self.targetActions forKey:@"targetActions"];
    [aCoder encodeObject:self.inheritedRecognizerName forKey:@"inheritedRecognizerName"];
    [aCoder encodeObject:self.recognizerIvarTraces forKey:@"recognizerIvarTraces"];
    [aCoder encodeObject:@(self.recognizerOid) forKey:@"recognizerOid"];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super init]) {
        self.handlerType = [aDecoder decodeIntegerForKey:@"handlerType"];
        self.gestureRecognizerIsEnabled = [aDecoder decodeBoolForKey:@"gestureRecognizerIsEnabled"];
        self.eventName = [aDecoder decodeObjectForKey:@"eventName"];
        self.gestureRecognizerDelegator = [aDecoder decodeObjectForKey:@"gestureRecognizerDelegator"];
        self.targetActions = [aDecoder decodeObjectForKey:@"targetActions"];
        self.inheritedRecognizerName = [aDecoder decodeObjectForKey:@"inheritedRecognizerName"];
        self.recognizerIvarTraces = [aDecoder decodeObjectForKey:@"recognizerIvarTraces"];
        self.recognizerOid = ((NSNumber *)[aDecoder decodeObjectForKey:@"recognizerOid"]).unsignedLongValue;
    }
    return self;
}

+ (BOOL)supportsSecureCoding {
    return YES;
}

@end

