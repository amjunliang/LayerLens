//
//  LayerLensLookinSerializer.m
//  LayerLens
//
//  Created by YueYou on 10/12/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LayerLensLookinSerializer.h"
#import "LayerLens_DisplayItem.h"
#import "LayerLens_Object.h"
#import "LayerLens_IvarTrace.h"
#import "LayerLens_AttributesGroup.h"
#import "LayerLens_AttributesSection.h"
#import "LayerLens_Attribute.h"
#import "LayerLens_DashboardBlueprint.h"
#import "LayerLens_EventHandler.h"
#import "LayerLens_Tuple.h"
#import "NSObject+LayerLens_Server.h"
#import "CALayer+LayerLens_Server.h"

#if DEBUG
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static BOOL LayerLensIsSwiftUIHost(UIView *view) {
    for (Class cls = view.class; cls && cls != UIView.class; cls = class_getSuperclass(cls)) {
        NSString *name = NSStringFromClass(cls);
        if ([name hasPrefix:@"SwiftUI._UIHostingView"] ||
            [name hasPrefix:@"_TtGC7SwiftUI14_UIHostingView"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL LayerLensIsInSwiftUIHost(UIView *view) {
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if (LayerLensIsSwiftUIHost(ancestor)) return YES;
    }
    return NO;
}

#endif

@implementation LayerLensLookinSerializer

#pragma mark - Node

#if DEBUG
+ (void)enableSwiftUIAccessibility {
    // ViewMonitor uses this automation switch to expose SwiftUI elements without an AX client.
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_LAZY | RTLD_LOCAL);
        if (!handle) return;
        void (*setAutomationEnabled)(BOOL) = dlsym(handle, "_AXSSetAutomationEnabled");
        if (setAutomationEnabled) setAutomationEnabled(YES);
    });
}

+ (void)collectSwiftUINodesFrom:(NSObject *)container
                        window:(UIWindow *)window
                          clip:(CGRect)clip
                    parentRect:(CGRect)parentRect
                       visited:(NSHashTable *)visited
                         depth:(NSUInteger)depth
                      children:(NSMutableArray<NSDictionary *> *)children {
    if (depth >= 64 || visited.count >= 4096 || [visited containsObject:container]) return;
    [visited addObject:container];

    // Native views already have nodes in the layer hierarchy.
    if (![container isKindOfClass:UIView.class] && container.isAccessibilityElement) {
        CGRect localRect = [window convertRect:container.accessibilityFrame fromCoordinateSpace:window.screen.coordinateSpace];
        if (isfinite(localRect.origin.x) && isfinite(localRect.origin.y) &&
            isfinite(localRect.size.width) && isfinite(localRect.size.height)) {
            CGRect visibleRect = CGRectIntersection(localRect, clip);
            if (!CGRectIsEmpty(visibleRect)) {
                CGRect rect = CGRectOffset(visibleRect, window.frame.origin.x, window.frame.origin.y);
                NSString *label = container.accessibilityLabel;
                NSString *identifier = [container respondsToSelector:@selector(accessibilityIdentifier)]
                    ? [(id<UIAccessibilityIdentification>)container accessibilityIdentifier] : nil;
                [children addObject:[@{
                    @"oid": @0, @"viewOid": NSNull.null,
                    @"classChain": @[@"SwiftUI"], @"address": @"", @"isLayer": @NO,
                    @"vcClass": NSNull.null, @"vcOid": NSNull.null, @"ivarTraces": @[],
                    @"specialTrace": NSNull.null,
                    @"title": label.length ? label : (identifier.length ? identifier : @"SwiftUI"),
                    @"text": label.length ? label : NSNull.null,
                    @"identifier": identifier.length ? identifier : NSNull.null,
                    @"frame": [self arrayFromRect:CGRectOffset(rect, -parentRect.origin.x, -parentRect.origin.y)],
                    @"rect": [self arrayFromRect:rect], @"hidden": @NO, @"alpha": @1,
                    @"keyWindow": @NO, @"children": @[],
                } mutableCopy]];
            }
        }
    }

    NSArray *elements = container.accessibilityElements;
    NSInteger count = elements ? (NSInteger)elements.count : container.accessibilityElementCount;
    if (count == NSNotFound) return;
    for (NSInteger index = 0; index < MIN(count, 4096); index++) {
        if (visited.count >= 4096) break;
        id element = elements ? elements[index] : [container accessibilityElementAtIndex:index];
        if ([element isKindOfClass:NSObject.class] && ![element isKindOfClass:UIView.class]) {
            [self collectSwiftUINodesFrom:element window:window clip:clip parentRect:parentRect
                                 visited:visited depth:depth + 1 children:children];
        }
    }
}

