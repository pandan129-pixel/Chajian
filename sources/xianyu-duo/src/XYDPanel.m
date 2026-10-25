#import "XYDCommon.h"
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>

#pragma mark - helpers

UIViewController *XYDTopViewController(void) {
    UIWindow *win = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                    if (w.isKeyWindow) { win = w; break; }
                }
            }
            if (win) break;
        }
    }
    if (!win) win = UIApplication.sharedApplication.keyWindow;
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) vc = ((UINavigationController *)vc).topViewController;
    if ([vc isKindOfClass:[UITabBarController class]]) vc = ((UITabBarController *)vc).selectedViewController;
    return vc;
}

void XYDRefreshStatusBarTree(UIViewController *vc) {
    if (!vc) return;
    [vc setNeedsStatusBarAppearanceUpdate];
    for (UIViewController *c in vc.childViewControllers) XYDRefreshStatusBarTree(c);
    if ([vc isKindOfClass:[UINavigationController class]])
        XYDRefreshStatusBarTree(((UINavigationController *)vc).topViewController);
    if ([vc isKindOfClass:[UITabBarController class]])
        XYDRefreshStatusBarTree(((UITabBarController *)vc).selectedViewController);
}

void XYDShowToast(NSString *text) {
    if (!text.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
                if ([sc isKindOfClass:[UIWindowScene class]]) {
                    for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                        if (w.isKeyWindow) { win = w; break; }
                    }
                }
                if (win) break;
            }
        }
        if (!win) win = UIApplication.sharedApplication.keyWindow;
        if (!win) return;
        UILabel *l = [UILabel new];
        l.text = text;
        l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        l.textColor = UIColor.whiteColor;
        l.textAlignment = NSTextAlignmentCenter;
        l.numberOfLines = 0;
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
        l.layer.cornerRadius = 12;
        l.layer.masksToBounds = YES;
        CGSize size = [l sizeThatFits:CGSizeMake(win.bounds.size.width - 80, 200)];
        l.frame = CGRectMake(0, 0, size.width + 32, size.height + 20);
        l.center = CGPointMake(win.bounds.size.width / 2, win.bounds.size.height - 120);
        l.alpha = 0;
        [win addSubview:l];
        [UIView animateWithDuration:0.18 animations:^{ l.alpha = 1; } completion:^(BOOL f) {
            [UIView animateWithDuration:0.25 delay:1.8 options:0 animations:^{ l.alpha = 0; } completion:^(BOOL f2) { [l removeFromSuperview]; }];
        }];
    });
}

#pragma mark - media cell

@interface XYDMediaCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *thumb;
@property (nonatomic, strong) UILabel *badge;
@property (nonatomic, strong) UIImageView *check;
@end

@implementation XYDMediaCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.contentView.backgroundColor = [UIColor secondarySystemBackgroundColor];
        self.contentView.layer.cornerRadius = 8;
        self.contentView.layer.masksToBounds = YES;
        _thumb = [[UIImageView alloc] initWithFrame:self.contentView.bounds];
        _thumb.contentMode = UIViewContentModeScaleAspectFill;
        _thumb.clipsToBounds = YES;
        _thumb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.contentView addSubview:_thumb];
        _badge = [[UILabel alloc] initWithFrame:CGRectMake(4, 4, 34, 16)];
        _badge.font = [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold];
        _badge.textColor = UIColor.whiteColor;
        _badge.textAlignment = NSTextAlignmentCenter;
        _badge.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        _badge.layer.cornerRadius = 4;
        _badge.layer.masksToBounds = YES;
        _badge.hidden = YES;
        [self.contentView addSubview:_badge];
        _check = [[UIImageView alloc] initWithFrame:CGRectMake(frame.size.width - 24, frame.size.height - 24, 18, 18)];
        _check.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
        _check.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        _check.tintColor = [UIColor systemBlueColor];
        _check.backgroundColor = UIColor.whiteColor;
        _check.layer.cornerRadius = 9;
        _check.hidden = YES;
        [self.contentView addSubview:_check];
    }
    return self;
}
- (void)prepareForReuse {
    [super prepareForReuse];
    self.thumb.image = nil;
    self.badge.hidden = YES;
}
@end

#pragma mark - settings vc

@interface XYDSettingsVC () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, copy) NSArray *rows;
@end

