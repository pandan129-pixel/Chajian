#import "XYDCommon.h"

#pragma mark - helpers

static BOOL XYDIsAdView(UIView *v) {
    NSString *cn = NSStringFromClass([v class]);
    if (!cn.length) return NO;
    static NSArray<NSString *> *prefixes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefixes = @[@"GDT", @"BeiZi", @"BUAd", @"CSJ", @"Pangle", @"KWAd", @"BaiduMobAd",
                     @"Sigmob", @"Mintegral", @"AdMaterial", @"AdView", @"AdCell", @"AdBanner",
                     @"AdContainer", @"AdNative", @"AdSplash", @"AdWebView", @"AdWeb",
                     @"Promotion", @"Advert", @"FishSplashAd", @"SplashAd", @"AdComponent", @"AdCard", @"FeedAd", @"AdItem"];
    });
    for (NSString *p in prefixes) {
        if ([cn hasPrefix:p]) return YES;
        if ([cn containsString:p] && [cn rangeOfString:p].location > 0) {
            // 类名内部出现，需要更严格：要求前面不是小写字母（避免 ShadowAd 之类误判）
            NSUInteger i = [cn rangeOfString:p].location;
            unichar prev = [cn characterAtIndex:i - 1];
            if (prev >= 'A' && prev <= 'Z') return YES;
        }
    }
    return NO;
}

static BOOL XYDIsAdLabel(UIView *v) {
    NSString *t = nil;
    if ([v isKindOfClass:[UILabel class]]) t = ((UILabel *)v).text;
    else if ([v isKindOfClass:[UIButton class]]) t = [((UIButton *)v) titleForState:UIControlStateNormal];
    if (!t.length || t.length > 6) return NO;
    return [t isEqualToString:@"广告"] || [t isEqualToString:@"赞助"] ||
           [t isEqualToString:@"AD"] || [t isEqualToString:@"推广"];
}

static BOOL XYDIsAdContainerText(UIView *v) {
    if (![v isKindOfClass:[UILabel class]]) return NO;
    NSString *t = ((UILabel *)v).text;
    if (!t.length || t.length > 12) return NO;
    return [t containsString:@"广告"] || [t containsString:@"赞助"] || [t isEqualToString:@"推广"];
}

void XYDScanAndHideAds(UIView *root) {
    if (!root || !XYDPrefBool(@"enabled", YES) || !XYDPrefBool(@"cleanMyPage", YES)) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSMutableArray<UIView *> *marked = [NSMutableArray array];
    NSInteger budget = 700;
    while (stack.count && budget-- > 0) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v.hidden) continue;
        if (XYDIsAdView(v)) { [marked addObject:v]; continue; }
        if (XYDIsAdLabel(v) || XYDIsAdContainerText(v)) {
            UIView *p = v;
            for (int i = 0; i < 4 && p; i++) {
                if ([p isKindOfClass:[UITableViewCell class]] || [p isKindOfClass:[UICollectionViewCell class]]) {
                    [marked addObject:p]; break;
                }
                p = p.superview;
            }
        }
        if (v.subviews.count) [stack addObjectsFromArray:v.subviews];
    }
    for (UIView *v in marked) {
        if (!v.hidden) {
            v.hidden = YES;
            XYD_LOG(@"hide ad view %@", NSStringFromClass([v class]));
        }
    }
}

#pragma mark - per-class original IMP

static NSMapTable *XYDOrigMap(void) {
    return [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                                 valueOptions:NSPointerFunctionsStrongMemory];
}

static IMP XYDOriginalFor(NSMapTable *map, id self) {
    Class c = object_getClass(self);
    while (c) {
        NSValue *v = [map objectForKey:c];
        if (v) return (IMP)[v pointerValue];
        c = class_getSuperclass(c);
    }
    return NULL;
}

#pragma mark - splash / hot start

static BOOL XYDBlockSplash(void) {
    return XYDPrefBool(@"enabled", YES) && XYDPrefBool(@"blockSplash", YES);
}