+ (void)appendSwiftUINodesForView:(UIView *)view rect:(CGRect)rect children:(NSMutableArray<NSDictionary *> *)children {
    UIWindow *window = view.window;
    if (!window || !LayerLensIsInSwiftUIHost(view)) return;
    CGRect clip = window.bounds;
    for (UIView *ancestor = view; ancestor && ancestor != window; ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha < 0.01) return;
        if (ancestor == view || ancestor.clipsToBounds) {
            clip = CGRectIntersection(clip, [ancestor convertRect:ancestor.bounds toView:window]);
        }
    }
    if (CGRectIsEmpty(clip)) return;

    NSHashTable *visited = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    [self collectSwiftUINodesFrom:view window:window clip:clip parentRect:rect
                         visited:visited depth:0 children:children];
}

static NSDictionary *LayerLensLayoutProperties(NSDictionary *node) {
    NSMutableDictionary *properties = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in node[@"properties"]) {
        properties[entry[@"id"]] = entry[@"attribute"];
    }
    return properties;
}

static BOOL LayerLensReadLayoutPair(id value, CGFloat *x, CGFloat *y) {
    if (![value isKindOfClass:NSArray.class] || [value count] != 2 ||
        ![value[0] isKindOfClass:NSNumber.class] || ![value[1] isKindOfClass:NSNumber.class]) return NO;
    *x = [value[0] doubleValue];
    *y = [value[1] doubleValue];
    return isfinite(*x) && isfinite(*y);
}

// Text storage may be localized or formatted. Only a literal key or verbatim
// string is safe to compare with the text exposed on screen.
static NSString *LayerLensDebugText(id attribute, NSUInteger depth) {
    if (depth > 24 || ![attribute isKindOfClass:NSDictionary.class]) return nil;
    NSString *name = attribute[@"name"];
    id value = attribute[@"value"];
    if (([name isEqualToString:@"key"] || [name isEqualToString:@"verbatim"]) &&
        [value isKindOfClass:NSString.class] && [value length]) return value;
    for (id child in attribute[@"subattributes"]) {
        NSString *text = LayerLensDebugText(child, depth + 1);
        if (text) return text;
    }
    return nil;
}

static NSString *LayerLensNormalizedText(NSString *text) {
    NSArray *parts = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                      filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    return [parts componentsJoinedByString:@" "];
}