@implementation XYDSettingsVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"闲鱼助手 + 存图";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    [self.view addSubview:self.table];

    NSArray *switches = @[
        @[@"总开关", @"enabled"],
        @[@"拦截开屏/热启动广告", @"blockSplash"],
        @[@"隐藏信息流广告", @"blockFeed"],
        @[@"我的页净化", @"cleanMyPage"],
        @[@"详情页悬浮球", @"showBall"],
        @[@"我的页入口", @"myPageEntry"],
        @[@"自动收集已加载图片", @"autoCapture"],
        @[@"收集视频地址", @"captureVideo"],
        @[@"调试日志", @"debug"],
    ];
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableArray *dbg = [NSMutableArray array];
    for (NSArray *pair in switches) {
        NSString *key = pair[1];
        BOOL on = XYDPrefBool(key, YES);
        if ([key isEqualToString:@"enable"] || [key isEqualToString:@"debug"]) on = XYDPrefBool(key, NO);
        NSString *detail = nil;
        if ([key isEqualToString:@"blockSplash"]) detail = @"FMSplashModule / FMHomeRefreshHelper / FishSplashAdWindow";
        if ([key isEqualToString:@"blockFeed"]) detail = @"WaterfallItemCell 广告容器识别";
        if ([key isEqualToString:@"cleanMyPage"]) detail = @"我的页广告/营销位隐藏（保守规则）";
        [rows addObject:@{@"title": pair[0], @"key": key, @"kind": @"switch", @"value": @(on), @"detail": detail ?: @""}];
    }
    [rows addObject:@{@"title": @"最小图片体积", @"key": @"minKB", @"kind": @"minKB", @"value": @(XYDPrefDouble(@"minKB", 15))}];
    [rows addObject:@{@"title": @"最小图片边长", @"key": @"minPixel", @"kind": @"minPixel", @"value": @(XYDPrefDouble(@"minPixel", 300))}];
    self.rows = rows;
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"功能";
    if (section == 1) return @"图片收集";
    return @"诊断";
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"广告相关规则失败时不会影响 App 正常使用；可在日志里看命中情况。";
    if (section == 1) return @"体积/边长阈值越低，收集越全，但内存占用越高。";
    return nil;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 9;
    if (section == 1) return (NSInteger)self.rows.count - 9;
    return 1;
}
- (NSDictionary *)rowAt:(NSIndexPath *)ip {
    if (ip.section == 2) return nil;
    NSInteger idx = ip.section == 0 ? ip.row : 9 + ip.row;
    return idx < (NSInteger)self.rows.count ? self.rows[idx] : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 2) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"d"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"d"];
        cell.textLabel.text = @"查看诊断信息";
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    NSDictionary *r = [self rowAt:ip];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    cell.textLabel.text = r[@"title"];
    cell.detailTextLabel.text = r[@"detail"];
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSString *kind = r[@"kind"];
    if ([kind isEqualToString:@"switch"]) {
        UISwitch *sw = [UISwitch new];
        sw.on = [r[@"value"] boolValue];
        sw.tag = ip.section * 100 + ip.row;
        [sw addTarget:self action:@selector(onSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else {
        UISlider *sl = [UISlider new];
        sl.frame = CGRectMake(0, 0, 150, 32);
        if ([kind isEqualToString:@"minKB"]) { sl.minimumValue = 1; sl.maximumValue = 200; }
        else { sl.minimumValue = 80; sl.maximumValue = 1200; }
        sl.value = [r[@"value"] doubleValue];
        sl.tag = ip.section * 100 + ip.row;
        [sl addTarget:self action:@selector(onSlider:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sl;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"当前 %.0f", sl.value];
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 2) return;
    [self showDiagnostics];
}

- (void)showDiagnostics {
    NSMutableString *m = [NSMutableString string];
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    [m appendFormat:@"闲鱼 %@ (%@)\n融合插件 1.0.6\n\n", info[@"CFBundleShortVersionString"] ?: @"?",
                      info[@"CFBundleVersion"] ?: @"?"];
    [m appendFormat:@"FMSplashModule: %@\n", XYDClassExists(@"FMSplashModule") ? @"YES" : @"NO"];
    [m appendFormat:@"  loadAd: %@\n", XYDClassHasMethod(@"FMSplashModule", @"loadAd") ? @"YES" : @"NO"];
    [m appendFormat:@"  showSplashView: %@\n", XYDClassHasMethod(@"FMSplashModule", @"showSplashView") ? @"YES" : @"NO"];
    [m appendFormat:@"FMHomeRefreshHelper: %@\n", XYDClassExists(@"FMHomeRefreshHelper") ? @"YES" : @"NO"];
    [m appendFormat:@"  requestHotStartDecide: %@\n", XYDClassHasMethod(@"FMHomeRefreshHelper", @"requestHotStartDecide:") ? @"YES" : @"NO"];
    [m appendFormat:@"SplashWindow: %@\n", XYDClassExists(@"_TtC6FishAd18FishSplashAdWindow") ? @"YES" : @"NO"];
    Class detailCls = NSClassFromString(@"XDetailViewController");
    [m appendFormat:@"XDetailViewController: %@\n", detailCls ? @"YES" : @"NO"];
    [m appendFormat:@"  detailContext ivar: %@\n", (detailCls && class_getInstanceVariable(detailCls, "detailContext")) ? @"YES" : @"NO"];
    NSArray *feed = XYDMatchingClassNames(@[@"WaterfallItemCell", @"SingleRowItemCell", @"HomeCardCell"], 12);
    [m appendFormat:@"信息流 cell（命中 hook 的类）: %lu\n%@\n", (unsigned long)feed.count,
                    feed.count ? [feed componentsJoinedByString:@"\n"] : @"（无）"];
    NSArray *mine = XYDMatchingClassNames(@[@"FloatingUserInfoContentView", @"TopUserInfoContentView"], 6);
    [m appendFormat:@"\n我的页 view: %lu\n%@\n", (unsigned long)mine.count,
                    mine.count ? [mine componentsJoinedByString:@"\n"] : @"（无）"];
    [m appendFormat:@"\nMTOP token: %@\n相册权限: %ld\n",
                    [[[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies] filteredArrayUsingPredicate:
                     [NSPredicate predicateWithFormat:@"name == '_m_h5_tk'"]].count ? @"有" : @"无",
                    (long)[PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly]];
    [m appendFormat:@"\n日志: %@/xianyuduo.log\n", NSTemporaryDirectory()];

    UIViewController *vc = [UIViewController new];
    vc.title = @"诊断";
    vc.view.backgroundColor = [UIColor systemBackgroundColor];
    UITextView *tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.editable = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    tv.text = m;
    tv.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    [vc.view addSubview:tv];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)onSwitch:(UISwitch *)sw {
    NSIndexPath *ip = [NSIndexPath indexPathForRow:sw.tag % 100 inSection:sw.tag / 100];
    NSDictionary *r = [self rowAt:ip];
    if (r) XYDSetPref(r[@"key"], @(sw.on));
}
- (void)onSlider:(UISlider *)sl {
    NSIndexPath *ip = [NSIndexPath indexPathForRow:sl.tag % 100 inSection:sl.tag / 100];
    NSDictionary *r = [self rowAt:ip];
    if (!r) return;
    NSString *key = r[@"key"];
    double v = [key isEqualToString:@"minKB"] ? round(sl.value) : round(sl.value / 10) * 10;
    XYDSetPref(key, @(v));
    UITableViewCell *cell = [self.table cellForRowAtIndexPath:ip];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"当前 %.0f", v];
}
@end

#pragma mark - panel

@interface XYDPanelVC () <UICollectionViewDataSource, UICollectionViewDelegate>
@property (nonatomic, strong) UISegmentedControl *tabs;
@property (nonatomic, strong) UICollectionView *grid;
@property (nonatomic, strong) UIScrollView *settings;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UIButton *saveBtn;
@property (nonatomic, strong) UIButton *selectBtn;
@property (nonatomic, strong) UIButton *idBtn;
@property (nonatomic, strong) NSMutableArray<XYDMediaItem *> *items;
@property (nonatomic, strong) NSMutableSet<NSString *> *selected;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *thumbs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *downloading;
@property (nonatomic, strong) NSMutableArray<XYDMediaItem *> *thumbQueue;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *thumbTries;
@property (nonatomic) NSInteger thumbActive;
@property (nonatomic, copy) NSString *title2;
@property (nonatomic) BOOL busy;
@property (nonatomic) BOOL reloadStarted;
@end

@implementation XYDPanelVC

- (UIStatusBarStyle)preferredStatusBarStyle {
    if (@available(iOS 13.0, *)) return UIStatusBarStyleDarkContent;
    return UIStatusBarStyleDefault;
}

- (BOOL)prefersStatusBarHidden { return NO; }

- (instancetype)initWithItemId:(NSString *)itemId {
    if ((self = [super init])) {
        _itemId = [itemId copy];
        _items = [NSMutableArray array];
        _selected = [NSMutableSet set];
        _thumbs = [NSCache new];
        _thumbs.countLimit = 120;
        _downloading = [NSMutableDictionary dictionary];
        _thumbQueue = [NSMutableArray array];
        _thumbTries = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.modalPresentationCapturesStatusBarAppearance = NO;
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"存图";
    CGFloat top = 8, w = self.view.bounds.size.width;

    UILabel *title = [UILabel new];
    title.text = @"存图";
    title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    title.frame = CGRectMake(16, top + 4, w - 170, 28);
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.view addSubview:title];
    self.title2 = title.text;

    UILabel *sub = [UILabel new];
    sub.text = self.itemId.length ? [NSString stringWithFormat:@"ID %@", self.itemId] : @"未识别商品 ID";
    sub.font = [UIFont systemFontOfSize:10];
    sub.textColor = [UIColor secondaryLabelColor];
    sub.frame = CGRectMake(16, top + 30, w - 170, 14);
    sub.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.view addSubview:sub];

    UIButton *gear = [UIButton buttonWithType:UIButtonTypeSystem];
    gear.frame = CGRectMake(w - 112, top + 2, 40, 32);
    [gear setImage:[UIImage systemImageNamed:@"gearshape"] forState:UIControlStateNormal];
    [gear addTarget:self action:@selector(openSettingsTab) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:gear];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(w - 60, top, 44, 32);
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    self.tabs = [[UISegmentedControl alloc] initWithItems:@[@"媒体", @"设置"]];
    self.tabs.frame = CGRectMake(16, top + 48, w - 32, 32);
    self.tabs.selectedSegmentIndex = self.startOnSettings ? 1 : 0;
    [self.tabs addTarget:self action:@selector(switchTab) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.tabs];

    UICollectionViewFlowLayout *fl = [UICollectionViewFlowLayout new];
    CGFloat gap = 4;
    CGFloat cw = (w - 16 * 2 - gap * 2) / 3.0;
    fl.itemSize = CGSizeMake(cw, cw);
    fl.minimumInteritemSpacing = gap;
    fl.minimumLineSpacing = gap;
    fl.sectionInset = UIEdgeInsetsMake(8, 16, 8, 16);
    self.grid = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:fl];
    self.grid.backgroundColor = UIColor.clearColor;
    self.grid.dataSource = self;
    self.grid.delegate = self;
    self.grid.allowsMultipleSelection = YES;
    [self.grid registerClass:[XYDMediaCell class] forCellWithReuseIdentifier:@"m"];
    self.grid.frame = CGRectMake(0, top + 88, w, self.view.bounds.size.height - top - 88 - 86);
    self.grid.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.grid];

    self.settings = [[UIScrollView alloc] initWithFrame:self.grid.frame];
    self.settings.hidden = YES;
    [self.view addSubview:self.settings];
    [self buildSettings];

    UIView *bar = [UIView new];
    bar.frame = CGRectMake(0, self.view.bounds.size.height - 86, w, 86);
    bar.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    bar.backgroundColor = [UIColor secondarySystemBackgroundColor];
    [self.view addSubview:bar];

    self.status = [[UILabel alloc] initWithFrame:CGRectMake(16, 6, w - 32, 18)];
    self.status.font = [UIFont systemFontOfSize:11];
    self.status.textColor = [UIColor secondaryLabelColor];
    self.status.text = @"正在读取商品媒体…";
    [bar addSubview:self.status];

    self.selectBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.selectBtn.frame = CGRectMake(16, 30, 84, 40);
    [self.selectBtn setTitle:@"全选" forState:UIControlStateNormal];
    [self.selectBtn addTarget:self action:@selector(toggleSelectAll) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:self.selectBtn];

    if (!self.itemId.length) {
        self.idBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        self.idBtn.frame = CGRectMake(108, 30, 76, 40);
        [self.idBtn setTitle:@"输入ID" forState:UIControlStateNormal];
        [self.idBtn addTarget:self action:@selector(onInputID) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:self.idBtn];
    }

    self.saveBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.saveBtn.frame = CGRectMake(w - 16 - 130, 30, 130, 40);
    self.saveBtn.backgroundColor = [UIColor systemBlueColor];
    self.saveBtn.layer.cornerRadius = 10;
    [self.saveBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [self.saveBtn setTitle:@"保存所选" forState:UIControlStateNormal];
    [self.saveBtn addTarget:self action:@selector(saveSelected) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:self.saveBtn];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.reloadStarted) {
        self.reloadStarted = YES;
        [self reloadMedia];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.busy = NO;
    [self updateBar];
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sp = self.sheetPresentationController;
        if (sp) { sp.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent]; }
    }
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:^{
        UIWindow *win = nil;
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) if (w.isKeyWindow) { win = w; break; }
            if (win) break;
        }
        if (!win) win = UIApplication.sharedApplication.keyWindow;
        // 不要把根控制器的 prefersStatusBarHidden 强行刷新出来（闲鱼根控制器返回 YES）
        UIViewController *presenter = win.rootViewController;
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        [presenter setNeedsStatusBarAppearanceUpdate];
    }];
}

