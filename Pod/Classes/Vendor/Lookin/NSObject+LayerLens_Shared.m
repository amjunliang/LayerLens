
//
//  NSObject+Lookin.m
//  Lookin
//
//  Created by Li Kai on 2018/12/22.
//  https://lookin.work
//

#import "NSObject+LayerLens_Shared.h"
#import <objc/runtime.h>
#import "TargetConditionals.h"
#import "LayerLens_WeakContainer.h"

@implementation NSObject (LayerLens_Shared)

#pragma mark - Data Bind

static char kAssociatedObjectKey_LookinAllBindObjects;
- (NSMutableDictionary<id, id> *)layerlens_allBindObjects {
    NSMutableDictionary<id, id> *dict = objc_getAssociatedObject(self, &kAssociatedObjectKey_LookinAllBindObjects);
    if (!dict) {
        dict = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &kAssociatedObjectKey_LookinAllBindObjects, dict, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return dict;
}

- (void)layerlens_bindObject:(id)object forKey:(NSString *)key {
    if (!key.length) {
        NSAssert(NO, @"");
        return;
    }
    @synchronized (self) {
        if (object) {
            [[self layerlens_allBindObjects] setObject:object forKey:key];
        } else {
            [[self layerlens_allBindObjects] removeObjectForKey:key];
        }
    }
}

- (id)layerlens_getBindObjectForKey:(NSString *)key {
    if (!key.length) {
        NSAssert(NO, @"");
        return nil;
    }
    @synchronized (self) {
        id storedObj = [[self layerlens_allBindObjects] objectForKey:key];
        if ([storedObj isKindOfClass:[LayerLens_WeakContainer class]]) {
            storedObj = [(LayerLens_WeakContainer *)storedObj object];
        }
        return storedObj;
    }
}

- (void)layerlens_bindObjectWeakly:(id)object forKey:(NSString *)key {
    if (!key.length) {
        NSAssert(NO, @"");
        return;
    }
    if (object) {
        LayerLens_WeakContainer *container = [[LayerLens_WeakContainer alloc] init];
        container.object = object;
        [self layerlens_bindObject:container forKey:key];
    } else {
        [self layerlens_bindObject:nil forKey:key];
    }
}

- (void)layerlens_bindDouble:(double)doubleValue forKey:(NSString *)key {
    [self layerlens_bindObject:@(doubleValue) forKey:key];
}

- (double)layerlens_getBindDoubleForKey:(NSString *)key {
    id object = [self layerlens_getBindObjectForKey:key];
    if ([object isKindOfClass:[NSNumber class]]) {
        double doubleValue = [(NSNumber *)object doubleValue];
        return doubleValue;
        
    } else {
        return 0.0;
    }
}

- (void)layerlens_bindBOOL:(BOOL)boolValue forKey:(NSString *)key {
    [self layerlens_bindObject:@(boolValue) forKey:key];
}

- (BOOL)layerlens_getBindBOOLForKey:(NSString *)key {
    id object = [self layerlens_getBindObjectForKey:key];
    if ([object isKindOfClass:[NSNumber class]]) {
        BOOL boolValue = [(NSNumber *)object boolValue];
        return boolValue;
        
    } else {
        return NO;
    }
}

- (void)layerlens_bindLong:(long)longValue forKey:(NSString *)key {
    [self layerlens_bindObject:@(longValue) forKey:key];
}

- (long)layerlens_getBindLongForKey:(NSString *)key {
    id object = [self layerlens_getBindObjectForKey:key];
    if ([object isKindOfClass:[NSNumber class]]) {
        long longValue = [(NSNumber *)object longValue];
        return longValue;
        
    } else {
        return 0;
    }
}

- (void)layerlens_bindPoint:(CGPoint)pointValue forKey:(NSString *)key {
#if TARGET_OS_IPHONE
    [self layerlens_bindObject:[NSValue valueWithCGPoint:pointValue] forKey:key];
#elif TARGET_OS_MAC
    NSPoint nsPoint = NSMakePoint(pointValue.x, pointValue.y);
    [self layerlens_bindObject:[NSValue valueWithPoint:nsPoint] forKey:key];
#endif
}

- (CGPoint)layerlens_getBindPointForKey:(NSString *)key {
    id object = [self layerlens_getBindObjectForKey:key];
    if ([object isKindOfClass:[NSValue class]]) {
#if TARGET_OS_IPHONE
        CGPoint pointValue = [(NSValue *)object CGPointValue];
#elif TARGET_OS_MAC
        NSPoint nsPointValue = [(NSValue *)object pointValue];
        CGPoint pointValue = CGPointMake(nsPointValue.x, nsPointValue.y);
#endif
        return pointValue;
    } else {
        return CGPointZero;
    }
}

- (void)layerlens_clearBindForKey:(NSString *)key {
    [self layerlens_bindObject:nil forKey:key];
}

@end

@implementation NSObject (LayerLens_Coding)

- (id)layerlens_encodedObjectWithType:(LayerLens_CodingValueType)type {
    if (type == LayerLens_CodingValueTypeColor) {
        if ([self isKindOfClass:[LayerLens_Color class]]) {
            CGFloat r, g, b, a;
#if TARGET_OS_IPHONE
            CGFloat white;
            if ([(UIColor *)self getRed:&r green:&g blue:&b alpha:&a]) {
                // valid
            } else if ([(UIColor *)self getWhite:&white alpha:&a]) {
                r = white;
                g = white;
                b = white;
            } else {
                NSAssert(NO, @"");
                r = 0;
                g = 0;
                b = 0;
                a = 0;
            }
#elif TARGET_OS_MAC
            NSColor *color = [((NSColor *)self) colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            [color getRed:&r green:&g blue:&b alpha:&a];
#endif
            NSArray<NSNumber *> *rgba = @[@(r), @(g), @(b), @(a)];
            return rgba;
            
        } else {
            NSAssert(NO, @"");
            return nil;
        }
        
    } else if (type == LayerLens_CodingValueTypeImage) {
#if TARGET_OS_IPHONE
        if ([self isKindOfClass:[UIImage class]]) {
            UIImage *image = (UIImage *)self;
            return UIImagePNGRepresentation(image);
            
        } else {
            NSAssert(NO, @"");
            return nil;
        }
#elif TARGET_OS_MAC
        if ([self isKindOfClass:[NSImage class]]) {
            NSImage *image = (NSImage *)self;
            return [image TIFFRepresentation];
            
        } else {
            NSAssert(NO, @"");
            return nil;
        }
#endif
        
    } else {
        return self;
    }
}

- (id)layerlens_decodedObjectWithType:(LayerLens_CodingValueType)type {
    if (type == LayerLens_CodingValueTypeColor) {
        if ([self isKindOfClass:[NSArray class]]) {
            NSArray<NSNumber *> *rgba = (NSArray *)self;
            CGFloat r = [rgba[0] doubleValue];
            CGFloat g = [rgba[1] doubleValue];
            CGFloat b = [rgba[2] doubleValue];
            CGFloat a = [rgba[3] doubleValue];
            LayerLens_Color *color = [LayerLens_Color colorWithRed:r green:g blue:b alpha:a];
            return color;
            
        } else {
            NSAssert(NO, @"");
            return nil;
        }
        
    } else if (type == LayerLens_CodingValueTypeImage) {
        if ([self isKindOfClass:[NSData class]]) {
            LayerLens_Image *image = [[LayerLens_Image alloc] initWithData:(NSData *)self];
            return image;
        } else {
            NSAssert(NO, @"");
            return nil;
        }
            
    } else {
        return self;
    }
}

@end