+ (NSUInteger)associateDebugTree:(NSArray *)tree withHost:(UIView *)host node:(NSDictionary *)hostNode scrollContent:(BOOL)scrollContent {
    UIWindow *window = host.window;
    if (!window) return 0;
    NSMutableArray *candidates = [NSMutableArray array];
    NSMutableArray *pending = [NSMutableArray array];
    for (NSDictionary *node in tree) [pending addObject:@{@"node": node, @"context": scrollContent ? @[@"ScrollView"] : @[]}];
    for (NSUInteger i = 0; i < pending.count && i < 20000; i++) {
        NSDictionary *item = pending[i], *node = item[@"node"];
        NSDictionary *properties = LayerLensLayoutProperties(node);
        NSString *type = properties[@0][@"readableType"];
        // Scroll coordinates require a separate physical-container mapping.
        if ([type hasPrefix:@"SystemScrollView<"]) continue;
        NSArray *context = item[@"context"];
        NSString *kind = nil;
        if ([type hasPrefix:@"Label<"]) kind = @"Label";
        else if ([type hasPrefix:@"HStack<"]) kind = @"HStack";
        else if ([type hasPrefix:@"VStack<"]) kind = @"VStack";
        if (kind && ![context.lastObject isEqualToString:kind]) {
            context = [context arrayByAddingObject:kind];
            NSUInteger limit = scrollContent ? 5 : 4;
            if (context.count > limit) {
                NSArray *tail = [context subarrayWithRange:NSMakeRange(context.count - 4, 4)];
                context = scrollContent ? [@[@"ScrollView"] arrayByAddingObjectsFromArray:tail] : tail;
            }
        }
        for (NSDictionary *child in node[@"children"]) {
            [pending addObject:@{@"node": child, @"context": context}];
        }
        if (![type isEqualToString:@"Text"]) continue;
        CGFloat x, y, width, height;
        NSString *text = LayerLensDebugText(properties[@1], 0);
        if (!text.length || !LayerLensReadLayoutPair(properties[@3][@"value"], &x, &y) ||
            !LayerLensReadLayoutPair(properties[@4][@"value"], &width, &height) ||
            width <= 0 || height <= 0) continue;
        CGRect rect = [host convertRect:CGRectMake(x, y, width, height) toView:window];
        rect = CGRectOffset(rect, window.frame.origin.x, window.frame.origin.y);
        NSUInteger labelIndex = [context indexOfObject:@"Label"];
        if (labelIndex != NSNotFound) context = scrollContent ? @[@"ScrollView", @"Label"] : @[@"Label"];
        [candidates addObject:@{@"text": LayerLensNormalizedText(text),
                                @"rect": [self arrayFromRect:rect],
                                @"context": [context arrayByAddingObject:@"Text"]}];
    }

    NSMutableArray *axNodes = [NSMutableArray array];
    NSMutableArray *views = [NSMutableArray arrayWithArray:hostNode[@"children"] ?: @[]];
    SEL capture = NSSelectorFromString(@"makeViewDebugData");
    for (NSUInteger i = 0; i < views.count; i++) {
        NSMutableDictionary *node = views[i];
        CALayer *layer = (CALayer *)[NSObject layerlens_objectWithOid:[node[@"oid"] unsignedLongValue]];
        if ([layer isKindOfClass:CALayer.class] && [layer.layerlens_hostView respondsToSelector:capture]) continue;
        if ([node[@"classChain"] isEqual:@[@"SwiftUI"]] && [node[@"text"] isKindOfClass:NSString.class]) {
            [axNodes addObject:node];
        }
        [views addObjectsFromArray:node[@"children"] ?: @[]];
    }
    NSUInteger matched = 0;
    for (NSMutableDictionary *ax in axNodes) {
        NSArray *coords = ax[@"rect"];
        if (coords.count != 4) continue;
        CGRect axRect = CGRectMake([coords[0] doubleValue], [coords[1] doubleValue],
                                   [coords[2] doubleValue], [coords[3] doubleValue]);
        NSString *text = LayerLensNormalizedText(ax[@"text"]);
        NSDictionary *match = nil;
        for (NSDictionary *candidate in candidates) {
            if (![candidate[@"text"] isEqualToString:text]) continue;
            NSArray *r = candidate[@"rect"];
            CGRect rect = CGRectMake([r[0] doubleValue], [r[1] doubleValue], [r[2] doubleValue], [r[3] doubleValue]);
            CGRect overlap = CGRectIntersection(rect, axRect);
            if (CGRectIsNull(overlap) || overlap.size.width * overlap.size.height < rect.size.width * rect.size.height * 0.9) continue;
            if (match) { match = nil; break; }
            match = candidate;
        }
        NSUInteger matchingAX = 0;
        if (match) {
            NSArray *r = match[@"rect"];
            CGRect rect = CGRectMake([r[0] doubleValue], [r[1] doubleValue], [r[2] doubleValue], [r[3] doubleValue]);
            for (NSDictionary *other in axNodes) {
                if (![LayerLensNormalizedText(other[@"text"]) isEqualToString:text]) continue;
                NSArray *values = other[@"rect"];
                if (values.count != 4) continue;
                CGRect otherRect = CGRectMake([values[0] doubleValue], [values[1] doubleValue], [values[2] doubleValue], [values[3] doubleValue]);
                CGRect overlap = CGRectIntersection(rect, otherRect);
                if (!CGRectIsNull(overlap) && overlap.size.width * overlap.size.height >= rect.size.width * rect.size.height * 0.9) matchingAX++;
            }
        }
        if (match && matchingAX == 1) {
            ax[@"swiftUIContext"] = match[@"context"];
            matched++;
        }
    }
    return matched;
}

// A physical scroll content view and its logical root share a size. Skip
// ambiguous matches instead of placing a node in the wrong coordinate space.
static NSDictionary *LayerLensFindScrollLayout(NSArray *tree, CGSize size) {
    NSMutableArray *pending = [tree mutableCopy];
    NSDictionary *match = nil;
    for (NSUInteger index = 0; index < pending.count && index < 20000; index++) {
        NSDictionary *node = pending[index];
        NSDictionary *properties = LayerLensLayoutProperties(node);
        CGFloat width, height;
        if ([node[@"children"] count] &&
            LayerLensReadLayoutPair(properties[@4][@"value"], &width, &height) &&
            fabs(width - size.width) < 0.5 && fabs(height - size.height) < 0.5) {
            if (match) return nil;
            match = node;
        } else if (node[@"children"]) {
            [pending addObjectsFromArray:node[@"children"]];
        }
    }
    return match;
}