- (void)openSettingsTab {
    self.tabs.selectedSegmentIndex = 1;
    [self switchTab];
}

- (void)switchTab {
    BOOL s = self.tabs.selectedSegmentIndex == 1;
    self.grid.hidden = s;
    self.settings.hidden = !s;
    self.selectBtn.hidden = s;
    self.saveBtn.hidden = s;
    self.status.text = s ? @"设置修改立即生效（广告开关需下次启动完全生效）" : self.status.text;
}

- (void)buildSettings {
    CGFloat y = 8, w = self.view.bounds.size.width;
    NSArray *defs = @[
        @[@"总开关", @"enabled", @1],
        @[@"拦截开屏/热启动广告", @"blockSplash", @1],
        @[@"隐藏信息流广告", @"blockFeed", @1],
        @[@"我的页净化", @"cleanMyPage", @1],
        @[@"自动收集图片", @"autoCapture", @1],
        @[@"收集视频地址", @"captureVideo", @1],
        @[@"详情页悬浮球", @"showBall", @1],
        @[@"我的页入口", @"myPageEntry", @1],
        @[@"调试日志", @"debug", @0],
    ];
    for (NSArray *d in defs) {
        UIView *row = [UIView new];
        row.frame = CGRectMake(0, y, w, 46);
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, w - 110, 46)];
        l.text = d[0];
        l.font = [UIFont systemFontOfSize:14];
        [row addSubview:l];
        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(w - 70, 7, 51, 31)];
        sw.on = XYDPrefBool(d[1], [d[2] boolValue]);
        sw.tag = [defs indexOfObject:d];
        [sw addTarget:self action:@selector(settingSwitch:) forControlEvents:UIControlEventValueChanged];
        [row addSubview:sw];
        [self.settings addSubview:row];
        y += 46;
    }
    NSArray *sliders = @[@[@"最小图片体积 (KB)", @"minKB", @15, @1, @200],
                         @[@"最小图片边长 (px)", @"minPixel", @300, @80, @1200]];
    for (NSArray *d in sliders) {
        UIView *row = [UIView new];
        row.frame = CGRectMake(0, y, w, 66);
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, w - 32, 18)];
        l.font = [UIFont systemFontOfSize:13];
        double v = XYDPrefDouble(d[1], [d[2] doubleValue]);
        l.text = [NSString stringWithFormat:@"%@：%.0f", d[0], v];
        l.tag = 900 + [sliders indexOfObject:d];
        [row addSubview:l];
        UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(16, 30, w - 32, 28)];
        sl.minimumValue = [d[3] doubleValue]; sl.maximumValue = [d[4] doubleValue]; sl.value = v;
        sl.tag = [sliders indexOfObject:d];
        [sl addTarget:self action:@selector(settingSlider:) forControlEvents:UIControlEventValueChanged];
        [row addSubview:sl];
        [self.settings addSubview:row];
        y += 66;
    }
    UILabel *ver = [[UILabel alloc] initWithFrame:CGRectMake(16, y + 10, w - 32, 40)];
    ver.font = [UIFont systemFontOfSize:11];
    ver.textColor = [UIColor secondaryLabelColor];
    ver.numberOfLines = 0;
    ver.text = @"融合版 1.0 · 去广告来自 3.2.2 逆向，存图逻辑重写\n无 SQLite / 无定时器 / 无常驻后台任务";
    [self.settings addSubview:ver];
    self.settings.contentSize = CGSizeMake(w, y + 70);
}

