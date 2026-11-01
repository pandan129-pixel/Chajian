// NFBBundleFix.dylib
//
// NeoFreeBird 7.3.0 的 BHTBundle 只认几个写死的路径：
//   /Library/Application Support/BHT/BHTwitter.bundle
//   /var/jb/Library/Application Support/BHT/BHTwitter.bundle
// 12.39 的定制构建还会找 dylib 同目录，但在 roothide 上 realpath 可能是
// usr/lib/TweakInject，仍然可能找不到，界面就回退成 key。
//
// 这个 dylib 只做一件事：找到真正的 BHTwitter.bundle，然后让 NFB 的查找命中。
// 不修改 NFB 的二进制，只在 Foundation 层做精确路径重定向。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <objc/message.h>

static NSString *gRealBundle = nil;

static void NFBLog(NSString* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString* msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"nfb-fix.log"];
    FILE* f = fopen(path.fileSystemRepresentation, "a");
    if (f) {
        fprintf(f, "%s\n", msg.UTF8String);
        fclose(f);
    }
}


static BOOL IsBundlePath(NSString *p) {
    return [p.lastPathComponent isEqualToString:@"BHTwitter.bundle"];
}

static NSString *FindBundle(NSString *dir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *rel = @[
        @"BHTwitter.bundle",
        @"../../Library/Application Support/BHT/BHTwitter.bundle",
        @"../../../Library/Application Support/BHT/BHTwitter.bundle",
        @"../Application Support/BHT/BHTwitter.bundle",
    ];
    for (NSString *r in rel) {
        NSString *p = [[dir stringByAppendingPathComponent:r] stringByStandardizingPath];
        if ([fm fileExistsAtPath:p]) return p;
    }
    // 从 dylib 目录逐级向上找 Library/Application Support/BHT/BHTwitter.bundle
    NSString *d = dir;
    for (int i = 0; i < 6; i++) {
        NSString *p = [[d stringByAppendingPathComponent:
                        @"Library/Application Support/BHT/BHTwitter.bundle"]
                       stringByStandardizingPath];
        if ([fm fileExistsAtPath:p]) return p;
        d = [d stringByDeletingLastPathComponent];
    }
    for (NSString *p in @[
             @"/Library/Application Support/BHT/BHTwitter.bundle",
             @"/var/jb/Library/Application Support/BHT/BHTwitter.bundle"]) {
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}

static BOOL (*origExists)(id, SEL, NSString *);
static BOOL newExists(id self, SEL _cmd, NSString *path) {
    if (gRealBundle && IsBundlePath(path)) {
        return YES;
    }
    return origExists(self, _cmd, path);
}

static NSBundle *(*origBundleWithPath)(id, SEL, NSString *);
static NSBundle *newBundleWithPath(id self, SEL _cmd, NSString *path) {
    if (gRealBundle && IsBundlePath(path)) {
        return origBundleWithPath(self, _cmd, gRealBundle);
    }
    return origBundleWithPath(self, _cmd, path);
}

// 强制中文 + 修复 mainBundle
static NSString *FindReadableBundle(void);
static NSBundle *gFixedBundle = nil;
static NSDictionary *gZhDict = nil;
static NSString *(*origLocalized)(id, SEL, NSString *);
static NSBundle *(*origMainBundle)(id, SEL);
static BOOL gHooked = NO;

static NSBundle *FixedBundle(void) {
    if (gFixedBundle) return gFixedBundle;
    NSString *base = FindReadableBundle() ?: gRealBundle;
    if (base) gFixedBundle = [NSBundle bundleWithPath:base];
    return gFixedBundle;
}

// 直接读 .strings（binary plist），不依赖 NSBundle 对 .lproj 的解析。
static NSString *gReadableBundle = nil;

static NSString *FindReadableBundle(void) {
    if (gReadableBundle) return gReadableBundle;
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    NSString *home = [NSHomeDirectory() stringByAppendingPathComponent:
                      @"Library/Application Support/BHT/BHTwitter.bundle"];
    [cands addObject:home];
    if (gRealBundle) [cands addObject:gRealBundle];
    [cands addObject:@"/var/jb/Library/Application Support/BHT/BHTwitter.bundle"];
    [cands addObject:@"/usr/lib/TweakInject/BHTwitter.bundle"];
    NSString *appRes = [[NSBundle mainBundle] pathForResource:@"BHTwitter"
                                                      ofType:@"bundle"];
    if (appRes) [cands addObject:appRes];

    for (NSString *base in cands) {
        if (![base isKindOfClass:[NSString class]] || !base.length) continue;
        NSString *p = [base stringByAppendingPathComponent:
                       @"zh-Hans.lproj/Localizable.strings"];
        NSError *e = nil;
        NSData *d = [NSData dataWithContentsOfFile:p options:0 error:&e];
        NFBLog(@"[read] %@ len=%lu", p, (unsigned long)d.length);
        if (d.length) {
            gReadableBundle = base;
            NFBLog(@"[read] using %@", base);
            return base;
        }
    }
    NFBLog(@"[read] no readable bundle (real=%@ home=%@)", gRealBundle, home);
    return nil;
}

static NSDictionary *ZhDict(void) {
    if (gZhDict) return gZhDict;
    NSString *base = FindReadableBundle() ?: gRealBundle;
    if (!base) return nil;
    for (NSString *l in @[@"zh-Hans", @"zh_CN"]) {
        NSString *p = [[base stringByAppendingPathComponent:l]
                       stringByAppendingPathExtension:@"lproj"];
        p = [p stringByAppendingPathComponent:@"Localizable.strings"];
        NSError* err = nil;
        NSData* data = [NSData dataWithContentsOfFile:p options:0 error:&err];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        NSDictionary *sys = [NSDictionary dictionaryWithContentsOfFile:@"/System/Library/CoreServices/SystemVersion.plist"];
        NFBLog(@"[zh-try] %@ data=%lu count=%lu err=%@ sys=%@", p,
               (unsigned long)data.length, (unsigned long)d.count, err,
               sys[@"ProductVersion"]);
        if (d.count) {
            gZhDict = d;
            NFBLog(@"[zh] %@ keys=%lu", p, (unsigned long)d.count);
            break;
        }
    }
    return gZhDict;
}

static NSBundle *newMainBundle(id self, SEL _cmd) {
    NSBundle *b = origMainBundle ? origMainBundle(self, _cmd) : nil;
    if (b) return b;
    NSBundle *fixed = FixedBundle();
    if (fixed) {
        static int logged = 0;
        if (logged++ < 3) NFBLog(@"[mainBundle] nil -> %@", fixed.bundlePath);
    }
    return fixed;
}

static BOOL ForceChineseEnabled(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"NFBForceChinese"];
    return v == nil ? YES : [v boolValue];
}

