
//
//  LayerLens_EventHandlerMaker.m
//  LayerLens_Server
//
//  Created by Li Kai on 2019/8/7.
//  https://lookin.work
//

#import "LayerLens_EventHandlerMaker.h"
#import "LayerLens_Tuple.h"
#import "LayerLens_EventHandler.h"
#import "LayerLens_Object.h"
#import "LayerLens_WeakContainer.h"
#import "LayerLens_IvarTrace.h"
#import "LayerLens_ServerDefines.h"
#import "LayerLens_GestureTargetActionsSearcher.h"
#import "LayerLens_MultiplatformAdapter.h"

@implementation LayerLens_EventHandlerMaker

+ (NSArray<LayerLens_EventHandler *> *)makeForView:(UIView *)view {
    if (!view) {
        return nil;
    }
    
    NSMutableArray<LayerLens_EventHandler *> *allHandlers = nil;
    
    if ([view isKindOfClass:[UIControl class]]) {
        NSArray<LayerLens_EventHandler *> *targetActionHandlers = [self _targetActionHandlersForControl:(UIControl *)view];
        if (targetActionHandlers.count) {
            if (!allHandlers) {
                allHandlers = [NSMutableArray array];
            }
            [allHandlers addObjectsFromArray:targetActionHandlers];
        }
    }
    
    NSArray<LayerLens_EventHandler *> *gestureHandlers = [self _gestureHandlersForView:view];
    if (gestureHandlers.count) {
        if (!allHandlers) {
            allHandlers = [NSMutableArray array];
        }
        [allHandlers addObjectsFromArray:gestureHandlers];
    }
    
    return allHandlers.copy;
}

+ (NSArray<LayerLens_EventHandler *> *)_gestureHandlersForView:(UIView *)view {
    if (view.gestureRecognizers.count == 0) {
        return nil;
    }
    NSArray<LayerLens_EventHandler *> *handlers = [view.gestureRecognizers layerlens_map:^id(NSUInteger idx, __kindof UIGestureRecognizer *recognizer) {
        LayerLens_EventHandler *handler = [LayerLens_EventHandler new];
        handler.handlerType = LayerLens_EventHandlerTypeGesture;
        handler.eventName = NSStringFromClass([recognizer class]);
        
        NSArray<LayerLens_TwoTuple *> *targetActionInfos = [LayerLens_GestureTargetActionsSearcher getTargetActionsFromRecognizer:recognizer];
        handler.targetActions = [targetActionInfos layerlens_map:^id(NSUInteger idx, LayerLens_TwoTuple *rawTuple) {
            NSObject *target = ((LayerLens_WeakContainer *)rawTuple.first).object;
            if (!target) {
                // 该 target 已被释放
                return nil;
            }
            LayerLens_StringTwoTuple *newTuple = [LayerLens_StringTwoTuple new];
            newTuple.first = [LayerLens_Helper descriptionOfObject:target];
            newTuple.second = (NSString *)rawTuple.second;
            return newTuple;
        }];
        handler.inheritedRecognizerName = [self _inheritedRecognizerNameForRecognizer:recognizer];
        handler.gestureRecognizerIsEnabled = recognizer.enabled;
        if (recognizer.delegate) {
            handler.gestureRecognizerDelegator = [LayerLens_Helper descriptionOfObject:recognizer.delegate];
        }
        handler.recognizerIvarTraces = [recognizer.layerlens_ivarTraces layerlens_map:^id(NSUInteger idx, LayerLens_IvarTrace *trace) {
            return [NSString stringWithFormat:@"(%@ *) -> %@", trace.hostClassName, trace.ivarName];
        }];
        
        handler.recognizerOid = [recognizer layerlens_registerOid];
        return handler;
    }];
    return handlers;
}

+ (NSString *)_inheritedRecognizerNameForRecognizer:(UIGestureRecognizer *)recognizer {
    if (!recognizer) {
        NSAssert(NO, @"");
        return nil;
    }
    
    static NSArray<Class> *baseRecognizers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 注意这里 UIScreenEdgePanGestureRecognizer 在 UIPanGestureRecognizer 前面，因为 UIScreenEdgePanGestureRecognizer 继承于 UIPanGestureRecognizer
#if TARGET_OS_TV
        baseRecognizers = @[[UILongPressGestureRecognizer class],
                            [UIPanGestureRecognizer class],
                            [UISwipeGestureRecognizer class],
                            [UITapGestureRecognizer class]];
#elif TARGET_OS_VISION
        baseRecognizers = @[[UILongPressGestureRecognizer class],
                            [UIPanGestureRecognizer class],
                            [UISwipeGestureRecognizer class],
                            [UIRotationGestureRecognizer class],
                            [UIPinchGestureRecognizer class],
                            [UITapGestureRecognizer class]];
#else
        baseRecognizers = @[[UILongPressGestureRecognizer class],
                            [UIScreenEdgePanGestureRecognizer class],
                            [UIPanGestureRecognizer class],
                            [UISwipeGestureRecognizer class],
                            [UIRotationGestureRecognizer class],
                            [UIPinchGestureRecognizer class],
                            [UITapGestureRecognizer class]];
#endif

    });
    
    __block NSString *result = @"UIGestureRecognizer";
    [baseRecognizers enumerateObjectsUsingBlock:^(Class  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if ([recognizer isMemberOfClass:obj]) {
            // 自身就是基本款，则直接置为 nil
            result = nil;
            *stop = YES;
            return;
        }
        if ([recognizer isKindOfClass:obj]) {
            result = NSStringFromClass(obj);
            *stop = YES;
            return;
        }
    }];
    return result;
}

