#import "XYDCommon.h"
#import <execinfo.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <string.h>

static void XYDAppendCrashFile(const char *text) {
    if (!text) return;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"xyd-crash.log"];
    int fd = open(path.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd >= 0) { write(fd, text, strlen(text)); close(fd); }
}

static void XYDHandleSignal(int sig) {
    void *bt[64];
    int n = backtrace(bt, 64);
    XYDAppendCrashFile("\n=== signal ===\n");
    backtrace_symbols_fd(bt, n, open([NSTemporaryDirectory() stringByAppendingPathComponent:@"xyd-crash.log"].UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0600));
    signal(sig, SIG_DFL);
    raise(sig);
}

static void XYDUncaughtException(NSException *e) {
    NSString *s = [NSString stringWithFormat:@"\n=== exception %@: %@\n%@\n", e.name, e.reason, e.callStackSymbols];
    XYDAppendCrashFile(s.UTF8String);
}

static void XYDInstallCrashHandler(void) {
    NSSetUncaughtExceptionHandler(&XYDUncaughtException);
    int sigs[] = {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP};
    for (unsigned i = 0; i < sizeof(sigs)/sizeof(sigs[0]); i++) signal(sigs[i], XYDHandleSignal);
}

static void XYDInstallAll(void) {
    XYDInstallCapture();
    XYDInstallContext();
    XYDInstallSplashHooks();   // 开屏必须尽早
    XYDInstallEntry();
    // 信息流/我的页要枚举 2 万个类，移到首帧之后再装，避免拖慢启动
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        XYDInstallFeedHooks();
    });
}

static BOOL XYDIncomplete(void) {
    return XYDAdClassesMissing() ||
           !XYDClassExists(@"XDetailViewController") ||
           !XYDClassExists(@"UIImage");
}

static void XYDScheduleRetries(void) {
    // 部分 Swift/框架类可能在启动后才注册；最多重试 3 次，不做常驻轮询
    static int attempt = 0;
    if (attempt >= 3) return;
    if (!XYDIncomplete()) return;
    attempt++;
    NSTimeInterval delay = attempt == 1 ? 1.0 : (attempt == 2 ? 2.5 : 6.0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!XYDPrefBool(@"enabled", YES)) return;
        XYDInvalidateClassCache();
        XYDInstallSplashHooks();
        XYDInstallFeedHooks();
        XYDInstallEntry();
        XYDInstallContext();
        XYDScheduleRetries();
    });
}

@interface XYDMain : NSObject
@end

@implementation XYDMain
+ (void)boot {
    @autoreleasepool {
        NSString *bid = [NSBundle mainBundle].bundleIdentifier;
        if (![bid isEqualToString:@"com.taobao.fleamarket"]) return;

        XYDDefaultsIfNeeded();
        if (XYDPrefBool(@"debug", NO)) XYDInstallCrashHandler();
        if (!XYDPrefBool(@"enabled", YES)) {
            XYD_LOG(@"disabled by pref");
            return;
        }
        XYD_LOG(@"boot %@ (%@)", bid,
                [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?");

#ifdef XYD_CONTROL
        XYD_LOG(@"CONTROL build: hooks disabled");
#else
        XYDInstallAll();
        XYDScheduleRetries();
#endif
#ifdef XYD_TEST_VIDEO
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            XYDLog(@"TESTVIDEO start");
            XYDFetchVideoURL(@"727755438", ^(NSURL *u, NSError *e) {
                XYDLog(@"TESTVIDEO url=%@ err=%@", u, e.localizedDescription);
            });
        });
#endif
#ifdef XYD_AUTOOPEN
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSURL *u = [NSURL URLWithString:@"fleamarket://item?id=1091430207724"];
            XYD_LOG(@"AUTOOPEN %@", u);
            Class router = NSClassFromString(@"FMURLRouter");
            SEL sel = NSSelectorFromString(@"safeOpenURL:withQuery:withParams:withUniqueid:");
            if (router && [router respondsToSelector:sel]) {
                BOOL ok = ((BOOL (*)(id, SEL, id, id, id, id))objc_msgSend)(router, sel, u, nil, nil, nil);
                XYD_LOG(@"AUTOOPEN router result=%d", ok);
            } else {
                XYD_LOG(@"AUTOOPEN router missing");
            }
        });
#endif

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) {
            XYDRefreshPrefs();
            XYDInstallOptionalHooks();
            XYDStore *st = [XYDStore shared];
            if (st.onDetailPage && XYDPrefBool(@"showBall", YES)) XYDInstallFloatingBall();
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) {
            XYDUninstallFloatingBall();
        }];
    }
}
@end

__attribute__((constructor))
static void XYDConstructor(void) {
    // 同步安装：与 3.2.2 一致，保证详情页首屏图片也能被捕获
    [XYDMain boot];
}
