
//
//  UITableView+LayerLens_Server.m
//  LayerLens_Server
//
//  Created by Li Kai on 2019/9/5.
//  https://lookin.work
//

#import "UITableView+LayerLens_Server.h"
#import "LayerLens_ServerDefines.h"

@implementation UITableView (LayerLens_Server)

- (NSArray<NSNumber *> *)layerlens_numberOfRows {
    NSUInteger sectionsCount = MIN(self.numberOfSections, 10);
    NSArray<NSNumber *> *rowsCount = [NSArray layerlens_arrayWithCount:sectionsCount block:^id(NSUInteger idx) {
        return @([self numberOfRowsInSection:idx]);
    }];
    if (rowsCount.count == 0) {
        return nil;
    }
    return rowsCount;
}

@end

