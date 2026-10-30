//
//  LLEListViewController.m
//  LayerLensExample
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

#import "LLEListViewController.h"
#import "LLENetworkDemo.h"
#if DEBUG && __has_include(<LayerLens/LayerLens.h>)
#import <LayerLens/LayerLens.h>
#define LLELog(...) LayerLensLog(__VA_ARGS__)
#else
#define LLELog(...)
#endif

@interface LLEListViewController () <UITableViewDataSource>

@property (nonatomic, strong) UIView *headerCard;
@property (nonatomic, strong) UILabel *captureLabel;
@property (nonatomic, strong) NSTimer *captureTimer;
@property (nonatomic, strong) NSMutableArray *captureEvents;
@property (nonatomic, copy) NSDictionary *lastCaptureState;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic, strong) UIButton *requestButton;
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

    self.requestButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.requestButton setTitle:@"Send requests" forState:UIControlStateNormal];
    [self.requestButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [self.requestButton addTarget:self action:@selector(sendRequests) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.titleLabel, self.actionButton, self.requestButton]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentLeading;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.headerCard addSubview:stack];

    self.captureLabel = [[UILabel alloc] init];
    self.captureLabel.numberOfLines = 0;
    self.captureLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.captureLabel.textColor = UIColor.whiteColor;
    [stack addArrangedSubview:self.captureLabel];
    self.captureEvents = [NSMutableArray array];
    if (@available(iOS 17.0, *)) {
        [self registerForTraitChanges:@[UITraitSceneCaptureState.class] withTarget:self action:@selector(captureStateChanged)];
    }
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(captureStateChanged) name:UIScreenCapturedDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(captureStateChanged) name:UIApplicationDidBecomeActiveNotification object:nil];
    __weak typeof(self) weakSelf = self;
    self.captureTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        [weakSelf sampleCaptureState:@"poll"];
    }];

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

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    [self sampleCaptureState:@"appear"];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    UIApplication.sharedApplication.idleTimerDisabled = NO;
}

- (void)captureStateChanged { [self sampleCaptureState:@"notification-or-trait"]; }

- (void)sampleCaptureState:(NSString *)reason {
    UIScreen *screen = self.view.window.windowScene.screen ?: UIScreen.mainScreen;
    NSInteger viewState = -1, windowState = -1, sceneState = -1;
    if (@available(iOS 17.0, *)) {
        viewState = self.traitCollection.sceneCaptureState;
        windowState = self.view.window.traitCollection.sceneCaptureState;
        sceneState = self.view.window.windowScene.traitCollection.sceneCaptureState;
    }
    NSDictionary *state = @{@"view": @(viewState), @"window": @(windowState), @"scene": @(sceneState), @"screenCaptured": @(screen.isCaptured)};
    self.captureLabel.text = [NSString stringWithFormat:@"Capture API (0=inactive, 1=active)\nview=%ld window=%ld scene=%ld\nUIScreen.isCaptured=%@", (long)viewState, (long)windowState, (long)sceneState, screen.isCaptured ? @"YES" : @"NO"];
    if (![state isEqual:self.lastCaptureState] || ![reason isEqual:@"poll"]) {
        [self.captureEvents addObject:@{@"time": @(NSDate.date.timeIntervalSince1970), @"reason": reason, @"state": state}];
        if (self.captureEvents.count > 500) [self.captureEvents removeObjectAtIndex:0];
        LLELog(@"Capture probe %@: %@", reason, state);
        self.lastCaptureState = state;
    }
    NSDictionary *report = @{@"updatedAt": @(NSDate.date.timeIntervalSince1970), @"state": state, @"events": self.captureEvents, @"systemVersion": UIDevice.currentDevice.systemVersion};
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToURL:[documents URLByAppendingPathComponent:@"capture-probe.json"] atomically:YES];
}

- (void)dealloc { [self.captureTimer invalidate]; [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)toggleColor {
    [self sampleCaptureState:@"button-touch"];
    BOOL indigo = [self.headerCard.backgroundColor isEqual:UIColor.systemIndigoColor];
    self.headerCard.backgroundColor = indigo ? UIColor.systemTealColor : UIColor.systemIndigoColor;
    // 日志显示在 LayerLens 的日志面板中
    LLELog(@"Toggle color: %@", indigo ? @"teal" : @"indigo");
}

// 请求显示在 LayerLens 的网络面板中
- (void)sendRequests {
    [LLENetworkDemo sendRequests];
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