- (void)settingSwitch:(UISwitch *)sw {
    NSArray *keys = @[@"enabled",@"blockSplash",@"blockFeed",@"cleanMyPage",@"autoCapture",
                      @"captureVideo",@"showBall",@"myPageEntry",@"debug"];
    if (sw.tag >= 0 && sw.tag < (NSInteger)keys.count) {
        XYDSetPref(keys[sw.tag], @(sw.on));
        if ([keys[sw.tag] isEqualToString:@"showBall"] && !sw.on) XYDUninstallFloatingBall();
    }
}

- (void)settingSlider:(UISlider *)sl {
    NSString *key = sl.tag == 0 ? @"minKB" : @"minPixel";
    double v = sl.tag == 0 ? round(sl.value) : round(sl.value / 10) * 10;
    XYDSetPref(key, @(v));
    UILabel *l = [self.settings viewWithTag:900 + sl.tag];
    if (l) l.text = [NSString stringWithFormat:@"%@：%.0f", sl.tag == 0 ? @"最小图片体积 (KB)" : @"最小图片边长 (px)", v];
}

- (void)reloadMedia {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        XYDScanVideoCache();
    });
    NSMutableArray *merged = [NSMutableArray array];
    NSMutableSet *keys = [NSMutableSet set];
    for (XYDMediaItem *it in [[XYDStore shared] snapshot]) {
        if (it.key.length && ![keys containsObject:it.key]) { [keys addObject:it.key]; [merged addObject:it]; }
    }
    self.items = merged;
    [self fillVideoCovers];
    [self.grid reloadData];
    [self.grid layoutIfNeeded];
    [self prefetchThumbs];
    [self updateBar];

    if (!self.itemId.length) {
        self.status.text = merged.count ? [NSString stringWithFormat:@"已捕获 %lu 项", (unsigned long)merged.count] : @"没有捕获到媒体";
        return;
    }
    self.status.text = @"正在读取商品原图…";
    __weak typeof(self) weakSelf = self;
    XYDFetchItemMedia(self.itemId, ^(NSArray<XYDMediaItem *> *items, NSString *title, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSMutableArray *m = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        NSArray *captured = [[XYDStore shared] snapshot];
        for (XYDMediaItem *it in items) {
            if (!it.key.length || [seen containsObject:it.key]) continue;
            if (it.kind == XYDMediaKindPhoto) {
                BOOL dup = NO;
                for (XYDMediaItem *c in captured) {
                    if (c.kind != XYDMediaKindPhoto || !c.data.length) continue;
                    if (c.pixelSize.width > 0 && it.pixelSize.width > 0) {
                        if (fabs(c.pixelSize.width - it.pixelSize.width) <= 2 &&
                            fabs(c.pixelSize.height - it.pixelSize.height) <= 2) { dup = YES; break; }
                    }
                }
                if (dup) continue;
            }
            [seen addObject:it.key];
            [m addObject:it];
        }
        for (XYDMediaItem *it in captured) {
            if (it.key.length && ![seen containsObject:it.key]) { [seen addObject:it.key]; [m addObject:it]; }
        }
        self.items = m;
        [self fillVideoCovers];
        [self.grid reloadData];
        [self.grid layoutIfNeeded];
        [self prefetchThumbs];
        [self updateBar];
        if (error && !m.count) self.status.text = error.localizedDescription;
        else self.status.text = [NSString stringWithFormat:@"共 %lu 项（API %lu / 捕获 %lu）",
                                 (unsigned long)m.count, (unsigned long)items.count,
                                 (unsigned long)[[XYDStore shared] snapshot].count];
    });
}

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)self.items.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    XYDMediaCell *c = [cv dequeueReusableCellWithReuseIdentifier:@"m" forIndexPath:ip];
    XYDMediaItem *it = self.items[ip.item];
    c.check.hidden = ![self.selected containsObject:it.key];
    c.badge.hidden = it.kind != XYDMediaKindVideo;
    if (it.kind == XYDMediaKindVideo) c.badge.text = @"▶ 视频";
    UIImage *img = [self.thumbs objectForKey:it.key];
    if (img) {
        c.thumb.image = img;
        c.thumb.backgroundColor = UIColor.clearColor;
    } else {
        c.thumb.image = nil;
        c.thumb.backgroundColor = [UIColor tertiarySystemFillColor];
        [self loadThumb:it];
    }
    return c;
}

