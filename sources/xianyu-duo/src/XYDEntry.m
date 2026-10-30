#import "XYDCommon.h"

#pragma mark - ball

@interface XYDBallHost : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIButton *ball;
@property (nonatomic) CGPoint startCenter;
@property (nonatomic) BOOL suppressTap;
@end

@implementation XYDBallHost

+ (instancetype)shared {
    static XYDBallHost *h; static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [XYDBallHost new]; });
    return h;
}

- (UIWindow *)keyWindow {
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)sc).windows) if (w.isKeyWindow) return w;
            }
        }
    }
    return UIApplication.sharedApplication.keyWindow;
}

- (void)install {
    if (self.ball.superview) return;
    if (!XYDPrefBool(@"showBall", YES)) return;
    UIWindow *win = [self keyWindow];
    if (!win) return;

    CGFloat size = 34;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(0, 0, size, size);
    b.backgroundColor = [UIColor colorWithRed:0.99 green:0.35 blue:0.20 alpha:0.88];
    b.layer.cornerRadius = size / 2;
    b.layer.masksToBounds = NO;
    b.layer.shadowColor = UIColor.blackColor.CGColor;
    b.layer.shadowOpacity = 0.25;
    b.layer.shadowOffset = CGSizeMake(0, 2);
    b.layer.shadowRadius = 4;
    UIImage *icon = [UIImage systemImageNamed:@"arrow.down.to.line" withConfiguration:
                     [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]];
    if (!icon) icon = [UIImage systemImageNamed:@"square.and.arrow.down" withConfiguration:
                       [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]];
    [b setImage:icon forState:UIControlStateNormal];
    b.tintColor = UIColor.whiteColor;
    b.accessibilityLabel = @"存图";
    [b addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    pan.delegate = self;
    [b addGestureRecognizer:pan];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    lp.minimumPressDuration = 0.55;
    [b addGestureRecognizer:lp];

    CGFloat bx = XYDPrefDouble(@"ballX", -1);
    CGFloat by = XYDPrefDouble(@"ballY", -1);
    CGPoint c = CGPointMake(win.bounds.size.width - 40, win.bounds.size.height * 0.62);
    if (bx >= 0 && by >= 0) c = CGPointMake(bx * win.bounds.size.width, by * win.bounds.size.height);
    c.x = MAX(size / 2 + 4, MIN(win.bounds.size.width - size / 2 - 4, c.x));
    c.y = MAX(win.safeAreaInsets.top + size / 2 + 4, MIN(win.bounds.size.height - win.safeAreaInsets.bottom - size / 2 - 4, c.y));
    b.center = c;
    b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [win addSubview:b];
    [win bringSubviewToFront:b];
    self.ball = b;
    XYD_LOG(@"ball installed");
}

- (void)uninstall {
    [self.ball removeFromSuperview];
    self.ball = nil;
}

- (void)onTap {
    if (self.suppressTap) { self.suppressTap = NO; return; }
    UIViewController *top0 = XYDTopViewController();
    if ([top0 isKindOfClass:[XYDPanelVC class]]) return;
    if ([top0 isKindOfClass:[UINavigationController class]] &&
        [((UINavigationController *)top0).topViewController isKindOfClass:[XYDPanelVC class]]) return;
    XYDStore *st = [XYDStore shared];
    XYDPanelVC *p = [[XYDPanelVC alloc] initWithItemId:st.accountItemId];
    p.modalPresentationStyle = UIModalPresentationPageSheet;
    [XYDTopViewController() presentViewController:p animated:YES completion:nil];
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    self.suppressTap = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.suppressTap = NO;
    });
    XYDSettingsVC *s = [XYDSettingsVC new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:s];
    s.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                       target:self action:@selector(closeSettings)];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [XYDTopViewController() presentViewController:nav animated:YES completion:nil];
}