#define XYD_NOOP_VOID(name) \
    static void (*orig_##name)(id, SEL); \
    static void xyd_##name(id self, SEL _cmd) { \
        if (!XYDBlockSplash()) { if (orig_##name) orig_##name(self, _cmd); return; } \
        XYD_LOG(@"blocked %@", NSStringFromSelector(_cmd)); \
    }

XYD_NOOP_VOID(postHotStartRefreshHomeNotification)

// 开屏整套生命周期必须放行：App 在 load/show/finish 里维护状态栏，
// 拦任何一步都可能让首页状态栏永久消失。这里只把广告窗口视觉隐藏。
static void (*orig_loadAd)(id, SEL);
static void xyd_loadAd(id self, SEL _cmd) {
    if (orig_loadAd) orig_loadAd(self, _cmd);
}

static void (*orig_showSplashView)(id, SEL);
static void xyd_showSplashView(id self, SEL _cmd) {
    if (orig_showSplashView) orig_showSplashView(self, _cmd);
}

static void (*orig_fishSplashAdDidShow)(id, SEL);
static void xyd_fishSplashAdDidShow(id self, SEL _cmd) {
    if (orig_fishSplashAdDidShow) orig_fishSplashAdDidShow(self, _cmd);
}

static void (*orig_fishSplashAdDidFinish)(id, SEL);
static void xyd_fishSplashAdDidFinish(id self, SEL _cmd) {
    if (orig_fishSplashAdDidFinish) orig_fishSplashAdDidFinish(self, _cmd);
}

static void (*orig_requestHotStartDecide)(id, SEL, long long);
static void xyd_requestHotStartDecide(id self, SEL _cmd, long long flag) {
    if (!XYDBlockSplash()) {
        if (orig_requestHotStartDecide) orig_requestHotStartDecide(self, _cmd, flag);
        return;
    }
    XYD_LOG(@"blocked requestHotStartDecide:");
}

static void (*orig_setDisableHotStartAd)(id, SEL, BOOL);
static void xyd_setDisableHotStartAd(id self, SEL _cmd, BOOL v) {
    if (!XYDBlockSplash()) {
        if (orig_setDisableHotStartAd) orig_setDisableHotStartAd(self, _cmd, v);
    }
}

static void (*orig_handleAppWillEnterForeground)(id, SEL);
static void xyd_handleAppWillEnterForeground(id self, SEL _cmd) {
    // 保留系统原有前台记账逻辑；热启动请求由 requestHotStartDecide: 拦截
    if (orig_handleAppWillEnterForeground) orig_handleAppWillEnterForeground(self, _cmd);
}

static void (*orig_handleHotStartResult)(id, SEL, id, long long);
static void xyd_handleHotStartResult(id self, SEL _cmd, id result, long long minutes) {
    if (!XYDBlockSplash()) {
        if (orig_handleHotStartResult) orig_handleHotStartResult(self, _cmd, result, minutes);
        return;
    }
    XYD_LOG(@"blocked handleHotStartDecideResult");
}

static BOOL (*orig_disableHotStartAd)(id, SEL);
static BOOL xyd_disableHotStartAd(id self, SEL _cmd) {
    if (!XYDBlockSplash()) return orig_disableHotStartAd ? orig_disableHotStartAd(self, _cmd) : NO;
    return YES;
}

static void (*orig_splashLayout)(id, SEL);
static void xyd_splashLayout(id self, SEL _cmd) {
    if (orig_splashLayout) orig_splashLayout(self, _cmd);
    if (!XYDBlockSplash()) return;
    if ([self isKindOfClass:[UIView class]]) {
        UIView *v = (UIView *)self;
        v.hidden = YES;
        v.alpha = 0;
    }
}

static void (*orig_splashDidMove)(id, SEL);
static void xyd_splashDidMove(id self, SEL _cmd) {
    if (orig_splashDidMove) orig_splashDidMove(self, _cmd);
    if (!XYDBlockSplash()) return;
    if ([self isKindOfClass:[UIView class]]) ((UIView *)self).hidden = YES;
}

static void (*orig_splashAddSubview)(id, SEL, UIView *);
static void xyd_splashAddSubview(id self, SEL _cmd, UIView *v) {
    if (orig_splashAddSubview) orig_splashAddSubview(self, _cmd, v);
    if (!XYDBlockSplash()) return;
    if ([self isKindOfClass:[UIView class]]) ((UIView *)self).hidden = YES;
}

#pragma mark - feed

static const void *kXYDHiddenViewsKey = &kXYDHiddenViewsKey;
static NSMapTable *gWFLayoutOrig;
static NSMapTable *gWFPrepareOrig;

static void xyd_wfLayout(id self, SEL _cmd) {
    IMP orig = XYDOriginalFor(gWFLayoutOrig, self);
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
    if (!XYDPrefBool(@"enabled", YES) || !XYDPrefBool(@"blockFeed", YES)) return;
    if (![self isKindOfClass:[UIView class]]) return;

    NSArray *cached = objc_getAssociatedObject(self, kXYDHiddenViewsKey);
    if (cached) {
        for (UIView *v in cached) v.hidden = YES;
        return;
    }

    UIView *cell = (UIView *)self;
    NSMutableArray *hide = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:cell];
    NSInteger budget = 120;
    BOOL adBadge = NO;
    while (stack.count && budget-- > 0) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v == cell) { [stack addObjectsFromArray:v.subviews]; continue; }
        if (XYDIsAdLabel(v)) { adBadge = YES; break; }
        if (XYDIsAdView(v)) { [hide addObject:v]; continue; }
        if (v.subviews.count) [stack addObjectsFromArray:v.subviews];
    }
    if (adBadge) {
        UIView *content = [(UICollectionViewCell *)cell contentView] ?: cell;
        [hide addObject:content];
    }
    if (hide.count) {
        objc_setAssociatedObject(self, kXYDHiddenViewsKey, [hide copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (UIView *v in hide) v.hidden = YES;
        XYD_LOG(@"feed ad cell hidden (%lu views)", (unsigned long)hide.count);
    } else {
        objc_setAssociatedObject(self, kXYDHiddenViewsKey, @[], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void xyd_wfPrepare(id self, SEL _cmd) {
    NSArray *cached = objc_getAssociatedObject(self, kXYDHiddenViewsKey);
    for (UIView *v in cached) v.hidden = NO;
    objc_setAssociatedObject(self, kXYDHiddenViewsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    IMP orig = XYDOriginalFor(gWFPrepareOrig, self);
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
}

#pragma mark - my page entry anchor

static NSMapTable *gMyPageLayoutOrig;
static void xyd_userInfoLayout(id self, SEL _cmd) {
    IMP orig = XYDOriginalFor(gMyPageLayoutOrig, self);
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
    if (!XYDPrefBool(@"enabled", YES) || !XYDPrefBool(@"cleanMyPage", YES)) return;
    if (![NSStringFromClass([self class]) containsString:@"IFMatrix"]) return;
    static NSTimeInterval lastScan = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - lastScan < 1.5) return;
    lastScan = now;
    UIView *root = self;
    @try {
        UIResponder *r = (UIResponder *)self;
        while (r && ![r isKindOfClass:[UIViewController class]]) r = r.nextResponder;
        if ([r isKindOfClass:[UIViewController class]]) root = ((UIViewController *)r).view;
    } @catch (__unused NSException *e) {}
    dispatch_async(dispatch_get_main_queue(), ^{ XYDScanAndHideAds(root); });
}

#pragma mark - install

void XYDApplyAdPrefs(void) {
    // 预留：运行时切换开关无需重装 hook（handler 内实时读 prefs）
}

void XYDInstallSplashHooks(void) {
    if (!XYDPrefBool(@"blockSplash", YES)) return;
    XYDHookFirst(@[@"FMSplashModule", @"IFMSplashModule"], @"loadAd", (IMP)xyd_loadAd, (IMP *)&orig_loadAd);
    XYDHookFirst(@[@"FMSplashModule", @"IFMSplashModule"], @"showSplashView", (IMP)xyd_showSplashView, (IMP *)&orig_showSplashView);
    XYDHookFirst(@[@"FMSplashModule", @"IFMSplashModule"], @"fishSplashAdDidShow", (IMP)xyd_fishSplashAdDidShow, (IMP *)&orig_fishSplashAdDidShow);
    XYDHookFirst(@[@"FMSplashModule", @"IFMSplashModule"], @"fishSplashAdDidFinish", (IMP)xyd_fishSplashAdDidFinish, (IMP *)&orig_fishSplashAdDidFinish);

    XYDHookOnce(@"FMHomeRefreshHelper", @"handleAppWillEnterForeground", (IMP)xyd_handleAppWillEnterForeground, (IMP *)&orig_handleAppWillEnterForeground);
    XYDHookOnce(@"FMHomeRefreshHelper", @"requestHotStartDecide:", (IMP)xyd_requestHotStartDecide, (IMP *)&orig_requestHotStartDecide);
    XYDHookOnce(@"FMHomeRefreshHelper", @"handleHotStartDecideResult:backgroundMinutes:", (IMP)xyd_handleHotStartResult, (IMP *)&orig_handleHotStartResult);
    XYDHookOnce(@"FMHomeRefreshHelper", @"postHotStartRefreshHomeNotification", (IMP)xyd_postHotStartRefreshHomeNotification, (IMP *)&orig_postHotStartRefreshHomeNotification);

    XYDHookFirst(@[@"_TtC6FishAd18FishSplashAdWindow", @"FishSplashAdWindow"], @"layoutSubviews", (IMP)xyd_splashLayout, (IMP *)&orig_splashLayout);
    XYDHookFirst(@[@"_TtC6FishAd18FishSplashAdWindow", @"FishSplashAdWindow"], @"didMoveToWindow", (IMP)xyd_splashDidMove, (IMP *)&orig_splashDidMove);
    XYDHookFirst(@[@"_TtC6FishAd18FishSplashAdWindow", @"FishSplashAdWindow"], @"addSubview:", (IMP)xyd_splashAddSubview, (IMP *)&orig_splashAddSubview);

    XYDHookFirst(@[@"_TtC6FishAd18FishSplashAdConfig", @"FishSplashAdConfig"], @"disableHotStartAd", (IMP)xyd_disableHotStartAd, (IMP *)&orig_disableHotStartAd);
    XYDHookFirst(@[@"_TtC6FishAd18FishSplashAdConfig", @"FishSplashAdConfig"], @"setDisableHotStartAd:", (IMP)xyd_setDisableHotStartAd, (IMP *)&orig_setDisableHotStartAd);
}

void XYDInstallFeedHooks(void) {
    if (XYDPrefBool(@"blockFeed", YES)) {
        if (!gWFLayoutOrig) gWFLayoutOrig = XYDOrigMap();
        if (!gWFPrepareOrig) gWFPrepareOrig = XYDOrigMap();
        NSArray *feedCells = @[@"WaterfallItemCell", @"SingleRowItemCell", @"HomeCardCell", @"SearchResultCardCell"];
        XYDHookAllSubclassesOf([UICollectionViewCell class], feedCells, @"layoutSubviews",
                               (IMP)xyd_wfLayout, gWFLayoutOrig);
        XYDHookAllSubclassesOf([UICollectionViewCell class], feedCells, @"prepareForReuse",
                               (IMP)xyd_wfPrepare, gWFPrepareOrig);
    }
    if (XYDPrefBool(@"cleanMyPage", YES)) {
        if (!gMyPageLayoutOrig) gMyPageLayoutOrig = XYDOrigMap();
        XYDHookAllSubclassesOf([UIView class],
            @[@"IFMatrix.FloatingUserInfoContentView", @"IFMatrix.TopUserInfoContentView",
              @"IFMatrix.WorkspaceFloatingUserInfoContentView", @"IFMatrix.WorkspaceTopUserInfoContentView"],
            @"layoutSubviews", (IMP)xyd_userInfoLayout, gMyPageLayoutOrig);
    }
}

void XYDInstallAdBlock(void) {
    XYDInstallSplashHooks();
    XYDInstallFeedHooks();
}
