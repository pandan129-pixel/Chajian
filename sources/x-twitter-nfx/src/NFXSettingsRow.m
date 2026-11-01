// NFXSettingsRow.dylib
//
// X 12.39 replaced T1SettingsViewController with XSettings.SettingsListViewController
// backed by XDesignSystem.ListItems + a UIKit diffable data source. The list
// model is Swift (SettingsSectionDefinition/SettingsRowDefinition), so the old
// 7.2 row insertion cannot be restored directly and wrapping the diffable data
// source breaks X's snapshot updates.
//
// This dylib therefore keeps an always-present, native-looking NFX row as the
// table footer of the Settings list, and keeps:
//   - two-finger long press -> 7.2 settings (fallback)
//   - compact inline action spacing (X 12.39 ships 7 buttons; share got clipped)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void NFXLog(NSString* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString* msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"nfx-row.log"];
    FILE* f = fopen(path.fileSystemRepresentation, "a");
    if (f) { fprintf(f, "%s\n", msg.UTF8String); fclose(f); }
}

static id ReadIvar(id obj, const char* name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable([obj class], name);
    if (!iv) return nil;
    return object_getIvar(obj, iv);
}

static NSString* BHTString(NSString* key, NSString* fallback) {
    Class c = NSClassFromString(@"BHTBundle");
    if (c && [c respondsToSelector:@selector(sharedBundle)]) {
        id bundle = ((id (*)(id, SEL))objc_msgSend)((id)c, sel_registerName("sharedBundle"));
        SEL sel = sel_registerName("localizedStringForKey:");
        if (bundle && [bundle respondsToSelector:sel]) {
            id v = ((id (*)(id, SEL, id))objc_msgSend)(bundle, sel, key);
            if ([v isKindOfClass:[NSString class]] && [v length] && ![v isEqualToString:key]) return v;
        }
    }
    return fallback;
}

static id MakeSettingsController(id account) {
    Class c = NSClassFromString(@"ModernSettingsViewController");
    if (!c) return nil;
    SEL sel = sel_registerName("initWithAccount:");
    if (![c instancesRespondToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)([c alloc], sel, account);
}

@interface NFXPresenter : NSObject
+ (instancetype)shared;
@property (nonatomic, weak) UIViewController* host;
- (void)longPress:(UILongPressGestureRecognizer*)g;
- (void)openRow:(id)sender;
- (void)presentFrom:(UIViewController*)from;
@end

@implementation NFXPresenter
+ (instancetype)shared { static NFXPresenter* s; static dispatch_once_t o; dispatch_once(&o, ^{ s=[self new]; }); return s; }

- (UIWindow*)keyWindow {
    for (UIScene* s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow* w in ((UIWindowScene*)s).windows) if (w.isKeyWindow) return w;
    }
    return UIApplication.sharedApplication.keyWindow;
}

- (id)account {
    Class c = objc_getClass("T1AccountsViewController");
    if (!c) return nil;
    SEL sel = sel_registerName("currentAccount");
    if (![c respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)c, sel);
}

- (void)presentFrom:(UIViewController*)from {
    if (!from) return;
    id vc = MakeSettingsController([self account]);
    if (!vc) { NFXLog(@"[open] 7.2 settings unavailable"); return; }
    UINavigationController* nav = [[UINavigationController alloc] initWithRootViewController:vc];
    ((UIViewController*)vc).navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                     target:self action:@selector(done:)];
    [from presentViewController:nav animated:YES completion:nil];
    NFXLog(@"[open] presented from %@", NSStringFromClass([from class]));
}

- (void)openRow:(id)sender {
    UIViewController* from = self.host;
    if (!from) {
        from = [self keyWindow].rootViewController;
        while (from.presentedViewController) from = from.presentedViewController;
    }
    [self presentFrom:from];
}

- (void)longPress:(UILongPressGestureRecognizer*)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIViewController* top = [self keyWindow].rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    [self presentFrom:top];
}

- (void)done:(id)s {
    UIViewController* top = [self keyWindow].rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    [top dismissViewControllerAnimated:YES completion:nil];
}
@end

static void InstallGesture(void) {
    UIWindow* w = nil;
    for (UIScene* s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow* win in ((UIWindowScene*)s).windows) if (win.isKeyWindow) { w = win; break; }
        if (w) break;
    }
    if (!w) return;
    for (UIGestureRecognizer* g in w.gestureRecognizers) {
        if ([g isKindOfClass:[UILongPressGestureRecognizer class]] &&
            ((UILongPressGestureRecognizer*)g).numberOfTouchesRequired == 2) return;
    }
    UILongPressGestureRecognizer* g =
        [[UILongPressGestureRecognizer alloc] initWithTarget:[NFXPresenter shared]
                                                     action:@selector(longPress:)];
    g.minimumPressDuration = 1.2;
    g.numberOfTouchesRequired = 2;
    g.cancelsTouchesInView = NO;
    [w addGestureRecognizer:g];
    NFXLog(@"[gesture] installed on %@", NSStringFromClass([w class]));
}

