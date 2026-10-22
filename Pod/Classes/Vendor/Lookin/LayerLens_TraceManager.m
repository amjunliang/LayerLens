
//
//  LayerLens_TraceManager.m
//  LayerLens_Server
//
//  Created by Li Kai on 2019/5/5.
//  https://lookin.work
//

#import "LayerLens_TraceManager.h"
#import <objc/runtime.h>
#import "LayerLens_IvarTrace.h"
#import "LayerLens_ServerDefines.h"
#import "LayerLens_WeakContainer.h"
#import "LayerLens_MultiplatformAdapter.h"

@interface LayerLens_TraceManager ()

@property(nonatomic, strong) NSMutableArray<LayerLens_WeakContainer *> *searchTargets;

@end

@implementation LayerLens_TraceManager

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    static LayerLens_TraceManager *instance = nil;
    dispatch_once(&onceToken,^{
        instance = [[super allocWithZone:NULL] init];
    });
    return instance;
}

+ (id)allocWithZone:(struct _NSZone *)zone {
    return [self sharedInstance];
}

- (void)addSearchTarger:(id)target {
    if (!target) {
        return;
    }
    if (!self.searchTargets) {
        self.searchTargets = [NSMutableArray array];
    }
    LayerLens_WeakContainer *container = [LayerLens_WeakContainer containerWithObject:target];
    [self.searchTargets addObject:container];
}

- (void)reload {
    // 把旧的先都清理掉
    [NSObject layerlens_clearAllObjectsTraces];
    
    [self.searchTargets enumerateObjectsUsingBlock:^(LayerLens_WeakContainer * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if (!obj.object) {
            return;
        }
        [self _markIVarsInAllClassLevelsOfObject:obj.object];
    }];
    
    [[LayerLens_MultiplatformAdapter allWindows] enumerateObjectsUsingBlock:^(__kindof UIWindow * _Nonnull window, NSUInteger idx, BOOL * _Nonnull stop) {
        [self _addTraceForLayersRootedByLayer:window.layer];
    }];
}

- (void)_addTraceForLayersRootedByLayer:(CALayer *)layer {
    UIView *view = layer.layerlens_hostView;
    
    if ([view.superview layerlens_isChildrenViewOfTabBar]) {
        view.layerlens_isChildrenViewOfTabBar = YES;
    } else if ([view isKindOfClass:[UITabBar class]]) {
        view.layerlens_isChildrenViewOfTabBar = YES;
    }
    
    if (view) {
        [self _markIVarsInAllClassLevelsOfObject:view];
        UIViewController* vc = [view layerlens_findHostViewController];
        if (vc) {
            [self _markIVarsInAllClassLevelsOfObject:vc];
        }
        
        [self _buildSpecialTraceForView:view];
    } else {
        [self _markIVarsInAllClassLevelsOfObject:layer];
    }
    
    [[layer.sublayers copy] enumerateObjectsUsingBlock:^(__kindof CALayer * _Nonnull sublayer, NSUInteger idx, BOOL * _Nonnull stop) {
        [self _addTraceForLayersRootedByLayer:sublayer];
    }];
}

