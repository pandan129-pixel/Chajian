// NFXSettingsGesture.dylib
//
// X 12.39 removed T1SettingsViewController, which is where BHTwitter / NFX 7.2
// used to insert its settings row. This companion dylib opens the old 7.2
// settings UI directly:
//
//   two-finger long press anywhere in X  ->  NFX 7.2 settings
//
// It reads the current account from +[T1AccountsViewController currentAccount]
// and presents the 7.2 `ModernSettingsViewController initWithAccount:`.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void NFXLog(NSString* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString* msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"nfx-gesture.log"];
    FILE* f = fopen(path.fileSystemRepresentation, "a");
    if (f) {
        fprintf(f, "%s\n", msg.UTF8String);
        fclose(f);
    }
}

@interface NFXSettingsPresenter : NSObject
+ (instancetype)shared;
- (void)handleLongPress:(UILongPressGestureRecognizer*)gesture;
@end

@implementation NFXSettingsPresenter
+ (instancetype)shared {
    static NFXSettingsPresenter* s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}

- (UIWindow*)keyWindow {
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow* w in ((UIWindowScene*)scene).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return UIApplication.sharedApplication.keyWindow;
}

- (UIViewController*)topControllerFrom:(UIViewController*)vc {
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]])
        return [self topControllerFrom:((UINavigationController*)vc).visibleViewController];
    if ([vc isKindOfClass:[UITabBarController class]])
        return [self topControllerFrom:((UITabBarController*)vc).selectedViewController];
    return vc;
}

- (id)currentAccount {
    Class c = objc_getClass("T1AccountsViewController");
    if (!c) return nil;
    SEL sel = sel_registerName("currentAccount");
    if (![c respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)c, sel);
}

- (void)handleLongPress:(UILongPressGestureRecognizer*)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    Class cls = NSClassFromString(@"ModernSettingsViewController");
    if (!cls) {
        NFXLog(@"[gesture] ModernSettingsViewController missing");
        return;
    }
    id account = [self currentAccount];
    NFXLog(@"[gesture] account=%@", account);
    id vc = ((id (*)(id, SEL, id))objc_msgSend)([cls alloc],
                                               sel_registerName("initWithAccount:"), account);
    if (!vc) {
        NFXLog(@"[gesture] initWithAccount returned nil");
        return;
    }
    UINavigationController* nav = [[UINavigationController alloc] initWithRootViewController:vc];
    ((UIViewController*)vc).navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                     target:self
                                                     action:@selector(done:)];
    UIWindow* w = [self keyWindow];
    UIViewController* top = [self topControllerFrom:w.rootViewController];
    if (!top) {
        NFXLog(@"[gesture] no top controller");
        return;
    }
    [top presentViewController:nav animated:YES completion:nil];
    NFXLog(@"[gesture] presented from %@", NSStringFromClass([top class]));
}

- (void)done:(id)sender {
    UIWindow* w = [self keyWindow];
    UIViewController* top = [self topControllerFrom:w.rootViewController];
    [top dismissViewControllerAnimated:YES completion:nil];
}
@end

static void InstallGesture(void) {
    UIWindow* w = nil;
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow* win in ((UIWindowScene*)scene).windows) {
            if (win.isKeyWindow) { w = win; break; }
        }
        if (w) break;
    }
    if (!w) w = UIApplication.sharedApplication.keyWindow;
    if (!w) return;
    for (UIGestureRecognizer* g in w.gestureRecognizers) {
        if ([g isKindOfClass:[UILongPressGestureRecognizer class]]) {
            UILongPressGestureRecognizer* lp = (UILongPressGestureRecognizer*)g;
            if (lp.numberOfTouchesRequired == 2) return;
        }
    }
    UILongPressGestureRecognizer* g =
        [[UILongPressGestureRecognizer alloc] initWithTarget:[NFXSettingsPresenter shared]
                                                     action:@selector(handleLongPress:)];
    g.minimumPressDuration = 1.2;
    g.numberOfTouchesRequired = 2;
    g.cancelsTouchesInView = NO;
    [w addGestureRecognizer:g];
    NFXLog(@"[gesture] installed on %@", NSStringFromClass([w class]));
}

__attribute__((constructor)) static void nfx_settings_gesture(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ InstallGesture(); });
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIWindowDidBecomeKeyNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification* note) { InstallGesture(); }];
}
