// AmapSplash — 高德地图开屏/启动广告清理（适配 17.02.1）
//
// 设计原则：
//  * 不依赖 CydiaSubstrate：直接用 Objective-C runtime 的
//    method_setImplementation，因此 arm64 / arm64e、roothide / rootless 都能加载。
//  * 只挂当前版本真实存在的方法，缺类/缺方法只记日志，不 crash。
//  * 所有改动都能在 /tmp/amapsplash.log 里追溯（App 容器 tmp）。
//
// 逆向依据见 ../docs/REVERSE-NOTES.md：WKK 1.1-3 的 52 个 hook 中，
// 17.02.1 有 5 个类 + 17 个方法被改名/移除，开屏链路已整体重写。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <stdarg.h>
#import <string.h>
#import <unistd.h>

#ifdef UI_PROBE
#import <UIKit/UIKit.h>
#import <dlfcn.h>
typedef CGImageRef (*UIGetScreenImageFn)(void);
#endif

static FILE *gLog;

static void logline(const char *fmt, ...) {
    if (!gLog) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(gLog, fmt, ap);
    va_end(ap);
    fputc('\n', gLog);
    fflush(gLog);
}

static BOOL class_owns_method(Class cls, SEL sel, BOOL meta) {
    Class target = meta ? object_getClass(cls) : cls;
    unsigned int n = 0;
    Method *ms = class_copyMethodList(target, &n);
    BOOL found = NO;
    for (unsigned int i = 0; i < n && !found; i++)
        if (method_getName(ms[i]) == sel) found = YES;
    free(ms);
    return found;
}

/// 返回原 IMP；类/方法不存在或方法继承自父类时返回 NULL。
static IMP hook(Class cls, const char *name, const char *selname, IMP repl, BOOL meta) {
    if (!cls) {
        logline("SKIP   %s %s (no class)", name, selname);
        return NULL;
    }
    SEL sel = sel_registerName(selname);
    if (!class_owns_method(cls, sel, meta)) {
        logline("SKIP   %s %s (not defined here)", name, selname);
        return NULL;
    }
    Method m = meta ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) {
        logline("SKIP   %s %s (no method)", name, selname);
        return NULL;
    }
    IMP old = method_setImplementation(m, repl);
    const char *types = method_getTypeEncoding(m);
    logline("HOOK   %s%s %s  types=%s", meta ? "+" : "-", name, selname, types ?: "?");
    return old;
}

#define CLS(n) objc_getClass(n)
#define HOOK_I(cls, sel, repl) hook(cls, #cls, sel, (IMP)repl, NO)
#define HOOK_C(cls, sel, repl) hook(cls, #cls, sel, (IMP)repl, YES)

/* ---- replacements -------------------------------------------------- */

// Generic bodies. Extra arguments are ignored; ARM64 AAPCS makes this safe
// for the (object/BOOL) signatures we replace here.
static void ret_void0(id self, SEL _cmd) {}
static void ret_void1(id self, SEL _cmd, id a) {}
static void ret_void2(id self, SEL _cmd, id a, id b) {}
static void ret_void3(id self, SEL _cmd, id a, id b, id c) {}
static void ret_void4(id self, SEL _cmd, id a, id b, id c, id d) {}
static void ret_void5(id self, SEL _cmd, id a, id b, id c, id d, id e) {}
static void ret_void6(id self, SEL _cmd, id a, id b, id c, id d, id e, id f) {}
static void ret_void7(id self, SEL _cmd, id a, id b, id c, id d, id e, id f, id g) {}
static void ret_void8(id self, SEL _cmd, id a, id b, id c, id d, id e, id f, id g, id h) {}

static id ret_nil0(id self, SEL _cmd) { return nil; }
static id ret_nil1(id self, SEL _cmd, id a) { return nil; }
static id ret_nil2(id self, SEL _cmd, id a, id b) { return nil; }
static id ret_nil3(id self, SEL _cmd, id a, id b, id c) { return nil; }

static BOOL ret_no0(id self, SEL _cmd) { return NO; }
static id ret_false_obj(id self, SEL _cmd) { return @NO; }
static BOOL ret_no1(id self, SEL _cmd, id a) { return NO; }
static BOOL ret_no2(id self, SEL _cmd, id a, id b) { return NO; }

