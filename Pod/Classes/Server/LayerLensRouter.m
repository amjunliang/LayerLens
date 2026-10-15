//
//  LayerLensRouter.m
//  LayerLens
//
//  Created by YueYou on 10/12/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LayerLensRouter.h"
#import "LayerLensHTTPRequest.h"
#import "LayerLensHTTPResponse.h"

@interface LayerLensRouter ()

@property (nonatomic, strong) NSMutableDictionary<NSString *, LayerLensRouteHandler> *exactRoutes;
@property (nonatomic, strong) NSMutableArray<NSArray *> *prefixRoutes;

@end

@implementation LayerLensRouter

- (instancetype)init {
    if (self = [super init]) {
        _exactRoutes = [NSMutableDictionary dictionary];
        _prefixRoutes = [NSMutableArray array];
    }
    return self;
}

- (void)addRoute:(NSString *)method path:(NSString *)path handler:(LayerLensRouteHandler)handler {
    self.exactRoutes[[NSString stringWithFormat:@"%@ %@", method.uppercaseString, path]] = [handler copy];
}

- (void)addRoute:(NSString *)method prefix:(NSString *)prefix handler:(LayerLensRouteHandler)handler {
    [self.prefixRoutes addObject:@[method.uppercaseString, prefix, [handler copy]]];
}

- (void)handleRequest:(LayerLensHTTPRequest *)request responder:(LayerLensResponder)responder {
    LayerLensRouteHandler handler = self.exactRoutes[[NSString stringWithFormat:@"%@ %@", request.method, request.path]];
    if (!handler) {
        for (NSArray *route in self.prefixRoutes) {
            if ([route[0] isEqualToString:request.method] && [request.path hasPrefix:route[1]]) {
                handler = route[2];
                break;
            }
        }
    }
    if (!handler) {
        responder([LayerLensHTTPResponse errorResponse:404 message:@"Not Found"]);
        return;
    }
    handler(request, responder);
}

@end
