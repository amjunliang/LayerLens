
//
//  LayerLens_EventHandler.h
//  Lookin
//
//  Created by Li Kai on 2019/8/7.
//  https://lookin.work
//



#import <Foundation/Foundation.h>

@class LayerLens_Object, LayerLens_IvarTrace, LayerLens_StringTwoTuple;

typedef NS_ENUM(NSInteger, LayerLens_EventHandlerType) {
    LayerLens_EventHandlerTypeTargetAction,
    LayerLens_EventHandlerTypeGesture
};

@interface LayerLens_EventHandler : NSObject <NSSecureCoding>

@property(nonatomic, assign) LayerLens_EventHandlerType handlerType;

/// 比如 "UIControlEventTouchUpInside", "UITapGestureRecognizer"
@property(nonatomic, copy) NSString *eventName;
/// tuple.first => @"<WRHomeView: 0xff>"，tuple.second => @"handleTap"
@property(nonatomic, copy) NSArray<LayerLens_StringTwoTuple *> *targetActions;

/// 返回当前 recognizer 是继承自哪一个基本款 recognizer。
/// 基本款 recognizer 指的是 TapRecognizer, PinchRecognizer 之类的常见 recognizer
/// 如果当前 recognizer 本身就是基本款 recognizer，则该属性为 nil
@property(nonatomic, copy) NSString *inheritedRecognizerName;
@property(nonatomic, assign) BOOL gestureRecognizerIsEnabled;
@property(nonatomic, copy) NSString *gestureRecognizerDelegator;
@property(nonatomic, copy) NSArray<NSString *> *recognizerIvarTraces;
/// recognizer 对象
@property(nonatomic, assign) unsigned long long recognizerOid;

@end