// A geometry wrapper can have the same size as the scroll content. Descend
// through a unique scroll view before resolving the inner coordinate space.
static NSDictionary *LayerLensScrollContentRoot(NSDictionary *root, CGSize size) {
    NSMutableArray *pending = [NSMutableArray arrayWithArray:root[@"children"] ?: @[]];
    NSDictionary *scroll = nil;
    for (NSUInteger i = 0; i < pending.count && i < 20000; i++) {
        NSDictionary *node = pending[i];
        NSString *type = LayerLensLayoutProperties(node)[@0][@"readableType"];
        if ([type hasPrefix:@"SystemScrollView<"]) {
            if (scroll) return nil;
            scroll = node;
        } else {
            [pending addObjectsFromArray:node[@"children"] ?: @[]];
        }
    }
    return scroll ? LayerLensFindScrollLayout(scroll[@"children"] ?: @[], size) : root;
}

+ (NSArray *)layoutNodesInScrollContent:(UIView *)view tree:(NSArray *)tree {
    UIScrollView *scroll = (UIScrollView *)view.superview;
    UIWindow *window = view.window;
    if (!window || ![scroll isKindOfClass:UIScrollView.class]) return @[];
    NSDictionary *root = LayerLensFindScrollLayout(tree, view.bounds.size);
    if (!root) return @[];
    CGRect clip = window.bounds;
    for (UIView *ancestor = view; ancestor && ancestor != window; ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha < 0.01) return @[];
        if (ancestor == view || ancestor == scroll || ancestor.clipsToBounds) {
            clip = CGRectIntersection(clip, [ancestor convertRect:ancestor.bounds toView:window]);
        }
    }
    if (CGRectIsEmpty(clip)) return @[];

    NSMutableArray *result = [NSMutableArray array];
    NSMutableArray *pending = [NSMutableArray arrayWithArray:root[@"children"]];
    for (NSUInteger index = 0; index < pending.count && index < 20000; index++) {
        NSDictionary *node = pending[index];
        NSDictionary *properties = LayerLensLayoutProperties(node);
        NSString *type = properties[@0][@"readableType"];
        if ([type hasPrefix:@"SystemScrollView<"] || properties[@2][@"value"]) continue;
        if (node[@"children"]) [pending addObjectsFromArray:node[@"children"]];
        // Keep layout wrappers out of hit testing. Prefer AX for semantic controls.
        if (![type hasPrefix:@"_ShapeView<"]) continue;
        CGFloat x, y, width, height;
        if (!LayerLensReadLayoutPair(properties[@3][@"value"], &x, &y) ||
            !LayerLensReadLayoutPair(properties[@4][@"value"], &width, &height) ||
            width <= 0 || height <= 0) continue;
        CGRect local = CGRectMake(x, y, width, height);
        CGRect visible = CGRectIntersection(clip, [view convertRect:local toView:window]);
        if (CGRectIsEmpty(visible)) continue;
        CGRect rect = CGRectOffset(visible, window.frame.origin.x, window.frame.origin.y);
        [result addObject:@{
            @"oid": @0, @"viewOid": NSNull.null, @"classChain": @[type],
            @"title": type, @"isLayer": @NO, @"address": @"", @"ivarTraces": @[],
            @"frame": [self arrayFromRect:local], @"rect": [self arrayFromRect:rect],
            @"hidden": @NO, @"alpha": @1, @"children": @[], @"swiftUILayout": @YES,
        }];
    }
    return result;
}