static UITableView* SettingsTable(UIViewController* vc) {
    id list = ReadIvar(vc, "list");
    id tv = ReadIvar(list, "tableView");
    if ([tv isKindOfClass:[UITableView class]]) return (UITableView*)tv;
    NSMutableArray* stack = [NSMutableArray arrayWithObject:vc.view];
    UITableView* best = nil;
    while (stack.count) {
        UIView* v = stack.lastObject; [stack removeLastObject];
        if ([v isKindOfClass:[UITableView class]]) best = (UITableView*)v;
        for (UIView* s in v.subviews) [stack addObject:s];
    }
    return best;
}

static char kNFXFooterKey;

static UIView* MakeFooterRow(UITableView* t, UIViewController* host) {
    CGFloat w = t.bounds.size.width;
    CGFloat h = 88.0;
    UIView* f = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    f.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    f.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];

    UIButton* btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = f.bounds;
    btn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [btn addTarget:NFXPresenter.shared action:@selector(openRow:) forControlEvents:UIControlEventTouchUpInside];
    btn.accessibilityLabel = @"NFX 设置";

    UILabel* logo = [[UILabel alloc] initWithFrame:CGRectMake(14, 18, 34, 30)];
    logo.text = @"\U0001D54F";
    logo.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    logo.textColor = [UIColor secondaryLabelColor];
    logo.textAlignment = NSTextAlignmentCenter;
    [btn addSubview:logo];

    UILabel* title = [[UILabel alloc] initWithFrame:CGRectMake(60, 16, w - 110, 22)];
    title.text = BHTString(@"NFB_SETTINGS_TITLE", @"NFX");
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textColor = [UIColor labelColor];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [btn addSubview:title];

    UILabel* sub = [[UILabel alloc] initWithFrame:CGRectMake(60, 40, w - 108, 40)];
    sub.text = BHTString(@"NFB_SETTINGS_DETAIL", @"自定义你的推特：隐藏广告、启用更多高级功能等。");
    sub.font = [UIFont systemFontOfSize:15];
    sub.textColor = [UIColor secondaryLabelColor];
    sub.numberOfLines = 2;
    sub.lineBreakMode = NSLineBreakByWordWrapping;
    sub.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [btn addSubview:sub];

    UIImageView* chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.tintColor = [UIColor tertiaryLabelColor];
    chevron.frame = CGRectMake(w - 32, 36, 12, 16);
    chevron.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    [btn addSubview:chevron];

    UIView* line = [[UIView alloc] initWithFrame:CGRectMake(16, 0, w - 16, 0.5)];
    line.backgroundColor = [UIColor separatorColor];
    line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [btn addSubview:line];

    [f addSubview:btn];
    return f;
}

static void InstallRow(UIViewController* vc) {
    UITableView* t = SettingsTable(vc);
    if (!t) return;
    if ([t numberOfSections] <= 0) return;      // wait for the list
    UIView* footer = (UIView*)objc_getAssociatedObject(t, &kNFXFooterKey);
    if (footer) {
        if (t.tableHeaderView != footer) t.tableHeaderView = footer;
        NFXPresenter.shared.host = vc;
        return;
    }
    footer = MakeFooterRow(t, vc);
    objc_setAssociatedObject(t, &kNFXFooterKey, footer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    t.tableHeaderView = footer;
    NFXPresenter.shared.host = vc;
    NFXLog(@"[row] header installed sections=%ld rows0=%ld",
           (long)[t numberOfSections],
           (long)[t numberOfRowsInSection:0]);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CGRect inWindow = [footer convertRect:footer.bounds toView:nil];
        NFXLog(@"[row] header check inWindow=%d frame=%@",
               footer.window != nil, NSStringFromCGRect(inWindow));
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSString* flag = [NSTemporaryDirectory() stringByAppendingPathComponent:@"nfx-rowtest"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:flag]) return;
        [[NSFileManager defaultManager] removeItemAtPath:flag error:nil];
        UIButton* btn = nil;
        for (UIView* s in footer.subviews) if ([s isKindOfClass:[UIButton class]]) { btn = (UIButton*)s; break; }
        NFXLog(@"[rowtest] header=%@ btn=%@", NSStringFromClass([footer class]), btn ? @"yes" : @"no");
        [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController* p = vc.presentedViewController;
            NFXLog(@"[rowtest] presented=%@", p ? NSStringFromClass([p class]) : @"nil");
        });
    });
}