- (void)loadThumb:(XYDMediaItem *)it {
    if (!it.key.length) return;
    if ([self.thumbs objectForKey:it.key]) return;
    if ([self.downloading objectForKey:it.key]) return;
    self.downloading[it.key] = @1;
    [self.thumbQueue addObject:it];
    [self pumpThumbs];
}

- (void)pumpThumbs {
    while (self.thumbActive < 4 && self.thumbQueue.count) {
        XYDMediaItem *it = self.thumbQueue.firstObject;
        [self.thumbQueue removeObjectAtIndex:0];
        self.thumbActive++;
        [self startThumb:it];
    }
}

- (void)finishThumb:(XYDMediaItem *)it image:(UIImage *)img {
    self.thumbActive = MAX(0, self.thumbActive - 1);
    [self.downloading removeObjectForKey:it.key];
    if (img && it.key) {
        [self.thumbs setObject:img forKey:it.key];
        [self.thumbTries removeObjectForKey:it.key];
        NSUInteger idx = [self.items indexOfObjectIdenticalTo:it];
        if (idx != NSNotFound && idx < (NSUInteger)[self.grid numberOfItemsInSection:0]) {
            NSIndexPath *ip = [NSIndexPath indexPathForItem:(NSInteger)idx inSection:0];
            [self.grid reloadItemsAtIndexPaths:@[ip]];
        }
    } else if (it.key) {
        // 首次失败常见于并发请求/缓存未命中，自动重试一次
        NSInteger tries = [self.thumbTries[it.key] integerValue];
        if (tries < 1) {
            self.thumbTries[it.key] = @(tries + 1);
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf loadThumb:it];
            });
        }
    }
    [self pumpThumbs];
}