static NSString *newLocalized(id self, SEL _cmd, NSString *key) {
    if (!ForceChineseEnabled()) return origLocalized(self, _cmd, key);
    NSDictionary *d = ZhDict();
    NSString *s = key ? d[key] : nil;
    if (s) return s;
    return origLocalized ? origLocalized(self, _cmd, key) : key;
}

static void InstallBHTBundleHook(void) {
    if (gHooked) return;
    Class c = objc_getClass("BHTBundle");
    if (!c) return;
    BOOL didMain = NO, didLoc = NO;
    Method mm = class_getInstanceMethod(c, @selector(mainBundle));
    if (mm) {
        origMainBundle = (void *)method_getImplementation(mm);
        class_replaceMethod(c, @selector(mainBundle),
                            (IMP)newMainBundle, method_getTypeEncoding(mm));
        didMain = YES;
    }
    Method m = class_getInstanceMethod(c, @selector(localizedStringForKey:));
    if (m) {
        origLocalized = (void *)method_getImplementation(m);
        class_replaceMethod(c, @selector(localizedStringForKey:),
                            (IMP)newLocalized, method_getTypeEncoding(m));
        didLoc = YES;
    }
    gHooked = YES;
    NFBLog(@"[hook] BHTBundle mainBundle=%d localized=%d", didMain, didLoc);
}

__attribute__((constructor)) static void nfb_bundle_fix(void) {
    Dl_info info;
    if (!dladdr((void *)nfb_bundle_fix, &info) || !info.dli_fname) return;
    NSString *dir = [[NSString stringWithUTF8String:info.dli_fname]
                     stringByDeletingLastPathComponent];
    gRealBundle = FindBundle(dir);
    NFBLog(@"[init] self=%@ real=%@ appLang=%@ apple=%@", dir, gRealBundle,
           [[NSBundle mainBundle] preferredLocalizations],
           [[NSUserDefaults standardUserDefaults] objectForKey:@"AppleLanguages"]);

    InstallBHTBundleHook();
    if (!gHooked) {
        for (int i = 1; i <= 20; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(i * 0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                InstallBHTBundleHook();
            });
        }
    }

    if (!gRealBundle) {
        NSLog(@"[NFBBundleFix] BHTwitter.bundle not found from %@", dir);
        NFBLog(@"[init] bundle NOT found from %@", dir);
        return;
    }

    Class nb = objc_getClass("NSBundle");
    Method bm = class_getClassMethod(nb, @selector(bundleWithPath:));
    if (bm) {
        origBundleWithPath = (void *)method_getImplementation(bm);
        method_setImplementation(bm, (IMP)newBundleWithPath);
    }

    Class fm = objc_getClass("NSFileManager");
    Method em = class_getInstanceMethod(fm, @selector(fileExistsAtPath:));
    if (em) {
        origExists = (void *)method_getImplementation(em);
        method_setImplementation(em, (IMP)newExists);
    }
    NSLog(@"[NFBBundleFix] using %@", gRealBundle);

}
