//
//  LLEListViewController.m
//  LayerLensExample
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LLEListViewController.h"
#if DEBUG && __has_include(<LayerLens/LayerLens.h>)
#import <LayerLens/LayerLens.h>
#define LLELog(...) LayerLensLog(__VA_ARGS__)
#else
#define LLELog(...)
#endif

@interface LLEListViewController () <UITableViewDataSource>

@property (nonatomic, strong) UIView *headerCard;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic, strong) UITableView *tableView;

@end

@implementation LLEListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"LayerLens";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    self.headerCard = [[UIView alloc] init];
    self.headerCard.backgroundColor = UIColor.systemIndigoColor;
    self.headerCard.layer.cornerRadius = 16;
    self.headerCard.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.headerCard];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.text = @"Open the LayerLens Mac app";
    self.titleLabel.textColor = UIColor.whiteColor;
    self.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];

    self.actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.actionButton setTitle:@"Toggle color" forState:UIControlStateNormal];
    [self.actionButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [self.actionButton addTarget:self action:@selector(toggleColor) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.titleLabel, self.actionButton]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentLeading;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.headerCard addSubview:stack];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.dataSource = self;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"cell"];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tableView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.headerCard.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [self.headerCard.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.headerCard.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:self.headerCard.topAnchor constant:20],
        [stack.leadingAnchor constraintEqualToAnchor:self.headerCard.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:self.headerCard.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:self.headerCard.bottomAnchor constant:-20],
        [self.tableView.topAnchor constraintEqualToAnchor:self.headerCard.bottomAnchor constant:8],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)toggleColor {
    BOOL indigo = [self.headerCard.backgroundColor isEqual:UIColor.systemIndigoColor];
    self.headerCard.backgroundColor = indigo ? UIColor.systemTealColor : UIColor.systemIndigoColor;
    // 日志显示在 LayerLens 的日志面板中
    LLELog(@"Toggle color: %@", indigo ? @"teal" : @"indigo");
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 20;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    UIListContentConfiguration *content = cell.defaultContentConfiguration;
    content.text = [NSString stringWithFormat:@"Row %ld", (long)indexPath.row + 1];
    content.image = [UIImage systemImageNamed:@"circle.grid.2x2"];
    cell.contentConfiguration = content;
    return cell;
}

@end