- (NSURL *)thumbURLForPhotoURL:(NSURL *)u {
    if (!u) return nil;
    NSString *s = u.absoluteString;
    if ([s containsString:@"alicdn.com"] || [s containsString:@"tbcdn.cn"] || [s containsString:@"taobaocdn"]) {
        NSRange q = [s rangeOfString:@"?"];
        NSString *base = q.location == NSNotFound ? s : [s substringToIndex:q.location];
        NSString *ext = base.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"] || [ext isEqualToString:@"png"]) {
            NSString *thumb = [NSString stringWithFormat:@"%@_360x360q78.%@", base, ext];
            return [NSURL URLWithString:thumb];
        }
    }
    return u;
}

- (NSURL *)thumbURLFor:(XYDMediaItem *)it {
    if (!it.remoteURL) return nil;
    if (it.kind == XYDMediaKindVideo) {
        if (it.coverURL) return [self thumbURLForPhotoURL:it.coverURL];
        NSString *s = it.remoteURL.absoluteString;
        if ([s containsString:@"alicdn.com"] && ![s containsString:@"x-oss-process"]) {
            NSString *sep = [s containsString:@"?"] ? @"&" : @"?";
            return [NSURL URLWithString:[s stringByAppendingFormat:@"%@x-oss-process=video/snapshot,t_1000,w_400", sep]];
        }
        return nil;
    }
    return [self thumbURLForPhotoURL:it.remoteURL];
}