static NSInteger ret_zero0(id self, SEL _cmd) { return 0; }

static BOOL hook_shouldSplash(id self, SEL _cmd, void *a, BOOL b) {
#ifdef FORCE_SHOW
    logline("CALL   +shouldSplashScreenShow:launchCheck: -> YES (forced, test build)");
    return YES;
#else
    logline("CALL   +shouldSplashScreenShow:launchCheck: -> NO (blocked)");
    return NO;
#endif
}

static void hook_presentSplash(id self, SEL _cmd, id data, NSUInteger scene, BOOL bg,
                               id info, id s1, id s2, id s3, id s4) {
    logline("CALL   -presentSplashScreenWithData:scene=%lu bg=%d -> blocked", (unsigned long)scene, bg);
}

static void hook_presentRealtime(id self, SEL _cmd, id data, NSUInteger scene,
                                 id cb, id s1, id s2, id s3, id s4) {
    logline("CALL   -presentRealTimeSplashScreen:scene=%lu -> blocked", (unsigned long)scene);
}

static void hook_checkLocal(id self, SEL _cmd, NSUInteger scene) {
    logline("CALL   -checkAndShowLocalRealtimeAndPreloadFlashView:%lu -> blocked", (unsigned long)scene);
}

static void hook_checkRealtime(id self, SEL _cmd, NSUInteger scene) {
    logline("CALL   -checkAndShowRealtimeFlashView:%lu -> blocked", (unsigned long)scene);
}

#ifdef UI_PROBE
static void dump_view(NSMutableString *out, UIView *v, int depth) {
    if (!v || depth > 10) return;
    [out appendFormat:@"%*s%s frame=%@ hidden=%d alpha=%.2f\n", depth * 2, "",
                      NSStringFromClass([v class]).UTF8String,
                      NSStringFromCGRect(v.frame), v.hidden, v.alpha];
    for (UIView *s in v.subviews) dump_view(out, s, depth + 1);
}

static void probe_ui(const char *tag) {
    @autoreleasepool {
        UIApplication *app = [UIApplication sharedApplication];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        UIWindow *w = app.keyWindow ?: app.windows.firstObject;
#pragma clang diagnostic pop
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"--- UI %s pid=%d ---\n", tag, getpid()];
        dump_view(out, w, 0);
        UIViewController *vc = w.rootViewController;
        int i = 0;
        while (vc && i++ < 10) {
            [out appendFormat:@"VC[%d] %s presented=%s\n", i, NSStringFromClass([vc class]).UTF8String,
                              vc.presentedViewController ? "yes" : "no"];
            vc = vc.presentedViewController;
        }
        NSString *dir = NSTemporaryDirectory();
        NSString *logp = [dir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"amapui-%s-%d.txt", tag, getpid()]];
        [out writeToFile:logp atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSString *shotp = [dir stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"amapui-%s-%d.png", tag, getpid()]];
        UIGraphicsBeginImageContextWithOptions(w.bounds.size, NO, 0);
        [w drawViewHierarchyInRect:w.bounds afterScreenUpdates:YES];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (img) [UIImagePNGRepresentation(img) writeToFile:shotp atomically:YES];
        logline("PROBE %s ui=%s shot=%s", tag, logp.UTF8String, shotp.UTF8String);
    }
}

static void schedule_probes(void) {
    for (int i = 0; i < 4; i++) {
        double sec = (i == 0) ? 1.5 : (i == 1 ? 3.0 : (i == 2 ? 6.0 : 10.0));
        NSString *tag = [NSString stringWithFormat:@"t%g", sec];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ probe_ui(tag.UTF8String); });
    }
}
#endif


/* ---- install ------------------------------------------------------- */

__attribute__((constructor)) static void amapsplash_init(void) {
    @autoreleasepool {
        NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:@"amapsplash.log"];
        gLog = fopen(p.UTF8String, "a");
        logline("\n=== AmapSplash 1.1.0 === pid=%d uid=%d ver=%s ===",
                getpid(), getuid(),
                [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] UTF8String] ?: "?");