+ (NSUInteger)appendSwiftUILayoutToRoots:(NSArray<NSDictionary *> *)roots {
    SEL capture = NSSelectorFromString(@"makeViewDebugData");
    NSMapTable<UIView *, NSArray *> *trees = [NSMapTable strongToStrongObjectsMapTable];
    NSMutableArray *pending = [roots mutableCopy];
    NSUInteger count = 0;
    for (NSUInteger index = 0; index < pending.count; index++) {
        NSMutableDictionary *node = pending[index];
        NSMutableArray *children = node[@"children"];
        [pending addObjectsFromArray:children];
        NSString *type = [node[@"classChain"] firstObject];
        CALayer *hostLayer = (CALayer *)[NSObject layerlens_objectWithOid:[node[@"oid"] unsignedLongValue]];
        UIView *possibleHost = [hostLayer isKindOfClass:CALayer.class] ? hostLayer.layerlens_hostView : nil;
        if (possibleHost && [possibleHost respondsToSelector:capture] && ![trees objectForKey:possibleHost]) {
            NSMethodSignature *signature = [possibleHost methodSignatureForSelector:capture];
            if (signature && signature.numberOfArguments == 2 && signature.methodReturnType[0] == '@') {
                id data = ((id (*)(id, SEL))objc_msgSend)(possibleHost, capture);
                id json = [data isKindOfClass:NSData.class] ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
                NSArray *tree = [json isKindOfClass:NSArray.class] ? json : @[];
                [trees setObject:tree forKey:possibleHost];
                count += [self associateDebugTree:tree withHost:possibleHost node:node scrollContent:NO];
            }
        }
        if (![type containsString:@"HostingScrollView"] || ![type containsString:@"PlatformGroupContainer"]) continue;
        CALayer *layer = (CALayer *)[NSObject layerlens_objectWithOid:[node[@"oid"] unsignedLongValue]];
        if (![layer isKindOfClass:CALayer.class]) continue;
        UIView *view = layer.layerlens_hostView;
        UIView *host = view.superview;
        while (host && ![host respondsToSelector:capture]) host = host.superview;
        if (!host) continue;
        NSArray *tree = [trees objectForKey:host];
        if (!tree) {
            NSMethodSignature *signature = [host methodSignatureForSelector:capture];
            if (!signature || signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') continue;
            id data = ((id (*)(id, SEL))objc_msgSend)(host, capture);
            id json = [data isKindOfClass:NSData.class] ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            tree = [json isKindOfClass:NSArray.class] ? json : @[];
            [trees setObject:tree forKey:host];
        }
        NSArray *shapes = [self layoutNodesInScrollContent:view tree:tree];
        NSDictionary *scrollRoot = LayerLensFindScrollLayout(tree, view.bounds.size);
        if (scrollRoot) {
            scrollRoot = LayerLensScrollContentRoot(scrollRoot, view.bounds.size);
        }
        if (scrollRoot) {
            count += [self associateDebugTree:scrollRoot[@"children"] ?: @[] withHost:view node:node scrollContent:YES];
        }
        // AX controls with overlapping bounds retain priority.
        [children insertObjects:shapes atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, shapes.count)]];
        count += shapes.count;
    }
    return count;
}
#endif

+ (NSDictionary *)nodeFromDisplayItem:(LayerLens_DisplayItem *)item parentRect:(CGRect)parentRect {
    LayerLens_Object *displayObject = item.viewObject ?: item.layerObject;
    CALayer *layer = item.layerObject ? (CALayer *)[NSObject layerlens_objectWithOid:item.layerObject.oid] : nil;

    CGRect rect = CGRectZero;
    if ([layer isKindOfClass:CALayer.class]) {
        rect = [self screenRectOfLayer:layer];
    } else {
        // 自定义节点(如 SwiftUI)没有 layer, frame 相对父节点
        rect = CGRectOffset(item.frame, parentRect.origin.x, parentRect.origin.y);
    }

    NSMutableArray<NSDictionary *> *children = [NSMutableArray arrayWithCapacity:item.subitems.count];
    for (LayerLens_DisplayItem *subitem in item.subitems) {
        [children addObject:[self nodeFromDisplayItem:subitem parentRect:rect]];
    }
#if DEBUG
    if (item.viewObject && [layer isKindOfClass:CALayer.class]) {
        [self appendSwiftUINodesForView:layer.layerlens_hostView rect:rect children:children];
    }
#endif

    NSMutableArray<NSString *> *traces = [NSMutableArray array];
    for (LayerLens_IvarTrace *trace in displayObject.ivarTraces) {
        [traces addObject:[NSString stringWithFormat:@"%@.%@", trace.hostClassName ?: @"?", trace.ivarName ?: @"?"]];
    }

    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    node[@"oid"] = @(item.layerObject.oid);
    node[@"viewOid"] = item.viewObject ? @(item.viewObject.oid) : [NSNull null];
    node[@"classChain"] = displayObject.classChainList ?: @[item.customDisplayTitle ?: @"Unknown"];
    node[@"address"] = displayObject.memoryAddress ?: @"";
    node[@"isLayer"] = @(item.viewObject == nil && item.layerObject != nil);
    node[@"vcClass"] = item.hostViewControllerObject.classChainList.firstObject ?: [NSNull null];
    node[@"vcOid"] = item.hostViewControllerObject ? @(item.hostViewControllerObject.oid) : [NSNull null];
    node[@"ivarTraces"] = traces;
    node[@"specialTrace"] = displayObject.specialTrace ?: [NSNull null];
    node[@"title"] = item.customDisplayTitle ?: [NSNull null];
    node[@"text"] = [self displayTextOfView:[layer isKindOfClass:CALayer.class] ? layer.layerlens_hostView : nil] ?: [NSNull null];
    NSObject *viewObject = item.viewObject ? [NSObject layerlens_objectWithOid:item.viewObject.oid] : nil;
    NSString *identifier = [viewObject isKindOfClass:UIView.class] ? ((UIView *)viewObject).accessibilityIdentifier : nil;
    node[@"identifier"] = identifier.length ? identifier : [NSNull null];
    node[@"frame"] = [self arrayFromRect:item.frame];
    node[@"rect"] = [self arrayFromRect:rect];
    node[@"hidden"] = @(item.isHidden);
    node[@"alpha"] = [self safeNumber:item.alpha];
    node[@"keyWindow"] = @(item.representedAsKeyWindow);
    // 手势与 UIControl 事件, 树中据此显示事件标记
    if (item.eventHandlers.count) {
        node[@"events"] = [self eventHandlersFromHandlers:item.eventHandlers];
    }
    node[@"children"] = children;
    return node;
}