- (void)_buildSpecialTraceForView:(UIView *)view {
    UIViewController* vc = [view layerlens_findHostViewController];
    if (vc) {
        view.layerlens_specialTrace = [NSString stringWithFormat:@"%@.view", NSStringFromClass(vc.class)];
        
    } else if ([view isKindOfClass:[UIWindow class]]) {
        CGFloat currentWindowLevel = ((UIWindow *)view).windowLevel;
        
        if (((UIWindow *)view).isKeyWindow) {
            view.layerlens_specialTrace = [NSString stringWithFormat:@"KeyWindow ( Level: %@ )", @(currentWindowLevel)];
        } else {
            view.layerlens_specialTrace = [NSString stringWithFormat:@"WindowLevel: %@", @(currentWindowLevel)];
        }
    } else if ([view isKindOfClass:[UITableViewCell class]]) {
        ((UITableViewCell *)view).backgroundView.layerlens_specialTrace = @"cell.backgroundView";
        ((UITableViewCell *)view).accessoryView.layerlens_specialTrace = @"cell.accessoryView";
    
    } else if ([view isKindOfClass:[UITableView class]]) {
        UITableView *tableView = (UITableView *)view;
        
        NSMutableArray<NSNumber *> *relatedSectionIdx = [NSMutableArray array];
        [[tableView visibleCells] enumerateObjectsUsingBlock:^(__kindof UITableViewCell * _Nonnull cell, NSUInteger idx, BOOL * _Nonnull stop) {
            NSIndexPath *indexPath = [tableView indexPathForCell:cell];
            cell.layerlens_specialTrace = [NSString stringWithFormat:@"{ sec:%@, row:%@ }", @(indexPath.section), @(indexPath.row)];
            
            if (![relatedSectionIdx containsObject:@(indexPath.section)]) {
                [relatedSectionIdx addObject:@(indexPath.section)];
            }
        }];
        
        [relatedSectionIdx enumerateObjectsUsingBlock:^(NSNumber * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            NSUInteger secIdx = [obj unsignedIntegerValue];
            UIView *secHeaderView = [tableView headerViewForSection:secIdx];
            secHeaderView.layerlens_specialTrace = [NSString stringWithFormat:@"sectionHeader { sec: %@ }", @(secIdx)];
            
            UIView *secFooterView = [tableView footerViewForSection:secIdx];
            secFooterView.layerlens_specialTrace = [NSString stringWithFormat:@"sectionFooter { sec: %@ }", @(secIdx)];
        }];
        
    } else if ([view isKindOfClass:[UICollectionView class]]) {
        UICollectionView *collectionView = (UICollectionView *)view;
        collectionView.backgroundView.layerlens_specialTrace = @"collectionView.backgroundView";
        
        if (@available(iOS 9.0, *)) {
            [[collectionView indexPathsForVisibleSupplementaryElementsOfKind:UICollectionElementKindSectionHeader] enumerateObjectsUsingBlock:^(NSIndexPath * _Nonnull indexPath, NSUInteger idx, BOOL * _Nonnull stop) {
                UIView *headerView = [collectionView supplementaryViewForElementKind:UICollectionElementKindSectionHeader atIndexPath:indexPath];
                headerView.layerlens_specialTrace = [NSString stringWithFormat:@"sectionHeader { sec:%@ }", @(indexPath.section)];
            }];
            [[collectionView indexPathsForVisibleSupplementaryElementsOfKind:UICollectionElementKindSectionFooter] enumerateObjectsUsingBlock:^(NSIndexPath * _Nonnull indexPath, NSUInteger idx, BOOL * _Nonnull stop) {
                UIView *footerView = [collectionView supplementaryViewForElementKind:UICollectionElementKindSectionFooter atIndexPath:indexPath];
                footerView.layerlens_specialTrace = [NSString stringWithFormat:@"sectionFooter { sec:%@ }", @(indexPath.section)];
            }];
        }
        
        [[collectionView visibleCells] enumerateObjectsUsingBlock:^(__kindof UICollectionViewCell * _Nonnull cell, NSUInteger idx, BOOL * _Nonnull stop) {
            NSIndexPath *indexPath = [collectionView indexPathForCell:cell];
            cell.layerlens_specialTrace = [NSString stringWithFormat:@"{ item:%@, sec:%@ }", @(indexPath.item), @(indexPath.section)];
        }];
        
    } else if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *headerFooterView = (UITableViewHeaderFooterView *)view;
        headerFooterView.textLabel.layerlens_specialTrace = @"sectionHeaderFooter.textLabel";
        headerFooterView.detailTextLabel.layerlens_specialTrace = @"sectionHeaderFooter.detailTextLabel";
    }
}

- (void)_markIVarsInAllClassLevelsOfObject:(NSObject *)object {
    [self _markIVarsOfObject:object class:object.class];
}

