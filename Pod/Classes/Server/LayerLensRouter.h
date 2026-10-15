//
//  LayerLensRouter.h
//  LayerLens
//
//  Created by YueYou on 10/12/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import <Foundation/Foundation.h>

@class LayerLensHTTPRequest, LayerLensHTTPResponse;

NS_ASSUME_NONNULL_BEGIN

typedef void (^LayerLensResponder)(LayerLensHTTPResponse *response);
/// handler 可在任意线程调用 responder, 且必须调用一次
typedef void (^LayerLensRouteHandler)(LayerLensHTTPRequest *request, LayerLensResponder responder);

@interface LayerLensRouter : NSObject

/// 精确匹配 path
- (void)addRoute:(NSString *)method path:(NSString *)path handler:(LayerLensRouteHandler)handler;
/// 前缀匹配, 精确匹配优先
- (void)addRoute:(NSString *)method prefix:(NSString *)prefix handler:(LayerLensRouteHandler)handler;

- (void)handleRequest:(LayerLensHTTPRequest *)request responder:(LayerLensResponder)responder;

@end

NS_ASSUME_NONNULL_END