+ (NSArray<LayerLens_EventHandler *> *)_targetActionHandlersForControl:(UIControl *)control {
    static dispatch_once_t onceToken;
    static NSArray<NSNumber *> *allEvents = nil;
    dispatch_once(&onceToken,^{
        allEvents = @[@(UIControlEventTouchDown), @(UIControlEventTouchDownRepeat), @(UIControlEventTouchDragInside), @(UIControlEventTouchDragOutside), @(UIControlEventTouchDragEnter), @(UIControlEventTouchDragExit), @(UIControlEventTouchUpInside), @(UIControlEventTouchUpOutside), @(UIControlEventTouchCancel), @(UIControlEventValueChanged), @(UIControlEventEditingDidBegin), @(UIControlEventEditingChanged), @(UIControlEventEditingDidEnd), @(UIControlEventEditingDidEndOnExit)];
        if (@available(iOS 9.0, *)) {
            allEvents = [allEvents arrayByAddingObject:@(UIControlEventPrimaryActionTriggered)];
        }
    });

    NSSet *allTargets = control.allTargets;
    
    if (!allTargets.count) {
        return nil;
    }
    
    NSMutableArray<LayerLens_EventHandler *> *handlers = [NSMutableArray array];
    
    [allEvents enumerateObjectsUsingBlock:^(NSNumber * _Nonnull eventNum, NSUInteger idx, BOOL * _Nonnull stop) {
        UIControlEvents event = [eventNum unsignedIntegerValue];
        
        NSMutableArray<LayerLens_StringTwoTuple *> *targetActions = [NSMutableArray array];
        
        [allTargets enumerateObjectsUsingBlock:^(id  _Nonnull target, BOOL * _Nonnull stop) {
            NSArray<NSString *> *actions = [control actionsForTarget:target forControlEvent:event];
            [actions enumerateObjectsUsingBlock:^(NSString * _Nonnull action, NSUInteger idx, BOOL * _Nonnull stop) {
                LayerLens_StringTwoTuple *tuple = [LayerLens_StringTwoTuple new];
                tuple.first = [LayerLens_Helper descriptionOfObject:target];
                tuple.second = action;
                [targetActions addObject:tuple];
            }];
        }];
        
        if (targetActions.count) {
            LayerLens_EventHandler *handler = [LayerLens_EventHandler new];
            handler.handlerType = LayerLens_EventHandlerTypeTargetAction;
            handler.eventName = [self _nameFromControlEvent:event];
            handler.targetActions = targetActions.copy;
            [handlers addObject:handler];
        }
    }];
    
    return handlers;
}

+ (NSString *)_nameFromControlEvent:(UIControlEvents)event {
    static dispatch_once_t onceToken;
    static NSDictionary<NSNumber *, NSString *> *eventsAndNames = nil;
    dispatch_once(&onceToken,^{
        NSMutableDictionary<NSNumber *, NSString *> *eventsAndNames_m = @{
            @(UIControlEventTouchDown): @"UIControlEventTouchDown",
            @(UIControlEventTouchDownRepeat): @"UIControlEventTouchDownRepeat",
            @(UIControlEventTouchDragInside): @"UIControlEventTouchDragInside",
            @(UIControlEventTouchDragOutside): @"UIControlEventTouchDragOutside",
            @(UIControlEventTouchDragEnter): @"UIControlEventTouchDragEnter",
            @(UIControlEventTouchDragExit): @"UIControlEventTouchDragExit",
            @(UIControlEventTouchUpInside): @"UIControlEventTouchUpInside",
            @(UIControlEventTouchUpOutside): @"UIControlEventTouchUpOutside",
            @(UIControlEventTouchCancel): @"UIControlEventTouchCancel",
            @(UIControlEventValueChanged): @"UIControlEventValueChanged",
            @(UIControlEventEditingDidBegin): @"UIControlEventEditingDidBegin",
            @(UIControlEventEditingChanged): @"UIControlEventEditingChanged",
            @(UIControlEventEditingDidEnd): @"UIControlEventEditingDidEnd",
            @(UIControlEventEditingDidEndOnExit): @"UIControlEventEditingDidEndOnExit",
        }.mutableCopy;
        if (@available(iOS 9.0, *)) {
            eventsAndNames_m[@(UIControlEventPrimaryActionTriggered)] = @"UIControlEventPrimaryActionTriggered";
        }
        eventsAndNames = eventsAndNames_m.copy;
    });
    
    NSString *name = eventsAndNames[@(event)];
    return name;
}

@end

