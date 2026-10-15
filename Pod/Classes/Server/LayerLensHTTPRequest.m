//
//  LayerLensHTTPRequest.m
//  LayerLens
//
//  Created by YueYou on 10/12/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LayerLensHTTPRequest.h"

static const NSUInteger kLayerLensMaxHeaderLength = 64 * 1024;
static const NSUInteger kLayerLensMaxBodyLength = 1024 * 1024;

@interface LayerLensHTTPRequest ()

@property (nonatomic, copy, readwrite) NSString *method;
@property (nonatomic, copy, readwrite) NSString *path;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, NSString *> *query;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, strong, readwrite, nullable) NSData *body;

@end

@implementation LayerLensHTTPRequest

+ (LayerLensParseResult)parseData:(NSData *)data request:(LayerLensHTTPRequest **)request {
    NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange headerEnd = [data rangeOfData:separator options:0 range:NSMakeRange(0, data.length)];
    if (headerEnd.location == NSNotFound) {
        return data.length > kLayerLensMaxHeaderLength ? LayerLensParseResultError : LayerLensParseResultIncomplete;
    }

    NSString *headerString = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, headerEnd.location)] encoding:NSUTF8StringEncoding];
    NSArray<NSString *> *lines = [headerString componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *requestLine = [lines.firstObject componentsSeparatedByString:@" "];
    if (requestLine.count < 2) {
        return LayerLensParseResultError;
    }

    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSRange colon = [lines[i] rangeOfString:@":"];
        if (colon.location == NSNotFound) {
            continue;
        }
        NSString *name = [[lines[i] substringToIndex:colon.location] lowercaseString];
        NSString *value = [[lines[i] substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        headers[name] = value;
    }

    NSUInteger bodyLength = (NSUInteger)MAX([headers[@"content-length"] integerValue], 0);
    if (bodyLength > kLayerLensMaxBodyLength) {
        return LayerLensParseResultError;
    }
    NSUInteger bodyStart = headerEnd.location + headerEnd.length;
    if (data.length < bodyStart + bodyLength) {
        return LayerLensParseResultIncomplete;
    }

    LayerLensHTTPRequest *result = [[LayerLensHTTPRequest alloc] init];
    result.method = requestLine[0].uppercaseString;
    result.headers = headers;
    result.body = bodyLength > 0 ? [data subdataWithRange:NSMakeRange(bodyStart, bodyLength)] : nil;

    NSURLComponents *components = [NSURLComponents componentsWithString:[@"http://localhost" stringByAppendingString:requestLine[1]]];
    result.path = components.path.length > 0 ? components.path : @"/";
    NSMutableDictionary<NSString *, NSString *> *query = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.queryItems) {
        query[item.name] = item.value ?: @"";
    }
    result.query = query;

    if (request) {
        *request = result;
    }
    return LayerLensParseResultDone;
}

- (id)JSONBody {
    if (self.body.length == 0) {
        return nil;
    }
    return [NSJSONSerialization JSONObjectWithData:self.body options:0 error:nil];
}

@end