- (void)generateVideoThumb:(XYDMediaItem *)it {
    NSURL *u = it.remoteURL;
    if (!u) { [self finishThumb:it image:nil]; return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray *parts = [NSMutableArray array];
        for (NSHTTPCookie *c in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies]) {
            NSString *dom = c.domain.lowercaseString ?: @"";
            if ([dom containsString:@"goofish"] || [dom containsString:@"taobao"])
                [parts addObject:[NSString stringWithFormat:@"%@=%@", c.name, c.value]];
        }
        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        headers[@"Referer"] = @"https://h5.m.goofish.com/";
        headers[@"User-Agent"] = @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
        if (parts.count) headers[@"Cookie"] = [parts componentsJoinedByString:@"; "];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:u options:@{@"AVURLAssetHTTPHeaderFieldsKey": headers}];
        AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
        gen.appliesPreferredTrackTransform = YES;
        gen.maximumSize = CGSizeMake(360, 360);
        NSError *err = nil;
        CGImageRef cg = [gen copyCGImageAtTime:CMTimeMakeWithSeconds(1.0, 600) actualTime:NULL error:&err];
        UIImage *img = cg ? [UIImage imageWithCGImage:cg] : nil;
        if (cg) CGImageRelease(cg);
        dispatch_async(dispatch_get_main_queue(), ^{ [self finishThumb:it image:img]; });
    });
}

- (void)fillVideoCovers {
    NSURL *cover = nil;
    for (XYDMediaItem *it in self.items) {
        if (it.kind == XYDMediaKindPhoto && it.remoteURL) { cover = it.remoteURL; break; }
    }
    if (!cover) return;
    for (XYDMediaItem *it in self.items) {
        if (it.kind == XYDMediaKindVideo && !it.coverURL) it.coverURL = cover;
    }
}