- (void)closeSettings {
    UIViewController *top = XYDTopViewController();
    [top dismissViewControllerAnimated:YES completion:nil];
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIWindow *win = (UIWindow *)self.ball.superview;
    if (!win) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        self.startCenter = self.ball.center;
    }
    CGPoint t = [g translationInView:win];
    CGPoint c = CGPointMake(self.startCenter.x + t.x, self.startCenter.y + t.y);
    CGFloat size = self.ball.bounds.size.width;
    c.x = MAX(size / 2 + 4, MIN(win.bounds.size.width - size / 2 - 4, c.x));
    c.y = MAX(win.safeAreaInsets.top + size / 2 + 4, MIN(win.bounds.size.height - win.safeAreaInsets.bottom - size / 2 - 4, c.y));
    self.ball.center = c;
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        XYDSetPref(@"ballX", @(c.x / win.bounds.size.width));
        XYDSetPref(@"ballY", @(c.y / win.bounds.size.height));
        // 吸边
        CGFloat targetX = c.x < win.bounds.size.width / 2 ? size / 2 + 6 : win.bounds.size.width - size / 2 - 6;
        [UIView animateWithDuration:0.2 animations:^{
            self.ball.center = CGPointMake(targetX, c.y);
        } completion:^(BOOL f) {
            XYDSetPref(@"ballX", @(targetX / win.bounds.size.width));
        }];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o { return YES; }
@end

void XYDInstallFloatingBall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [[XYDBallHost shared] install]; });
}

void XYDUninstallFloatingBall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [[XYDBallHost shared] uninstall]; });
}

#pragma mark - my page pill

@interface XYDBallHost (SettingsOpen)
- (void)openSettings;
@end

static UIButton *gMyPageButton;
static NSMapTable *gMyPageMoveOrig;

static IMP XYDEntryOriginal(id self) {
    Class c = object_getClass(self);
    while (c) {
        NSValue *v = [gMyPageMoveOrig objectForKey:c];
        if (v) return (IMP)[v pointerValue];
        c = class_getSuperclass(c);
    }
    return NULL;
}

static void xyd_userInfoDidMove(id self, SEL _cmd) {
    IMP orig = XYDEntryOriginal(self);
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
    @try {
    if (!XYDPrefBool(@"myPageEntry", YES)) { [gMyPageButton removeFromSuperview]; gMyPageButton = nil; return; }
    if (![self isKindOfClass:[UIView class]]) return;
    NSString *cn = NSStringFromClass([self class]) ?: @"";
    if (![cn containsString:@"IFMatrix"]) return;   // 只在“我的”页，不要注入商品详情卖家卡片
    UIView *host = (UIView *)self;
    if (gMyPageButton && gMyPageButton.superview == host) return;
    [gMyPageButton removeFromSuperview];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(host.bounds.size.width - 86, 8, 76, 28);
    b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.18];
    b.layer.cornerRadius = 14;
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [b setTitle:@"存图设置" forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [b addTarget:[XYDBallHost shared] action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
    [host addSubview:b];
    gMyPageButton = b;
    } @catch (__unused NSException *e) {}
}

@implementation XYDBallHost (SettingsOpen)
- (void)openSettings {
    XYDSettingsVC *s = [XYDSettingsVC new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:s];
    s.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                       target:self action:@selector(closeSettings)];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [XYDTopViewController() presentViewController:nav animated:YES completion:nil];
}
@end

static void XYDInstallUserInfoHook(NSString *name) {
    Class c = NSClassFromString(name);
    if (!c) return;
    SEL sel = NSSelectorFromString(@"didMoveToWindow");
    if (!class_getInstanceMethod(c, sel)) return;
    IMP orig = NULL;
    if (XYDHookOnce(name, @"didMoveToWindow", (IMP)xyd_userInfoDidMove, &orig)) {
        if (orig) [gMyPageMoveOrig setObject:[NSValue valueWithPointer:orig] forKey:c];
    }
}

void XYDInstallEntry(void) {
    if (!gMyPageMoveOrig) {
        gMyPageMoveOrig = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                                               valueOptions:NSPointerFunctionsStrongMemory];
    }
    // 只挂已知的 4 个类，绝不在启动路径枚举全部 UIView 子类（会拖慢/看门狗杀进程）
    NSArray *names = @[@"IFMatrix.FloatingUserInfoContentView",
                       @"IFMatrix.TopUserInfoContentView",
                       @"IFMatrix.WorkspaceFloatingUserInfoContentView",
                       @"IFMatrix.WorkspaceTopUserInfoContentView"];
    for (NSString *n in names) XYDInstallUserInfoHook(n);
}
