// amapdiag — read-only runtime inventory for Amap (com.autonavi.amap).
// Loaded on launch; writes a report to the app's tmp directory and NSLog.
// It never swizzles anything; it only asks the Objective-C runtime what exists.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

#include "hooks_generated.h"

static const char *kKeywords[] = {
    "Splash", "Launch", "Welcome", "Boot", "Advert", "Promotion", "Banner",
    "Popup", "Upgrade", "Guide", "Market", "Operation", "Badge", "RedPoint",
    "Feed", "AdView", "AdManager", "AdController", "AdModel", "NativeAd",
    "Loading", "HUD", "Toast", "Alert", "TabBar", "Widget", "Floating",
};

static int matches(const char *s) {
    if (!s) return 0;
    for (size_t i = 0; i < sizeof(kKeywords) / sizeof(kKeywords[0]); i++)
        if (strstr(s, kKeywords[i])) return 1;
    return 0;
}

static void dump_class(FILE *f, Class c) {
    const char *name = class_getName(c);
    Class sup = class_getSuperclass(c);
    fprintf(f, "\n### class %s : %s\n", name, sup ? class_getName(sup) : "-");
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    for (unsigned int i = 0; i < n; i++)
        fprintf(f, "  -[%s]\n", sel_getName(method_getName(ms[i])));
    free(ms);
    Class meta = object_getClass(c);
    ms = class_copyMethodList(meta, &n);
    for (unsigned int i = 0; i < n; i++)
        fprintf(f, "  +[%s]\n", sel_getName(method_getName(ms[i])));
    free(ms);
}

__attribute__((constructor)) static void amapdiag_main(void) {
    @autoreleasepool {
        NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
        NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"amapdiag.txt"];
        FILE *f = fopen(path.UTF8String, "w");
        if (!f) return;

        fprintf(f, "bundle=%s version=%s pid=%d uid=%d\n",
                bundle.UTF8String, ver.UTF8String, getpid(), getuid());
        fprintf(f, "diag dylib loaded\n");

        /* 1. Do the classes/selectors from the WKK 1.1-3 tweak still exist? */
        fprintf(f, "\n=== original hook table (%zu) ===\n",
                sizeof(kOrigHooks) / sizeof(kOrigHooks[0]));
        int ok = 0, missing_cls = 0, missing_sel = 0;
        for (size_t i = 0; i < sizeof(kOrigHooks) / sizeof(kOrigHooks[0]); i++) {
            Class c = objc_getClass(kOrigHooks[i].cls);
            if (!c) {
                fprintf(f, "MISSING_CLASS  %s  %s\n", kOrigHooks[i].cls, kOrigHooks[i].sel);
                missing_cls++;
                continue;
            }
            SEL s = sel_registerName(kOrigHooks[i].sel);
            Method im = class_getInstanceMethod(c, s);
            Method cm = class_getClassMethod(c, s);
            fprintf(f, "%-13s %-28s %-56s inst=%d cls=%d (%s)\n",
                    (im || cm) ? "OK" : "MISSING_SEL", kOrigHooks[i].cls,
                    kOrigHooks[i].sel, im ? 1 : 0, cm ? 1 : 0, kOrigHooks[i].behavior);
            if (im || cm) ok++; else missing_sel++;
        }
        fprintf(f, "summary ok=%d missing_class=%d missing_sel=%d\n",
                ok, missing_cls, missing_sel);

        /* 2. Full inventory of ad/splash-looking classes in this build. */
        int count = objc_getClassList(NULL, 0);
        Class *all = malloc(sizeof(Class) * (size_t)count);
        count = objc_getClassList(all, count);
        for (int i = 0; i < count; i++) {
            if (matches(class_getName(all[i])))
                dump_class(f, all[i]);
        }
        free(all);
        fprintf(f, "\n=== end ===\n");
        fclose(f);
        NSLog(@"[amapdiag] wrote %@", path);
    }
}