static void (*origAppear)(id, SEL, BOOL);
static void newAppear(id self, SEL _cmd, BOOL animated) {
    origAppear(self, _cmd, animated);
    for (int i = 1; i <= 12; i++)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ InstallRow((UIViewController*)self); });
}
static void InstallSettingsHook(void) {
    static BOOL done = NO;
    if (done) return;
    Class c = objc_getClass("XSettings.SettingsListViewController");
    if (!c) return;
    SEL sel = sel_registerName("viewDidAppear:");
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    origAppear = (void*)method_getImplementation(m);
    class_replaceMethod(c, sel, (IMP)newAppear, method_getTypeEncoding(m));
    NFXLog(@"[row] hooked settings VC");
    done = YES;
}

typedef void (*NFXLayoutFn)(id, SEL, CGPoint, double, double, id, id, double, double, BOOL);
static NFXLayoutFn origInlineLayout;
static void newInlineLayout(id self, SEL _cmd, CGPoint origin, double cw, double ch,
                            id wc, id ac, double minSp, double maxSp, BOOL pad) {
    static int logs;
    double inMin = minSp, inMax = maxSp;
    if (maxSp > 8.0) maxSp = 8.0;
    if (minSp > maxSp) minSp = maxSp;
    origInlineLayout(self, _cmd, origin, cw, ch, wc, ac, minSp, maxSp, pad);

    // X 12.39 places buttons on fixed slots; with BHT's extra download button the
    // last one (share) is clipped. Re-pack the same buttons with uniform spacing
    // inside the row width.
    NSArray* btnList = nil;
    @try { btnList = [self valueForKey:@"inlineActionButtons"]; } @catch (__unused NSException* e) {}
    if (btnList.count >= 2) {
        CGFloat total = 0;
        for (UIButton* b in btnList) total += b.frame.size.width;
        NSInteger gaps = (NSInteger)btnList.count - 1;
        CGFloat avail = cw - total;
        CGFloat gap = avail / (CGFloat)gaps;
        if (gap > 24.0) gap = 24.0;
        if (gap < 2.0) gap = 2.0;
        CGFloat used = total + gap * gaps;
        CGFloat x = origin.x + (cw - used) / 2.0;
        for (UIButton* b in btnList) {
            CGRect fr = b.frame;
            fr.origin.x = x;
            b.frame = fr;
            x += fr.size.width + gap;
        }
    }

    if (logs < 8) {
        logs++;
        NSArray* btns = nil;
        @try { btns = [self valueForKey:@"inlineActionButtons"]; } @catch (__unused NSException* e) {}
        NSMutableArray* frames = [NSMutableArray array];
        for (UIButton* b in btns) {
            double extra = -1;
            if ([b respondsToSelector:@selector(extraWidth)]) {
                @try { extra = ((double (*)(id, SEL))objc_msgSend)(b, @selector(extraWidth)); } @catch (__unused NSException* e) {}
            }
            [frames addObject:[NSString stringWithFormat:@"%@ x=%.1f w=%.1f extra=%.1f",
                               NSStringFromClass([b class]), b.frame.origin.x, b.frame.size.width, extra]];
        }
        NFXLog(@"[layout] in(min=%.1f,max=%.1f) used(min=%.1f,max=%.1f) cw=%.1f buttons=%@",
               inMin, inMax, minSp, maxSp, cw, [frames componentsJoinedByString:@" | "]);
    }
}
static void InstallInlineLayoutFix(void) {
    static BOOL done = NO;
    if (done) return;
    Class c = objc_getClass("TTAStatusInlineActionsView");
    if (!c) return;
    SEL sel = sel_registerName("_t1_layoutInlineActionButtonsAtOrigin:forContentWidth:contentHeight:buttonWidthCalculator:buttonAlignmentCalculator:minimumSpacing:maximumSpacing:shouldAddRightSidePadding:");
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    origInlineLayout = (void*)method_getImplementation(m);
    class_replaceMethod(c, sel, (IMP)newInlineLayout, method_getTypeEncoding(m));
    NFXLog(@"[layout] hooked inline action layout");
    done = YES;
}

__attribute__((constructor)) static void nfx_init(void) {
    for (int i = 0; i <= 120; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           InstallSettingsHook();
                           InstallInlineLayoutFix();
                           if (i >= 6) InstallGesture();
                       });
    }
    InstallSettingsHook();
    InstallInlineLayoutFix();
    [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification* n) {
                                                      InstallSettingsHook();
                                                      InstallInlineLayoutFix();
                                                      InstallGesture();
                                                  }];
}