/// 控件上显示的文字, 便于按字符串搜索源码
+ (NSString *)displayTextOfView:(UIView *)view {
    NSString *text = nil;
    if ([view isKindOfClass:UILabel.class]) {
        text = ((UILabel *)view).text;
    } else if ([view isKindOfClass:UIButton.class]) {
        text = ((UIButton *)view).currentTitle;
    } else if ([view isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)view;
        text = field.text.length > 0 ? field.text : field.placeholder;
    } else if ([view isKindOfClass:UITextView.class]) {
        text = ((UITextView *)view).text;
    }
    if (text.length == 0) {
        return nil;
    }
    return text.length > 40 ? [[text substringToIndex:40] stringByAppendingString:@"..."] : text;
}

+ (CGRect)screenRectOfLayer:(CALayer *)layer {
    UIWindow *window = layer.layerlens_window;
    if (!window) {
        return layer.frame;
    }
    if (layer == window.layer) {
        return window.frame;
    }
    CGRect rect = [layer convertRect:layer.bounds toLayer:window.layer];
    return CGRectOffset(rect, window.frame.origin.x, window.frame.origin.y);
}

#pragma mark - Attribute

+ (NSArray<NSDictionary *> *)attrGroupsFromGroups:(NSArray<LayerLens_AttributesGroup *> *)groups custom:(BOOL)custom {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:groups.count];
    for (LayerLens_AttributesGroup *group in groups) {
        NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];
        for (LayerLens_AttributesSection *section in group.attrSections) {
            NSMutableArray<NSDictionary *> *attrs = [NSMutableArray array];
            for (LayerLens_Attribute *attr in section.attributes) {
                [attrs addObject:[self attrFromAttribute:attr custom:custom]];
            }
            NSString *sectionTitle = custom ? nil : [LayerLens_DashboardBlueprint sectionTitleWithSectionID:section.identifier];
            [sections addObject:@{
                @"id": section.identifier ?: @"",
                @"title": sectionTitle ?: [NSNull null],
                @"attrs": attrs,
            }];
        }
        NSString *title = group.userCustomTitle ?: [LayerLens_DashboardBlueprint groupTitleWithGroupID:group.identifier];
        [result addObject:@{
            @"id": group.identifier ?: @"",
            @"title": title ?: group.identifier ?: @"",
            @"custom": @(custom),
            @"sections": sections,
        }];
    }
    return result;
}

+ (NSDictionary *)attrFromAttribute:(LayerLens_Attribute *)attr custom:(BOOL)custom {
    NSString *title = attr.displayTitle;
    NSString *enumList = nil;
    BOOL editable = NO;
    if (!custom) {
        title = [LayerLens_DashboardBlueprint briefTitleWithAttrID:attr.identifier] ?: title;
        enumList = [LayerLens_DashboardBlueprint enumListNameWithAttrID:attr.identifier];
        editable = [LayerLens_DashboardBlueprint setterWithAttrID:attr.identifier] != nil && [self isEditableAttrType:attr.attrType];
    }
    return @{
        @"id": attr.identifier ?: @"",
        @"title": title ?: attr.identifier ?: @"",
        @"type": @(attr.attrType),
        @"value": [self JSONValueFromValue:attr.value attrType:attr.attrType],
        @"editable": @(editable),
        @"enumList": enumList ?: [NSNull null],
    };
}