- (void)prefetchThumbs {
    NSUInteger n = MIN(self.items.count, (NSUInteger)15);
    for (NSUInteger i = 0; i < n; i++) [self loadThumb:self.items[i]];
}

- (void)startThumb:(XYDMediaItem *)it {
    if (it.kind == XYDMediaKindVideo && !it.coverURL && !it.data.length) {
        [self generateVideoThumb:it];
        return;
    }
    if (it.data.length) {
        NSData *data = it.data;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            UIImage *img = [self thumbnailFromData:data max:360];
            dispatch_async(dispatch_get_main_queue(), ^{ [self finishThumb:it image:img]; });
        });
        return;
    }
    NSURL *u = [self thumbURLFor:it];
    if (!u) { [self finishThumb:it image:nil]; return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    req.timeoutInterval = 15;
    [req setValue:@"https://h5.m.goofish.com/" forHTTPHeaderField:@"Referer"];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        forHTTPHeaderField:@"User-Agent"];
    NSURLSession *ss = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    [[ss dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            UIImage *img = data.length ? [self thumbnailFromData:data max:360] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{ [self finishThumb:it image:img]; });
        });
    }] resume];
    [ss finishTasksAndInvalidate];
}

- (UIImage *)thumbnailFromData:(NSData *)data max:(CGFloat)max {
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) return nil;
    NSDictionary *opts = @{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                           (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(max),
                           (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES};
    CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(src);
    if (!cg) return nil;
    UIImage *img = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return img;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    XYDMediaItem *it = self.items[ip.item];
    if (!it.key) return;
    if ([self.selected containsObject:it.key]) [self.selected removeObject:it.key];
    else [self.selected addObject:it.key];
    [cv reloadItemsAtIndexPaths:@[ip]];
    [self updateBar];
}

- (void)toggleSelectAll {
    if (self.selected.count == self.items.count) [self.selected removeAllObjects];
    else for (XYDMediaItem *it in self.items) if (it.key) [self.selected addObject:it.key];
    [self.grid reloadData];
    [self updateBar];
}

- (void)updateBar {
    NSUInteger n = self.selected.count;
    [self.selectBtn setTitle:(n == self.items.count && n > 0) ? @"取消全选" : @"全选" forState:UIControlStateNormal];
    [self.saveBtn setTitle:n ? [NSString stringWithFormat:@"保存 %lu 项", (unsigned long)n] : @"保存所选" forState:UIControlStateNormal];
    self.saveBtn.enabled = n > 0 && !self.busy;
    self.saveBtn.alpha = self.saveBtn.enabled ? 1 : 0.5;
}

- (void)onInputID {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"输入商品 ID" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.placeholder = @"例如 1091430207724";
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"读取" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSString *t = a.textFields.firstObject.text;
        NSCharacterSet *nonDigit = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        t = [[t componentsSeparatedByCharactersInSet:nonDigit] componentsJoinedByString:@""];
        if (t.length < 6) return;
        self.itemId = t;
        [self reloadMedia];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)saveSelected {
    XYD_LOG(@"save tap busy=%d items=%lu selected=%lu", self.busy, (unsigned long)self.items.count, (unsigned long)self.selected.count);
    if (self.busy) return;
    NSMutableArray *arr = [NSMutableArray array];
    for (XYDMediaItem *it in self.items) if ([self.selected containsObject:it.key]) [arr addObject:it];
    if (!arr.count) { XYDShowToast(@"先选择要保存的媒体"); return; }
    self.busy = YES;
    [self updateBar];
    __weak typeof(self) weakSelf = self;
    XYDSaveMediaItems(arr, ^(NSInteger done, NSInteger total, NSString *status) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.status.text = [NSString stringWithFormat:@"保存中 %ld/%ld %@", (long)done, (long)total, status ?: @""];
    }, ^(NSInteger saved, NSInteger failed, NSString *message) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.busy = NO;
        XYD_LOG(@"save done ok=%ld failed=%ld msg=%@", (long)saved, (long)failed, message);
        self.status.text = failed ? [NSString stringWithFormat:@"完成：成功 %ld，失败 %ld", (long)saved, (long)failed]
                                  : [NSString stringWithFormat:@"已保存 %ld 项到相册", (long)saved];
        if (saved > 0) [self.selected removeAllObjects];
        [self.grid reloadData];
        [self updateBar];
        XYDShowToast(failed ? [NSString stringWithFormat:@"保存完成，失败 %ld 项", (long)failed]
                            : [NSString stringWithFormat:@"已保存 %ld 项", (long)saved]);
    });
}
@end