- (void)_markIVarsOfObject:(NSObject *)hostObject class:(Class)targetClass {
    if (!targetClass) {
        return;
    }

    NSArray<NSString *> *prefixesToTerminateRecursion = @[@"NSObject", @"UIResponder", @"UIButton", @"UIButtonLabel"];
    BOOL hasPrefix = [prefixesToTerminateRecursion layerlens_any:^BOOL(NSString *prefix) {
        return [NSStringFromClass(targetClass) hasPrefix:prefix];
    }];
    if (hasPrefix) {
        return;
    }
    
    unsigned int outCount = 0;
    Ivar *ivars = class_copyIvarList(targetClass, &outCount);
    for (unsigned int i = 0; i < outCount; i ++) {
        Ivar ivar = ivars[i];
        NSString *ivarType = [[NSString alloc] layerlens_safeInitWithUTF8String:ivar_getTypeEncoding(ivar)];
        if (![ivarType hasPrefix:@"@"] || ivarType.length <= 3) {
            continue;
        }
        NSString *ivarClassName = [ivarType substringWithRange:NSMakeRange(2, ivarType.length - 3)];
        Class ivarClass = NSClassFromString(ivarClassName);
        if (![ivarClass isSubclassOfClass:[UIView class]]
            && ![ivarClass isSubclassOfClass:[CALayer class]]
            && ![ivarClass isSubclassOfClass:[UIViewController class]]
            && ![ivarClass isSubclassOfClass:[UIGestureRecognizer class]]) {
            continue;
        }
        const char * ivarNameChar = ivar_getName(ivar);
        if (!ivarNameChar) {
            continue;
        }
        // 这个 ivarObject 可能的类型：UIView, CALayer, UIViewController, UIGestureRecognizer
        NSObject *ivarObject = object_getIvar(hostObject, ivar);
        if (!ivarObject || ![ivarObject isKindOfClass:[NSObject class]]) {
            continue;
        }

        LayerLens_IvarTrace *ivarTrace = [LayerLens_IvarTrace new];
        ivarTrace.hostObject = hostObject;
        ivarTrace.hostClassName = [self makeDisplayClassNameWithSuper:targetClass childClass:hostObject.class];
        ivarTrace.ivarName = [[NSString alloc] layerlens_safeInitWithUTF8String:ivarNameChar];
        
        if (hostObject == ivarObject) {
            ivarTrace.relation = LayerLens_IvarTraceRelationValue_Self;
        } else if ([hostObject isKindOfClass:[UIView class]]) {
            CALayer *ivarLayer = nil;
            if ([ivarObject isKindOfClass:[CALayer class]]) {
                ivarLayer = (CALayer *)ivarObject;
            } else if ([ivarObject isKindOfClass:[UIView class]]) {
                ivarLayer = ((UIView *)ivarObject).layer;
            }
            if (ivarLayer && (ivarLayer.superlayer == ((UIView *)hostObject).layer)) {
                ivarTrace.relation = @"superview";
            }
        }

        if ([LayerLens_InvalidIvarTraces() containsObject:ivarTrace]) {
            continue;
        }
        
        if (![ivarObject respondsToSelector:@selector(layerlens_ivarTraces)] || ![ivarObject respondsToSelector:@selector(setLayerlens_ivarTraces:)]) {
            continue;
        }
        if (!ivarObject.layerlens_ivarTraces) {
            ivarObject.layerlens_ivarTraces = [NSArray array];
        }
        if (![ivarObject.layerlens_ivarTraces containsObject:ivarTrace]) {
            ivarObject.layerlens_ivarTraces = [ivarObject.layerlens_ivarTraces arrayByAddingObject:ivarTrace];
        }
    }
    free(ivars);
    
    Class superClass = [targetClass superclass];
    [self _markIVarsOfObject:hostObject class:superClass];
}

// 比如 superClass 可能是 UIView，而 childClass 可能是 UIButton
- (NSString *)makeDisplayClassNameWithSuper:(Class)superClass childClass:(Class)childClass {
    NSString *superName = NSStringFromClass(superClass);
    if (!childClass) {
        return superName;
    }
    NSString *childName = NSStringFromClass(childClass);
    if ([childName isEqualToString:superName]) {
        return superName;
    }
    return [NSString stringWithFormat:@"%@ : %@", childName, superName];
}

static NSSet<LayerLens_IvarTrace *> *LayerLens_InvalidIvarTraces(void) {
    static NSSet *list;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableSet *set = [NSMutableSet set];
        
        [set addObject:({
            LayerLens_IvarTrace *trace = [LayerLens_IvarTrace new];
            trace.hostClassName = @"UIView";
            trace.ivarName = @"_window";
            trace;
        })];
        [set addObject:({
            LayerLens_IvarTrace *trace = [LayerLens_IvarTrace new];
            trace.hostClassName = @"UIViewController";
            trace.ivarName = @"_view";
            trace;
        })];
        [set addObject:({
            LayerLens_IvarTrace *trace = [LayerLens_IvarTrace new];
            trace.hostClassName = @"UIView";
            trace.ivarName = @"_viewDelegate";
            trace;
        })];
        [set addObject:({
            LayerLens_IvarTrace *trace = [LayerLens_IvarTrace new];
            trace.hostClassName = @"UIViewController";
            trace.ivarName = @"_parentViewController";
            trace;
        })];
        list = set.copy;
    });
    return list;
}

@end