+ (NSArray<NSDictionary *> *)eventHandlersFromHandlers:(NSArray<LayerLens_EventHandler *> *)handlers {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:handlers.count];
    for (LayerLens_EventHandler *handler in handlers) {
        NSMutableArray<NSArray<NSString *> *> *targetActions = [NSMutableArray array];
        for (LayerLens_StringTwoTuple *tuple in handler.targetActions) {
            [targetActions addObject:@[tuple.first ?: @"", tuple.second ?: @""]];
        }
        [result addObject:@{
            @"type": handler.handlerType == LayerLens_EventHandlerTypeGesture ? @"gesture" : @"targetAction",
            @"oid": @(handler.recognizerOid),
            @"name": handler.eventName ?: @"",
            @"inherited": handler.inheritedRecognizerName ?: [NSNull null],
            @"enabled": @(handler.gestureRecognizerIsEnabled),
            @"delegate": handler.gestureRecognizerDelegator ?: [NSNull null],
            @"ivarTraces": handler.recognizerIvarTraces ?: @[],
            @"targetActions": targetActions,
        }];
    }
    return result;
}

#pragma mark - Value

+ (BOOL)isEditableAttrType:(LayerLens_AttrType)attrType {
    switch (attrType) {
        case LayerLens_AttrTypeChar:
        case LayerLens_AttrTypeInt:
        case LayerLens_AttrTypeShort:
        case LayerLens_AttrTypeLong:
        case LayerLens_AttrTypeLongLong:
        case LayerLens_AttrTypeUnsignedChar:
        case LayerLens_AttrTypeUnsignedInt:
        case LayerLens_AttrTypeUnsignedShort:
        case LayerLens_AttrTypeUnsignedLong:
        case LayerLens_AttrTypeUnsignedLongLong:
        case LayerLens_AttrTypeFloat:
        case LayerLens_AttrTypeDouble:
        case LayerLens_AttrTypeBOOL:
        case LayerLens_AttrTypeEnumInt:
        case LayerLens_AttrTypeEnumLong:
        case LayerLens_AttrTypeCGPoint:
        case LayerLens_AttrTypeCGVector:
        case LayerLens_AttrTypeCGSize:
        case LayerLens_AttrTypeCGRect:
        case LayerLens_AttrTypeCGAffineTransform:
        case LayerLens_AttrTypeUIEdgeInsets:
        case LayerLens_AttrTypeUIOffset:
        case LayerLens_AttrTypeNSString:
        case LayerLens_AttrTypeUIColor:
            return YES;
        default:
            return NO;
    }
}

+ (id)JSONValueFromValue:(id)value attrType:(LayerLens_AttrType)attrType {
    if (!value || value == [NSNull null]) {
        return [NSNull null];
    }
    if ([value isKindOfClass:NSValue.class] && ![value isKindOfClass:NSNumber.class]) {
        NSValue *v = value;
        switch (attrType) {
            case LayerLens_AttrTypeCGPoint: {
                CGPoint p = v.CGPointValue;
                return @[[self safeNumber:p.x], [self safeNumber:p.y]];
            }
            case LayerLens_AttrTypeCGVector: {
                CGVector p = v.CGVectorValue;
                return @[[self safeNumber:p.dx], [self safeNumber:p.dy]];
            }
            case LayerLens_AttrTypeCGSize: {
                CGSize s = v.CGSizeValue;
                return @[[self safeNumber:s.width], [self safeNumber:s.height]];
            }
            case LayerLens_AttrTypeCGRect:
                return [self arrayFromRect:v.CGRectValue];
            case LayerLens_AttrTypeCGAffineTransform: {
                CGAffineTransform t = v.CGAffineTransformValue;
                return @[[self safeNumber:t.a], [self safeNumber:t.b], [self safeNumber:t.c], [self safeNumber:t.d], [self safeNumber:t.tx], [self safeNumber:t.ty]];
            }
            case LayerLens_AttrTypeUIEdgeInsets: {
                UIEdgeInsets i = v.UIEdgeInsetsValue;
                return @[[self safeNumber:i.top], [self safeNumber:i.left], [self safeNumber:i.bottom], [self safeNumber:i.right]];
            }
            case LayerLens_AttrTypeUIOffset: {
                UIOffset o = v.UIOffsetValue;
                return @[[self safeNumber:o.horizontal], [self safeNumber:o.vertical]];
            }
            default:
                return v.description ?: @"";
        }
    }
    if ([value isKindOfClass:NSNumber.class]) {
        return [self sanitizeNumber:value];
    }
    if ([value isKindOfClass:NSString.class]) {
        return value;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *array = [NSMutableArray arrayWithCapacity:[value count]];
        for (id obj in value) {
            [array addObject:[self JSONValueFromValue:obj attrType:LayerLens_AttrTypeNone]];
        }
        return array;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            dict[[key description]] = [self JSONValueFromValue:obj attrType:LayerLens_AttrTypeNone];
        }];
        return dict;
    }
    if ([value isKindOfClass:UIColor.class]) {
        CGFloat r = 0, g = 0, b = 0, a = 0;
        [(UIColor *)value getRed:&r green:&g blue:&b alpha:&a];
        return @[@(r), @(g), @(b), @(a)];
    }
    return [value description] ?: @"";
}

