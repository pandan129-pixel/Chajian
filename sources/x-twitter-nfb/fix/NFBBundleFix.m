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

static NSString *gRealBundle = nil;

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

__attribute__((constructor)) static void nfb_bundle_fix(void) {
    Dl_info info;
    if (!dladdr((void *)nfb_bundle_fix, &info) || !info.dli_fname) return;
    NSString *dir = [[NSString stringWithUTF8String:info.dli_fname]
                     stringByDeletingLastPathComponent];
    gRealBundle = FindBundle(dir);
    if (!gRealBundle) {
        NSLog(@"[NFBBundleFix] BHTwitter.bundle not found from %@", dir);
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
