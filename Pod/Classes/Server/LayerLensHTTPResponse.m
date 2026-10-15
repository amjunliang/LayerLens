//
//  LayerLensHTTPResponse.m
//  LayerLens
//
//  Created by YueYou on 10/12/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LayerLensHTTPResponse.h"

@implementation LayerLensHTTPResponse

+ (instancetype)responseWithStatus:(NSInteger)status contentType:(NSString *)contentType body:(NSData *)body {
    LayerLensHTTPResponse *response = [[LayerLensHTTPResponse alloc] init];
    response.statusCode = status;
    response.contentType = contentType ?: @"text/plain; charset=utf-8";
    response.body = body;
    response.headers = [NSMutableDictionary dictionary];
    return response;
}

+ (instancetype)JSONResponse:(id)object {
    NSError *error = nil;
    NSData *data = object ? [NSJSONSerialization dataWithJSONObject:object options:0 error:&error] : nil;
    if (!data) {
        return [self errorResponse:500 message:error.localizedDescription ?: @"JSON serialization failed"];
    }
    return [self responseWithStatus:200 contentType:@"application/json; charset=utf-8" body:data];
}

+ (instancetype)errorResponse:(NSInteger)status message:(NSString *)message {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"error": message ?: @""} options:0 error:nil];
    return [self responseWithStatus:status contentType:@"application/json; charset=utf-8" body:data];
}

+ (instancetype)PNGResponse:(NSData *)data {
    LayerLensHTTPResponse *response = [self responseWithStatus:200 contentType:@"image/png" body:data];
    response.headers[@"Cache-Control"] = @"no-store";
    return response;
}

+ (instancetype)eventStreamResponseWithRetry:(NSInteger)retry {
    NSData *data = [[NSString stringWithFormat:@"retry: %ld\n\n", (long)retry] dataUsingEncoding:NSUTF8StringEncoding];
    LayerLensHTTPResponse *response = [self responseWithStatus:200 contentType:@"text/event-stream" body:data];
    response.headers[@"Cache-Control"] = @"no-store";
    response.keepOpen = YES;
    return response;
}

- (NSData *)serializedData {
    NSDictionary<NSNumber *, NSString *> *reasons = @{
        @200: @"OK", @302: @"Found", @400: @"Bad Request", @401: @"Unauthorized",
        @404: @"Not Found", @405: @"Method Not Allowed", @413: @"Payload Too Large", @500: @"Internal Server Error",
    };
    NSMutableString *head = [NSMutableString stringWithFormat:@"HTTP/1.1 %ld %@\r\n", (long)self.statusCode, reasons[@(self.statusCode)] ?: @"Unknown"];
    [head appendFormat:@"Content-Type: %@\r\n", self.contentType];
    if (self.keepOpen) {
        [head appendString:@"Connection: keep-alive\r\n"];
    } else {
        [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long)self.body.length];
        [head appendString:@"Connection: close\r\n"];
    }
    [self.headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        [head appendFormat:@"%@: %@\r\n", key, value];
    }];
    [head appendString:@"\r\n"];

    NSMutableData *data = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (self.body) {
        [data appendData:self.body];
    }
    return data;
}

@end