+ (id)modificationValueFromJSONValue:(id)value attrType:(LayerLens_AttrType)attrType supported:(BOOL *)supported {
    BOOL ok = YES;
    id result = nil;
    NSArray<NSNumber *> *numbers = [value isKindOfClass:NSArray.class] ? value : nil;
    switch (attrType) {
        case LayerLens_AttrTypeChar:
        case LayerLens_AttrTypeInt:
        case LayerLens_AttrTypeShort:
        case LayerLens_AttrTypeLong:
        case LayerLens_AttrTypeLongLong:
        case LayerLens_AttrTypeUnsignedChar:
        case LayerLens_AttrTypeUnsignedInt:
        case LayerLens_AttrTypeUnsignedShort:
        case LayerLens_AttrTypeUnsignedLong:
        case LayerLens_AttrTypeUnsignedLongLong:
        case LayerLens_AttrTypeFloat:
        case LayerLens_AttrTypeDouble:
        case LayerLens_AttrTypeEnumInt:
        case LayerLens_AttrTypeEnumLong:
            result = [value isKindOfClass:NSNumber.class] ? value : @([[value description] doubleValue]);
            break;
        case LayerLens_AttrTypeBOOL:
            result = @([value boolValue]);
            break;
        case LayerLens_AttrTypeNSString:
            result = [value isKindOfClass:NSString.class] ? value : nil;
            break;
        case LayerLens_AttrTypeUIColor:
            // nil 表示清除颜色
            result = numbers.count == 4 ? numbers : nil;
            break;
        case LayerLens_AttrTypeCGPoint:
            ok = numbers.count == 2;
            result = ok ? [NSValue valueWithCGPoint:CGPointMake(numbers[0].doubleValue, numbers[1].doubleValue)] : nil;
            break;
        case LayerLens_AttrTypeCGVector:
            ok = numbers.count == 2;
            result = ok ? [NSValue valueWithCGVector:CGVectorMake(numbers[0].doubleValue, numbers[1].doubleValue)] : nil;
            break;
        case LayerLens_AttrTypeCGSize:
            ok = numbers.count == 2;
            result = ok ? [NSValue valueWithCGSize:CGSizeMake(numbers[0].doubleValue, numbers[1].doubleValue)] : nil;
            break;
        case LayerLens_AttrTypeCGRect:
            ok = numbers.count == 4;
            result = ok ? [NSValue valueWithCGRect:CGRectMake(numbers[0].doubleValue, numbers[1].doubleValue, numbers[2].doubleValue, numbers[3].doubleValue)] : nil;
            break;
        case LayerLens_AttrTypeCGAffineTransform:
            ok = numbers.count == 6;
            result = ok ? [NSValue valueWithCGAffineTransform:CGAffineTransformMake(numbers[0].doubleValue, numbers[1].doubleValue, numbers[2].doubleValue, numbers[3].doubleValue, numbers[4].doubleValue, numbers[5].doubleValue)] : nil;
            break;
        case LayerLens_AttrTypeUIEdgeInsets:
            ok = numbers.count == 4;
            result = ok ? [NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(numbers[0].doubleValue, numbers[1].doubleValue, numbers[2].doubleValue, numbers[3].doubleValue)] : nil;
            break;
        case LayerLens_AttrTypeUIOffset:
            ok = numbers.count == 2;
            result = ok ? [NSValue valueWithUIOffset:UIOffsetMake(numbers[0].doubleValue, numbers[1].doubleValue)] : nil;
            break;
        default:
            ok = NO;
            break;
    }
    if (supported) {
        *supported = ok;
    }
    return result;
}

#pragma mark - Helper

+ (NSArray<NSNumber *> *)arrayFromRect:(CGRect)rect {
    return @[[self safeNumber:rect.origin.x], [self safeNumber:rect.origin.y], [self safeNumber:rect.size.width], [self safeNumber:rect.size.height]];
}

/// NaN/Inf 无法 JSON 序列化
+ (NSNumber *)safeNumber:(double)value {
    if (isnan(value) || isinf(value)) {
        return @0;
    }
    return @(value);
}

+ (id)sanitizeNumber:(NSNumber *)number {
    double value = number.doubleValue;
    if (isnan(value) || isinf(value)) {
        return number.description ?: @"NaN";
    }
    return number;
}

@end