#ifndef NO_HOOKS
        /* ---------- 17.02.1 新开屏链路 ---------- */
        Class vapp = CLS("WINSplashScreenVAppService");
        HOOK_C(vapp, "shouldSplashScreenShow:launchCheck:", hook_shouldSplash);
        HOOK_C(vapp, "enableXDays", ret_zero0);
        HOOK_I(vapp, "isLocalSplashDataCanExposure", ret_false_obj);
        HOOK_I(vapp, "checkAndShowLocalRealtimeAndPreloadFlashView:", hook_checkLocal);
        HOOK_I(vapp, "checkAndShowRealtimeFlashView:", hook_checkRealtime);
        HOOK_I(vapp, "checkAndShowPreloadFlashView:otherInfo:", ret_void2);
        HOOK_I(vapp, "checkAndShowLocalRealtimeFlashView:data:otherInfo:", ret_void3);
        HOOK_I(vapp, "showAIFlashAndDelayRemove", ret_void0);
        HOOK_I(vapp, "fetchSplashDataWithScene:", ret_void1);

        Class pres = CLS("WINSplashScreenPresenter");
        HOOK_I(pres,
               "presentSplashScreenWithData:scene:fromBackground:otherInfo:filteringSuccessBlock:filteringFailureBlock:playFinishBlock:animationFinishBlock:",
               hook_presentSplash);
        HOOK_I(pres,
               "presentRealTimeSplashScreen:scene:customFilterBlock:filteringSuccessBlock:filteringFailureBlock:playFinishBlock:animationFinishBlock:",
               hook_presentRealtime);
        HOOK_I(pres, "addSplashViewForResource:creative:sessionId:", ret_nil3);
        HOOK_I(pres, "setSplashView:", ret_void1);
        HOOK_I(pres, "setShowing:", ret_void1);
        HOOK_I(pres, "areaButtonClicked:", ret_void1);
        HOOK_I(pres, "setCounterdown:", ret_void1);

        Class sview = CLS("WINSplashView");
        HOOK_I(sview, "showWithImageData:localPath:creative:", ret_void3);
        HOOK_I(sview, "showVideoWithLocalPath:creative:", ret_void2);
        HOOK_I(sview, "initWithFrame:", ret_nil1);

        Class sdata = CLS("WINSplashScreenData");
        HOOK_I(sdata, "setAd:", ret_void1);

        /* ---------- 旧版仍有效的开屏 hook ---------- */
        Class ajxVideo = CLS("WINAJXVideoAuthorModule");
        HOOK_I(ajxVideo, "hideSplashView", ret_void0);
        Class ajxShort = CLS("WINAJXShortVideoModule");
        HOOK_I(ajxShort, "hideSplashView", ret_void0);

        /* ---------- 首页/弹窗类清理（沿用 WKK 语义） ---------- */
        Class tip = CLS("NMMessageTipView");
        HOOK_I(tip, "initWithFrame:", ret_nil1);

        Class zoom = CLS("WINZoomInOutView");
        HOOK_I(zoom, "initWithFrame:", ret_nil1);

        Class op = CLS("WINOperationWidgetView");
        HOOK_I(op, "loadViewWithType", ret_void0);
        HOOK_I(op, "widgetShowType", ret_nil0);

        Class up = CLS("LTMVersionUpgradeAlertView");
        HOOK_I(up, "init", ret_nil0);
        HOOK_C(up, "init", ret_nil0);

        Class launcher = CLS("AMapLauncherConfig");
        HOOK_I(launcher, "isTestFlightChannel", ret_no0);
        HOOK_I(launcher, "isTestFlightVersion", ret_no0);

        Class base = CLS("NMBasemapConfig");
        HOOK_I(base, "isTestFlightInstalled", ret_no0);

        Class weather = CLS("WINWeatherDataProvider");
        HOOK_I(weather, "fetchWeatherDataWithImageStandard:completion:", ret_void2);

        Class logo = CLS("WINScaleLineLogoMapWidget");
        HOOK_I(logo, "showLogoViewAndHideScaleLine", ret_nil0);

        Class group = CLS("WINGroupMapWidget");
        HOOK_I(group, "addSubWidgetWithTag:widget:", ret_void2);

#endif
        logline("=== install done ===");
#ifdef UI_PROBE
        schedule_probes();
#endif
    }
}
