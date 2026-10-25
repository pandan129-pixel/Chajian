// jbb v5 — 越狱检测绕过（授权研究用）
// 目标：文件 API / dyld 镜像 / dladdr / 反调试（v6.1 起不再处理 SSH/Frida）
// 编译：clang -arch arm64 -arch arm64e -miphoneos-version-min=15.0 -dynamiclib -O2
// 依赖：ElleKit 的 MSHookFunction（运行时 dlopen /usr/lib/libellekit.dylib）

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <errno.h>
#include <stdarg.h>
#include <pthread.h>
#include <fcntl.h>
#include <dirent.h>

#include <sys/stat.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <signal.h>
#include <sys/ucontext.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <sys/attr.h>
#include <sys/proc.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/dyld_images.h>
#include <mach-o/loader.h>
#include <mach/vm_map.h>
#include <dlfcn.h>

extern int ptrace(int request, pid_t pid, caddr_t addr, int data);
extern char **environ;

// ---------------------------------------------------------------- hook 框架
typedef void (*MSHookFunction_t)(void *symbol, void *replace, void **result);
static MSHookFunction_t MSHook = NULL;

/* v6.10: no per-launch file writes. The old marker wrote 2-3 files into the
 * app's Documents on every start (3 syscalls + directory churn per launch, and
 * a self-inflicted trace). Apelin R15: use os_log with the package id, and only
 * when a diagnostic build asks for it. */
#ifdef JBB_DIAG_LOG
#import <os/log.h>
static os_log_t jb_log(void) {
    static os_log_t log; static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.pandan.jbb", "runtime"); });
    return log;
}
static void jb_marker_msg(const char *name, const char *msg) {
    os_log(jb_log(), "%{public}s %{public}s", name, msg ? msg : "");
}
#else
static void jb_marker_msg(const char *name, const char *msg) { (void)name; (void)msg; }
#endif
static void jb_marker(const char *name) { jb_marker_msg(name, NULL); }

// ---------------- v6.2 diag: 记录 exit/abort 调用栈 ----------------
static int gDiag = 0;
static void jb_trace_exit(const char *why, int code) {
    const char *h = getenv("HOME");
    if (!h) return;
    char p[512];
    snprintf(p, sizeof(p), "%s/Documents/jbb_exit_trace.txt", h);
    int fd = open(p, O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (fd < 0) return;
    char head[160];
    int hl = snprintf(head, sizeof(head), "=== %s code=%d pid=%d ===\n", why, code, getpid());
    write(fd, head, hl);
    // 不依赖 backtrace()（iOS 16 运行时不一定导出）：用返回地址 + dladdr 定位来源镜像
    void *addrs[8] = {
        __builtin_return_address(0), __builtin_return_address(1),
        __builtin_return_address(2), __builtin_return_address(3),
        __builtin_return_address(4), __builtin_return_address(5),
        __builtin_return_address(6), __builtin_return_address(7)
    };
    for (int i = 0; i < 8; i++) {
        if (!addrs[i]) continue;
        Dl_info di; memset(&di, 0, sizeof(di));
        char line[512];
        if (dladdr(addrs[i], &di) && di.dli_fname) {
            int n = snprintf(line, sizeof(line), "  #%d %s+0x%llx\n", i, di.dli_fname,
                             (unsigned long long)((uintptr_t)addrs[i] - (uintptr_t)di.dli_fbase));
            if (n > 0) write(fd, line, n);
        } else {
            int n = snprintf(line, sizeof(line), "  #%d %p\n", i, addrs[i]);
            if (n > 0) write(fd, line, n);
        }
    }
    write(fd, "\n", 1);
    close(fd);
}

// ---------------- v6.4 diag: 信号崩溃记录 ----------------
static void jb_sig_handler(int sig, siginfo_t *si, void *uctx) {
    const char *h = getenv("HOME");
    if (h) {
        char p[512];
        snprintf(p, sizeof(p), "%s/Documents/jbb_crash.txt", h);
        int fd = open(p, O_CREAT | O_WRONLY | O_APPEND, 0644);
        if (fd >= 0) {
            char head[192];
            uintptr_t pc = 0, lr = 0, fp = 0;
#if defined(__arm64__) || defined(__aarch64__)
            ucontext_t *uc = (ucontext_t *)uctx;
#if __DARWIN_OPAQUE_ARM_THREAD_STATE64
            if (uc) { pc = (uintptr_t)uc->uc_mcontext->__ss.__opaque_pc;
                      lr = (uintptr_t)uc->uc_mcontext->__ss.__opaque_lr;
                      fp = (uintptr_t)uc->uc_mcontext->__ss.__opaque_fp; }
#else
            if (uc) { pc = (uintptr_t)uc->uc_mcontext->__ss.__pc;
                      lr = (uintptr_t)uc->uc_mcontext->__ss.__lr;
                      fp = (uintptr_t)uc->uc_mcontext->__ss.__fp; }
#endif
#endif
            int hl = snprintf(head, sizeof(head), "=== SIGNAL %d (%s) pid=%d pc=%p lr=%p ===\n",
                              sig, strsignal(sig), getpid(), (void *)pc, (void *)lr);
            if (hl > 0) write(fd, head, hl);
            Dl_info di; memset(&di, 0, sizeof(di));
            if (pc && dladdr((void *)pc, &di) && di.dli_fname) {
                char line[512];
                int n = snprintf(line, sizeof(line), "  pc in %s+0x%llx\n", di.dli_fname,
                                 (unsigned long long)(pc - (uintptr_t)di.dli_fbase));
                if (n > 0) write(fd, line, n);
            }
            if (lr) { memset(&di,0,sizeof(di));
                if (dladdr((void *)lr,&di) && di.dli_fname) {
                    char line[512];
                    int n = snprintf(line, sizeof(line), "  lr in %s+0x%llx\n", di.dli_fname,
                                     (unsigned long long)(lr - (uintptr_t)di.dli_fbase));
                    if (n > 0) write(fd, line, n);
                }
            }
            write(fd, "\n", 1);
            close(fd);
        }
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void jb_install_signal_handlers(void) {
    int sigs[] = {SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE};
    for (unsigned i = 0; i < sizeof(sigs)/sizeof(sigs[0]); i++) {
        struct sigaction sa; memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = jb_sig_handler;
        sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
        sigaction(sigs[i], &sa, NULL);
    }
}

static void (*o_exit)(int);
static void h_exit(int code) { if (gDiag) jb_trace_exit("exit", code); o_exit(code); }
static void (*o__exit)(int);
static void h__exit(int code) { if (gDiag) jb_trace_exit("_exit", code); o__exit(code); }
static void (*o_abort)(void);
static int (*o_kill)(pid_t, int);
static int h_kill(pid_t p, int sig) {
    if (gDiag && (p == getpid() || p == 0)) jb_trace_exit("kill", sig);
    return o_kill ? o_kill(p, sig) : -1;
}
static void h_abort(void) { if (gDiag) jb_trace_exit("abort", 0); o_abort(); }

// ---------------- v6.2: per-app profile ----------------
static int gFile = 1, gDyld = 1, gName = 1, gSysctl = 1, gPtrace = 1, gEnv = 0, gPpid = 1, gObjC = 1, gCsops = 1;
static int gEnabled = 1;

static void jb_tokens_init(BOOL extra, NSArray *custom);
static void jb_token_index_build(void);

static int gExtraDefault = 0;
static int gConfigFound = 0;   /* set by jb_load_profile: did any source yield config? */

/* Read a per-app switch, falling back to the Settings-UI default when the key
 * is absent. The UI (JBBAppSettingsController) shows every switch as ON except
 * env/extraTokens; an empty or partial profile must therefore mean "UI default",
 * not "all off", or an added-but-unconfigured app would silently disable almost
 * every hook while the UI still reads ON. Defaults here mirror the gFile.. inits. */
static BOOL jb_pbool(NSDictionary *profile, NSString *key, BOOL dflt)
{
    id v = profile[key];
    return v ? [v boolValue] : dflt;
}

static void jb_load_profile(void)
{
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid) return;

        NSDictionary *profile = nil;
        BOOL configFound = NO;   /* did any source actually yield our config? */

        /* 0) Per-app config published by jbbd into our own container. Sandboxed
         * apps can only read their own container, so this is the only channel
         * that actually works inside an app. jbbd writes it from the Settings
         * plist on every change. */
        {
            NSDictionary *own = [NSDictionary dictionaryWithContentsOfFile:
                [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/jbb/config.plist"]];
            if ([own isKindOfClass:[NSDictionary class]]) {
                configFound = YES;
                if (own[@"globalEnabled"]) gEnabled = [own[@"globalEnabled"] boolValue];
                if (own[@"globalExtraTokens"]) gExtraDefault = [own[@"globalExtraTokens"] boolValue];
                NSDictionary *profiles = own[@"profiles"];
                if ([profiles isKindOfClass:[NSDictionary class]]) profile = profiles[bid];
            }
        }

        /* 1) Direct file read (host/root processes, and a fallback). */
        if (!configFound) {
            NSDictionary *ui = [NSDictionary dictionaryWithContentsOfFile:
                @"/var/mobile/Library/Preferences/com.pandan.jbb.cfg.plist"];
            if (![ui isKindOfClass:[NSDictionary class]]) {
                ui = [NSDictionary dictionaryWithContentsOfFile:
                      @"/var/mobile/Library/Preferences/com.pandan.jbb.plist"];
            }
            if ([ui isKindOfClass:[NSDictionary class]]) {
                configFound = YES;
                if (ui[@"globalEnabled"]) gEnabled = [ui[@"globalEnabled"] boolValue];
                if (ui[@"globalExtraTokens"]) gExtraDefault = [ui[@"globalExtraTokens"] boolValue];
                NSDictionary *profiles = ui[@"profiles"];
                if ([profiles isKindOfClass:[NSDictionary class]]) profile = profiles[bid];
            }
        }

        /* 3) Legacy roothide profile file (kept for compatibility) */
        if (![profile isKindOfClass:[NSDictionary class]]) {
            Dl_info di; memset(&di, 0, sizeof(di));
            NSString *cfg = nil;
            if (dladdr((void *)jb_load_profile, &di) && di.dli_fname) {
                NSString *self0 = [NSString stringWithUTF8String:di.dli_fname];
                NSRange r = [self0 rangeOfString:@"/usr/lib/TweakInject/"];
                if (r.location != NSNotFound) {
                    NSString *root = [self0 substringToIndex:r.location];
                    cfg = [root stringByAppendingPathComponent:@"var/mobile/Library/RootHide/jbb_profiles.plist"];
                }
            }
            NSDictionary *all = cfg ? [NSDictionary dictionaryWithContentsOfFile:cfg] : nil;
            if ([all isKindOfClass:[NSDictionary class]]) {
                configFound = YES;
                id p = all[bid];
                if ([p isKindOfClass:[NSDictionary class]]) profile = p;
            }
        }

        gConfigFound = configFound ? 1 : 0;

        /* Fresh install / first launch: no config readable from inside a sandboxed
         * app yet (Settings mirrors its plist into cfprefsd on save/load, which is
         * path 1 above, so this only happens before the user opens Settings once).
         * Keep the 6.16 behaviour here (enabled) - a bypass that does nothing after
         * install is worse than the window before the first save. */
        if (!configFound) {
            gEnabled = 1;
            jb_tokens_init(gExtraDefault, nil);
            return;
        }

        if (![profile isKindOfClass:[NSDictionary class]]) {
            jb_tokens_init(gExtraDefault, nil);
            return;
        }

        gFile = jb_pbool(profile, @"file", YES);
        gDyld = jb_pbool(profile, @"dyld", YES);
        gName = jb_pbool(profile, @"name", YES);
        gSysctl = jb_pbool(profile, @"sysctl", YES);
        gPtrace = jb_pbool(profile, @"ptrace", YES);
        gEnv = jb_pbool(profile, @"env", NO);
        gPpid = jb_pbool(profile, @"ppid", YES);
        gObjC = jb_pbool(profile, @"objc", YES);
        gCsops = jb_pbool(profile, @"csops", YES);
        gDiag = jb_pbool(profile, @"diag", NO);
        if (profile[@"enabled"]) gEnabled = [profile[@"enabled"] boolValue];

        BOOL extra = profile[@"extraTokens"] ? [profile[@"extraTokens"] boolValue] : gExtraDefault;
        jb_tokens_init(extra, profile[@"tokens"]);
    }
}

static void jb_load_hook_framework(void) {
    if (MSHook) return;
    MSHook = (MSHookFunction_t)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (MSHook) { jb_marker_msg("jbb_v6_src", "rtld"); return; }

    Dl_info di; memset(&di, 0, sizeof(di));
    if (dladdr((void *)jb_load_hook_framework, &di) && di.dli_fname) {
        char root[PATH_MAX]; strlcpy(root, di.dli_fname, sizeof(root));
        char *p = strstr(root, "/usr/lib/");
        if (p) {
            *p = '\0';
            char path[PATH_MAX];
            snprintf(path, sizeof(path), "%s/usr/lib/libellekit.dylib", root);
            void *h = dlopen(path, RTLD_NOW);
            if (h) {
                MSHook = (MSHookFunction_t)dlsym(h, "MSHookFunction");
                if (MSHook) { jb_marker_msg("jbb_v6_src", path); return; }
            } else {
                jb_marker_msg("jbb_v6_dlerr", dlerror());
            }
        }
    }

    const char *paths[] = {
        "/usr/lib/libellekit.dylib",
        "/usr/lib/libsubstrate.dylib",
        "/usr/lib/libhooker.dylib",
        NULL
    };
    for (int i = 0; paths[i]; i++) {
        void *h = dlopen(paths[i], RTLD_NOW);
        if (!h) continue;
        MSHook = (MSHookFunction_t)dlsym(h, "MSHookFunction");
        if (MSHook) { jb_marker_msg("jbb_v6_src", paths[i]); return; }
    }
}

static void *gHookedSyms[128];
static int gHookedCount = 0;
static int jb_already_hooked(void *sym) {
    for (int i = 0; i < gHookedCount; i++) if (gHookedSyms[i] == sym) return 1;
    return 0;
}

static void jb_hook(const char *name, void *replace, void **orig) {
    if (!MSHook) return;
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (!sym) return;
    if (jb_already_hooked(sym)) return;     // stat/stat64 等同地址只装一次
    if (gHookedCount < 128) gHookedSyms[gHookedCount++] = sym;
    if (orig && *orig) return;
    if (orig) {
        void *o = NULL;
        MSHook(sym, replace, &o);
        *orig = o;
    } else {
        MSHook(sym, replace, NULL);
    }
}

// ---------------------------------------------------------------- 路径表
static const char *kJBTokensCore[] = {
    "/var/jb", "/.jbroot", ".jbroot-", "/basebin", "/private/preboot",
    "/usr/lib/systemhook", "/usr/lib/roothideinit", "/usr/lib/roothidepatch",
    "/usr/lib/TweakInject", "/usr/lib/libjailbreak.dylib", "/usr/lib/libroothide.dylib",
    "/usr/lib/libellekit.dylib", "/usr/lib/libsubstrate.dylib", "/usr/lib/libhooker.dylib",
    "/usr/lib/libblackjack", "/Library/MobileSubstrate",
    "/Applications/Cydia.app", "/Applications/Sileo.app", "/Applications/Zebra.app",
    "/Applications/Filza.app", "/var/mobile/Library/RootHide",
    "/usr/bin/jbctl", "systemhook", "roothide", "ellekit", "substrate",
    NULL,
};

/* Only useful on other jailbreak setups; off by default to keep the per-call
 * token loop short. Enable per app with "extraTokens": true. */
static const char *kJBTokensExtra[] = {
    "/var/lib/apt", "/var/cache/apt", "/etc/apt", "/var/lib/dpkg", "/Library/dpkg",
    "/usr/bin/cycript", "/usr/bin/dpkg", "/usr/bin/apt", "/usr/bin/uicache",
    "/bin/bash", "/usr/libexec/irisind", "irisind", "irisin", "umbra",
    "cocoatop", "relaxin", "libsandy", "substitute", "cydia", "libhooker",
    NULL,
};

#define JB_MAX_TOKENS 64
static const char *gTokens[JB_MAX_TOKENS];
static int gTokenCount = 0;

static void jb_tokens_init(BOOL extra, NSArray *custom) {
    int n = 0;
    for (int i = 0; kJBTokensCore[i] && n < JB_MAX_TOKENS; i++) gTokens[n++] = kJBTokensCore[i];
    if (extra) {
        for (int i = 0; kJBTokensExtra[i] && n < JB_MAX_TOKENS; i++) gTokens[n++] = kJBTokensExtra[i];
    }
    for (NSString *t in custom) {
        if (![t isKindOfClass:[NSString class]] || t.length < 3 || n >= JB_MAX_TOKENS) continue;
        gTokens[n++] = strdup(t.UTF8String);
    }
    gTokenCount = n;
    jb_token_index_build();
}

/* v6.15: first-byte anchor index instead of N x strstr.
 * Tokens are static literals; we only need to try a token when the path byte at
 * the current position equals the token's first byte (and the second byte also
 * matches). That turns a 26/45-entry strstr loop into one pass over the path
 * with a handful of candidate comparisons. */
static int16_t gAnchorHead[256];
static int16_t gAnchorNext[JB_MAX_TOKENS];
static uint8_t gTokenLen[JB_MAX_TOKENS];

static void jb_token_index_build(void) {
    for (int i = 0; i < 256; i++) gAnchorHead[i] = -1;
    for (int i = 0; i < gTokenCount; i++) {
        const char *t = gTokens[i];
        size_t len = strlen(t);
        gTokenLen[i] = (uint8_t)(len > 255 ? 255 : len);
        unsigned char c = (unsigned char)t[0];
        gAnchorNext[i] = gAnchorHead[c];
        gAnchorHead[c] = (int16_t)i;
    }
}

static int jb_token(const char *p) {
    if (!p || gTokenCount == 0) return 0;

    for (const char *q = p; *q; q++) {
        int16_t idx = gAnchorHead[(unsigned char)*q];
        while (idx >= 0) {
            const char *t = gTokens[idx];
            size_t len = gTokenLen[idx];
            if (len >= 2 && t[1] == q[1] && strncmp(q, t, len) == 0) return 1;
            idx = gAnchorNext[idx];
        }
    }
    return 0;
}

// 保留正常路径（避免误伤 /etc/hosts、/usr/lib/dyld、SystemVersion.plist）
/* These are absolute prefixes, so strncmp is both correct and cheaper than the
 * old strstr-anywhere match. */
#define JB_MAX_PREFIX 24
static const char *kExemptPrefixes[] = {
    "/etc/hosts", "/etc/resolv.conf", "/etc/passwd",
    "/usr/lib/dyld", "/usr/lib/system/", "/System/Library",
    "/System/Volumes/Preboot/Cryptexes/OS/",
    "/private/preboot/Cryptexes/OS/",
    NULL
};
/* v6.10 fast path: most calls are either under /System (exempt) or under the
 * jbroot. These strncmp checks answer the common cases before the token loop. */
static const char *kFastPrefixes[] = {
    "/var/jb", "/basebin", "/.jbroot",
    "/usr/lib/TweakInject", "/Library/MobileSubstrate",
    "/private/preboot", "/usr/lib/libjailbreak",
    "/usr/lib/libroothide", "/usr/lib/systemhook", NULL,
};

static char gJBRootPrefix[PATH_MAX];

/* v6.17: the prefix gates run on every intercepted call, including the common
 * benign path that never matches. Cache the literal lengths once at init so the
 * hot path does zero strlen (the biggest steady-state cost the 6.15 profiling
 * left on the table). Built from jbb_init after gJBRootPrefix is resolved. */
static uint8_t gExemptLen[JB_MAX_PREFIX];
static uint8_t gFastLen[JB_MAX_PREFIX];
static size_t gJBRootLen = 0;

static void jb_prefix_len_build(void) {
    for (int i = 0; kExemptPrefixes[i] && i < JB_MAX_PREFIX; i++)
        gExemptLen[i] = (uint8_t)strlen(kExemptPrefixes[i]);
    for (int i = 0; kFastPrefixes[i] && i < JB_MAX_PREFIX; i++)
        gFastLen[i] = (uint8_t)strlen(kFastPrefixes[i]);
    gJBRootLen = gJBRootPrefix[0] ? strlen(gJBRootPrefix) : 0;
}

static int jb_exempt(const char *p) {
    if (!p) return 0;
    for (int i = 0; kExemptPrefixes[i]; i++) {
        if (!strncmp(p, kExemptPrefixes[i], gExemptLen[i])) return 1;
    }
    return 0;
}

static int jb_path(const char *p) {
    if (!p || p[0] != '/') return 0;
    if (jb_exempt(p)) return 0;

    /* Tweaks keep resources under /Library/Application Support/<name>/...  On
     * roothide those live inside the jbroot, so the *real* path (the one a tweak
     * gets from dladdr) contains ".jbroot-", and hiding it makes the tweak unable
     * to load its own bundle (BHTwitter). Resource dirs are not jailbreak
     * indicators, so let them through. */
    if (strstr(p, "/Library/Application Support/")) return 0;

    if (gJBRootLen && !strncmp(p, gJBRootPrefix, gJBRootLen)) return 1;

    for (int i = 0; kFastPrefixes[i]; i++) {
        if (!strncmp(p, kFastPrefixes[i], gFastLen[i])) return 1;
    }

    return jb_token(p);
}

static int jb_errno(void) { errno = ENOENT; return -1; }

// ---------------------------------------------------------------- 文件 API
static int (*o_lstat)(const char *, struct stat *);
static int (*o_stat)(const char *, struct stat *);
static int (*o_access)(const char *, int);
static int (*o_faccessat)(int, const char *, int, int);
static int (*o_open)(const char *, int, ...);
static int (*o_openat)(int, const char *, int, ...);
static int (*o_fstatat)(int, const char *, struct stat *, int);
static ssize_t (*o_readlink)(const char *, char *, size_t);
static ssize_t (*o_readlinkat)(int, const char *, char *, size_t);
static char *(*o_realpath)(const char *, char *);
static DIR *(*o_opendir)(const char *);
static struct dirent *(*o_readdir)(DIR *);
static int (*o_getattrlist)(const char *, struct attrlist *, void *, size_t, unsigned long);
static FILE *(*o_fopen)(const char *, const char *);

static int h_lstat(const char *p, struct stat *b) { return jb_path(p) ? jb_errno() : o_lstat(p, b); }
static int h_stat(const char *p, struct stat *b) { return jb_path(p) ? jb_errno() : o_stat(p, b); }
static int h_access(const char *p, int m) { return jb_path(p) ? jb_errno() : o_access(p, m); }
static int h_faccessat(int d, const char *p, int m, int f) { return jb_path(p) ? jb_errno() : o_faccessat(d, p, m, f); }

static int h_open(const char *p, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }
    if (jb_path(p)) return jb_errno();
    return (flags & O_CREAT) ? o_open(p, flags, mode) : o_open(p, flags);
}

static int h_openat(int dirfd, const char *p, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }
    if (jb_path(p)) return jb_errno();
    return (flags & O_CREAT) ? o_openat(dirfd, p, flags, mode) : o_openat(dirfd, p, flags);
}

static int h_fstatat(int d, const char *p, struct stat *b, int f) { return jb_path(p) ? jb_errno() : o_fstatat(d, p, b, f); }
static ssize_t h_readlink(const char *p, char *b, size_t s) { return jb_path(p) ? jb_errno() : o_readlink(p, b, s); }
static ssize_t h_readlinkat(int d, const char *p, char *b, size_t s) { return jb_path(p) ? jb_errno() : o_readlinkat(d, p, b, s); }
static char *h_realpath(const char *p, char *r) { return jb_path(p) ? NULL : o_realpath(p, r); }
static DIR *h_opendir(const char *p) { return jb_path(p) ? NULL : o_opendir(p); }
static int h_getattrlist(const char *p, struct attrlist *a, void *b, size_t s, unsigned long o) {
    return jb_path(p) ? jb_errno() : o_getattrlist(p, a, b, s, o);
}
static FILE *h_fopen(const char *p, const char *m) { return jb_path(p) ? NULL : o_fopen(p, m); }

// v6.17: statfs/fstatfs + getfsstat —— roothide 用 f_mntonname 判越狱（statfs("/usr/lib")
// 的挂载点、/var/jb 的挂载项）。隐藏 jbroot 卷身份，并从挂载表里剔除 jb 挂载项。
static int (*o_statfs)(const char *, struct statfs *);
static int (*o_fstatfs)(int, struct statfs *);
static int (*o_getfsstat)(struct statfs *, int, int);

static void jb_scrub_statfs(struct statfs *b) {
    if (!b) return;
    /* Only rewrites when the mount identity itself leaks a jb token, so a stock
     * "/" or data-volume statfs is returned untouched. */
    if (jb_token(b->f_mntonname) || jb_token(b->f_mntfromname)) {
        strlcpy(b->f_mntonname, "/", sizeof(b->f_mntonname));
        strlcpy(b->f_mntfromname, "/dev/disk0s1s1", sizeof(b->f_mntfromname));
    }
}
static int h_statfs(const char *p, struct statfs *b) {
    if (jb_path(p)) return jb_errno();
    int r = o_statfs(p, b);
    if (r == 0) jb_scrub_statfs(b);
    return r;
}
static int h_fstatfs(int fd, struct statfs *b) {
    int r = o_fstatfs(fd, b);
    if (r == 0) jb_scrub_statfs(b);
    return r;
}
/* getmntinfo/getmntinfo_r_np are libc wrappers over getfsstat, so one hook here
 * covers them too. bufsize is bytes; clamp the walk to what the buffer holds. */
static int h_getfsstat(struct statfs *buf, int bufsize, int flags) {
    int n = o_getfsstat(buf, bufsize, flags);
    if (n > 0 && buf && bufsize > 0) {
        int cap = (int)((size_t)bufsize / sizeof(struct statfs));
        int lim = n < cap ? n : cap;
        int w = 0;
        for (int i = 0; i < lim; i++) {
            if (jb_token(buf[i].f_mntonname) || jb_token(buf[i].f_mntfromname)) continue;
            if (w != i) buf[w] = buf[i];
            w++;
        }
        n = w;
    }
    return n;
}

static int jb_dir_entry_bad(const char *name) {
    if (!name) return 0;
    if (!strcmp(name, ".jbroot") || !strcmp(name, "jbroot") || !strcmp(name, "rootfs")) return 1;
    if (!strncmp(name, ".jbroot-", 8)) return 1;
    if (!strcasecmp(name, "TweakInject") || !strcasecmp(name, "Cydia") ||
        !strcasecmp(name, "Sileo") || !strcasecmp(name, "Zebra") ||
        !strcasecmp(name, "Filza") || !strcasecmp(name, "TrollStore") ||
        !strcasecmp(name, "Umbra") || !strcasecmp(name, "irisin") ||
        !strcasecmp(name, "CocoaTop") || !strcasecmp(name, "Relaxin")) return 1;
    return 0;
}

static struct dirent *h_readdir(DIR *d) {
    struct dirent *e;
    while ((e = o_readdir(d))) {
        if (!jb_dir_entry_bad(e->d_name)) return e;
    }
    return NULL;
}

// v6.17: getattrlistbulk —— Filza / 检测 SDK 用它批量列目录，绕过 readdir。
// 输出缓冲是一串打包记录，每条： [uint32 length][attribute_set_t returned]
// [按位序排列的属性...][变长数据]。ATTR_CMN_NAME 在位序上紧跟 RETURNED_ATTRS，
// 故请求了 NAME 时其 attrreference_t 固定落在记录偏移 4+20=24 处；名字串由
// attr_dataoffset（相对 attrreference 自身）定位。据此按叶名过滤、就地紧凑缓冲。
static int (*o_getattrlistbulk)(int, struct attrlist *, void *, size_t, uint64_t);
static int h_getattrlistbulk(int dirfd, struct attrlist *al, void *buf, size_t bufsize, uint64_t opts) {
    int n = o_getattrlistbulk(dirfd, al, buf, bufsize, opts);
    if (n <= 0 || !buf || !al) return n;

    /* Need the name to filter, and getattrlistbulk mandates RETURNED_ATTRS; if
     * either is absent there is nothing we can key on, so pass the data through. */
    if (!(al->commonattr & ATTR_CMN_NAME) ||
        !(al->commonattr & ATTR_CMN_RETURNED_ATTRS)) return n;

    const uint32_t pre = (uint32_t)(sizeof(uint32_t) + sizeof(attribute_set_t)); // 4 + 20
    char *end = (char *)buf + bufsize;
    char *cur = (char *)buf;
    char *dst = (char *)buf;
    int kept = 0;

    for (int i = 0; i < n; i++) {
        if (cur + sizeof(uint32_t) > end) break;
        uint32_t len = *(uint32_t *)cur;
        if (len < pre || cur + len > end) break;   // malformed: stop, keep what we have
        char *next = cur + len;

        const char *name = NULL;
        if (cur + pre + sizeof(attrreference_t) <= next) {
            attrreference_t *nr = (attrreference_t *)(cur + pre);
            char *np = (char *)nr + nr->attr_dataoffset;
            if (np >= cur && np < next && nr->attr_length > 0 &&
                np + nr->attr_length <= next)
                name = np;
        }

        if (!(name && jb_dir_entry_bad(name))) {
            if (dst != cur) memmove(dst, cur, len);
            dst += len;
            kept++;
        }
        cur = next;
    }
    return kept;
}

// ---------------------------------------------------------------- dyld 快照
#define JB_MAX_IMAGES 2048
static uint32_t (*o_count)(void);
static const char *(*o_name)(uint32_t);
static const struct mach_header *(*o_header)(uint32_t);
static intptr_t (*o_slide)(uint32_t);
static int (*o_dladdr)(const void *, Dl_info *);
static void (*o_reg_add)(void (*)(const struct mach_header *, intptr_t));
static void (*o_reg_remove)(void (*)(const struct mach_header *, intptr_t));

/* ---- v6.21: compatibility mode ------------------------------------- *
 * Some tweaks (BHTwitter / libbhFLEX) use _dyld_image_count/header/slide and
 * dladdr to locate their own image. Our image hiding removes every jbroot
 * path from that enumeration and rewrites dladdr for them, which makes those
 * tweaks fail silently (the app opens, the tweak does nothing).
 * When such a dylib is present in the process we keep the hooks installed but
 * make them pass-through, so the other tweak can find itself again.
 * Trade-off: jb images are visible in that process (detection is easier). */
static char kFakeDylib[] = "/usr/lib/libSystem.B.dylib";

/* v6.10: the old implementation walked every load command of every image on
 * every dladdr() call. ObjC runtime and crash reporters call dladdr a lot, so
 * this was the biggest steady-state CPU cost. Now we call the original and only
 * rewrite the result when the image is one we hide. */
static uintptr_t jb_libsystem_base(void)
{
    static uintptr_t base = 0;
    if (base) return base;

    uint32_t n = o_count ? o_count() : _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = o_name ? o_name(i) : _dyld_get_image_name(i);
        if (nm && strstr(nm, "/libSystem.B.dylib")) {
            const struct mach_header *mh = o_header ? o_header(i) : _dyld_get_image_header(i);
            base = (uintptr_t)mh;
            break;
        }
    }
    return base;
}

// v6.6: 一致的 dyld 索引映射：count/name/header/slide 全部对齐，避免「重名/数量对不上」
static int gCompatMode = -1;
static int jb_compat_mode(void)
{
    if (gCompatMode >= 0) return gCompatMode;

    /* v6.21.4: the BHTwitter conflict turned out to be file-path hiding, not
     * dyld hiding (see the /Library/Application Support/ exemption in jb_path).
     * Image hiding stays on everywhere; JBB_NO_HIDE=1 forces compatibility mode
     * for debugging. */
    gCompatMode = getenv("JBB_NO_HIDE") ? 1 : 0;
    return gCompatMode;
}

static uint32_t gMap[JB_MAX_IMAGES];
static uint32_t gMapReal = 0;
static volatile uint32_t gMapVisible = 0;
static volatile uint32_t gMapSeq = 0;          /* even = stable snapshot */
static volatile int gMapDirty = 1;
static pthread_mutex_t gMapWriteLock = PTHREAD_MUTEX_INITIALIZER;

static void jb_map_dirty_cb(const struct mach_header *mh, intptr_t slide)
{
    (void)mh;
    (void)slide;
    gMapDirty = 1;
}

/* Writer: serialized by a mutex, published with a seqlock. */
static void jb_dyld_map_rebuild(void)
{
    if (!gMapDirty || !o_count || !o_name) return;

    pthread_mutex_lock(&gMapWriteLock);
    if (gMapDirty) {
        uint32_t real = o_count();
        uint32_t visible = 0;

        __atomic_store_n(&gMapSeq, __atomic_load_n(&gMapSeq, __ATOMIC_RELAXED) + 1, __ATOMIC_RELEASE);
        __atomic_thread_fence(__ATOMIC_RELEASE);

        for (uint32_t i = 0; i < real && visible < JB_MAX_IMAGES; i++) {
            const char *name = o_name(i);
            if (name && jb_token(name)) continue;
            gMap[visible++] = i;
        }

        __atomic_store_n(&gMapVisible, visible, __ATOMIC_RELEASE);
        gMapReal = real;
        __atomic_thread_fence(__ATOMIC_RELEASE);
        __atomic_store_n(&gMapSeq, __atomic_load_n(&gMapSeq, __ATOMIC_RELAXED) + 1, __ATOMIC_RELEASE);

        gMapDirty = 0;
    }
    pthread_mutex_unlock(&gMapWriteLock);
}

/* Reader: no lock in the common case. Returns UINT32_MAX when the visible index
 * does not exist. Falls back to the writer lock if a writer is mid-update for an
 * unexpectedly long time. */
static uint32_t jb_map_index(uint32_t i)
{
    jb_dyld_map_rebuild();

    for (int attempt = 0; attempt < 64; attempt++) {
        uint32_t seq1 = __atomic_load_n(&gMapSeq, __ATOMIC_ACQUIRE);
        if (seq1 & 1u) continue;

        uint32_t visible = __atomic_load_n(&gMapVisible, __ATOMIC_ACQUIRE);
        uint32_t mapped = (i < visible) ? gMap[i] : UINT32_MAX;

        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        if (seq1 == __atomic_load_n(&gMapSeq, __ATOMIC_ACQUIRE)) return mapped;
    }

    pthread_mutex_lock(&gMapWriteLock);
    uint32_t visible = gMapVisible;
    uint32_t mapped = (i < visible) ? gMap[i] : UINT32_MAX;
    pthread_mutex_unlock(&gMapWriteLock);
    return mapped;
}

static uint32_t h_dyld_count(void)
{
    if (jb_compat_mode() && o_count) return o_count();
    jb_dyld_map_rebuild();
    return __atomic_load_n(&gMapVisible, __ATOMIC_ACQUIRE);
}

static const char *h_name_safe(uint32_t i) {
    if (jb_compat_mode()) return o_name ? o_name(i) : NULL;
    return o_name ? o_name(jb_map_index(i)) : NULL;
}
static const struct mach_header *h_header_safe(uint32_t i) {
    if (jb_compat_mode()) return o_header ? o_header(i) : NULL;
    return o_header ? o_header(jb_map_index(i)) : NULL;
}
static intptr_t h_slide_safe(uint32_t i) {
    if (jb_compat_mode()) return o_slide ? o_slide(i) : 0;
    return o_slide ? o_slide(jb_map_index(i)) : 0;
}

static int h_dladdr(const void *addr, Dl_info *info) {
    if (!o_dladdr) return 0;
    if (jb_compat_mode()) return o_dladdr(addr, info);
    int r = o_dladdr(addr, info);
    if (r && info && info->dli_fname && jb_token(info->dli_fname)) {
        /* Same observable result as 6.9 (name + base both point at libSystem),
         * but without scanning every image on every call. */
        uintptr_t base = jb_libsystem_base();
        info->dli_fname = kFakeDylib;
        info->dli_fbase = (void *)(base ? base : info->dli_fbase);
        info->dli_sname = NULL;
        info->dli_saddr = NULL;
    }
    return r;
}

// v6.17: task_info(TASK_DYLD_INFO) —— 堵住绕过 _dyld_* API、直读 all_image_infos
// 的检测（task_info 返回 all_image_info_addr，检测方据此遍历 infoArray[].imageFilePath）。
// 做法：调用原函数拿到真实结构，复制一份、从 infoArray 里剔除命中 token 的镜像，
// 把返回的地址改指向我们的副本。只对本进程（mach_task_self）生效，避免对远程
// task 解引用他进程内存而崩溃。
static kern_return_t (*o_task_info)(task_name_t, task_flavor_t, task_info_t, mach_msg_type_number_t *);
static struct dyld_all_image_infos gFakeInfos;
static struct dyld_image_info gFakeImgArray[JB_MAX_IMAGES];
static pthread_mutex_t gInfosLock = PTHREAD_MUTEX_INITIALIZER;

static kern_return_t h_task_info(task_name_t task, task_flavor_t flavor,
                                 task_info_t info, mach_msg_type_number_t *cnt) {
    kern_return_t kr = o_task_info(task, flavor, info, cnt);
    if (jb_compat_mode()) return kr;
    if (kr != KERN_SUCCESS || flavor != TASK_DYLD_INFO || !info || !cnt ||
        *cnt < TASK_DYLD_INFO_COUNT || task != mach_task_self())
        return kr;

    struct task_dyld_info *di = (struct task_dyld_info *)info;
    const struct dyld_all_image_infos *real =
        (const struct dyld_all_image_infos *)(uintptr_t)di->all_image_info_addr;
    if (!real || !real->infoArray || real->infoArrayCount == 0) return kr;

    pthread_mutex_lock(&gInfosLock);
    /* Copy the whole struct so every version-specific field (dyldPath,
     * notification, uuidArray...) keeps pointing at the real dyld data; we only
     * override the image array and its count. */
    memcpy(&gFakeInfos, real, sizeof(gFakeInfos));
    uint32_t w = 0;
    for (uint32_t i = 0; i < real->infoArrayCount && w < JB_MAX_IMAGES; i++) {
        const char *path = real->infoArray[i].imageFilePath;
        if (path && jb_token(path)) continue;
        gFakeImgArray[w++] = real->infoArray[i];
    }
    gFakeInfos.infoArray = gFakeImgArray;
    gFakeInfos.infoArrayCount = w;
    di->all_image_info_addr = (mach_vm_address_t)(uintptr_t)&gFakeInfos;
    pthread_mutex_unlock(&gInfosLock);
    return kr;
}

// ---------------------------------------------------------------- 反调试（Frida/SSH 检测已按需求移除）
// v6.6: csops —— 去掉 GET_TASK_ALLOW / DEBUGGED
static int (*o_csops)(pid_t, unsigned int, void *, size_t);
static int (*o_csops_audittoken)(pid_t, unsigned int, void *, size_t, audit_token_t *);

static void jb_scrub_csflags(pid_t pid, void *buf, size_t sz, unsigned int op) {
    if (!gCsops || !buf || sz < sizeof(uint32_t) || op != 0) return;
    if (pid != 0 && pid != getpid()) return;
    uint32_t *f = (uint32_t *)buf;
    *f &= ~0x00000004u;   // CS_GET_TASK_ALLOW
    *f &= ~0x10000000u;   // CS_DEBUGGED
}

static int h_csops(pid_t pid, unsigned int op, void *buf, size_t sz) {
    int r = o_csops ? o_csops(pid, op, buf, sz) : -1;
    if (r == 0) jb_scrub_csflags(pid, buf, sz, op);
    return r;
}

/* v6.7: csops_audittoken has a fifth argument and is a different syscall.
 * v6.6 routed it to h_csops, which called the csops original instead. */
static int h_csops_audittoken(pid_t pid, unsigned int op, void *buf, size_t sz, audit_token_t *token) {
    int r = o_csops_audittoken ? o_csops_audittoken(pid, op, buf, sz, token) : -1;
    if (r == 0) jb_scrub_csflags(pid, buf, sz, op);
    return r;
}

static int (*o_ptrace)(int, pid_t, caddr_t, int);
static int h_ptrace(int req, pid_t pid, caddr_t addr, int data) {
    if (req == 31) return 0;                 // PT_DENY_ATTACH
    return o_ptrace(req, pid, addr, data);
}

static int jb_proc_bad(const char *comm);
static int (*o_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int h_sysctl(int *name, u_int nl, void *oldp, size_t *olp, void *newp, size_t nlp) {
    int r = o_sysctl(name, nl, oldp, olp, newp, nlp);
    if (r == 0 && oldp && olp && nl >= 4 &&
        name[0] == CTL_KERN && name[1] == KERN_PROC && name[2] == KERN_PROC_PID &&
        (pid_t)name[3] == getpid() && *olp >= sizeof(struct kinfo_proc)) {
        struct kinfo_proc *kp = (struct kinfo_proc *)oldp;
        kp->kp_proc.p_flag &= ~(P_TRACED | P_SELECT);
        kp->kp_eproc.e_ppid = 1;
    }
    // v6: KERN_PROC_ALL —— 压掉越狱相关进程
    if (r == 0 && oldp && olp && name[0] == CTL_KERN && name[1] == KERN_PROC &&
        name[2] == KERN_PROC_ALL) {
        struct kinfo_proc *arr = (struct kinfo_proc *)oldp;
        size_t esz = sizeof(struct kinfo_proc);
        size_t n = *olp / esz, w = 0;
        for (size_t i = 0; i < n; i++) {
            if (!jb_proc_bad(arr[i].kp_proc.p_comm)) {
                if (w != i) arr[w] = arr[i];
                w++;
            }
        }
        *olp = w * esz;
    }
    return r;
}

// v6: 进程表里隐藏越狱守护进程 / 管理器
static int jb_proc_bad(const char *comm) {
    if (!comm) return 0;
    return jb_token(comm);
}

static int (*o_getppid)(void);
static pid_t h_getppid(void) { pid_t p = o_getppid ? o_getppid() : 1; return p > 1 ? 1 : p; }

static char *(*o_getenv)(const char *);
static char *h_getenv(const char *name) {
    if (name && (!strncmp(name, "DYLD_", 5) || !strcmp(name, "_MSSafeMode") ||
                 !strcmp(name, "_SafeMode") || !strncmp(name, "JAILBREAKD", 10)))
        return NULL;
    return o_getenv(name);
}

// ---------------------------------------------------------------- ObjC
static BOOL (*o_fileExists)(id, SEL, NSString *);
static BOOL h_fileExists(id self, SEL _cmd, NSString *path) {
    if (jb_path([path fileSystemRepresentation])) return NO;
    return o_fileExists(self, _cmd, path);
}
static BOOL (*o_canOpen)(id, SEL, NSURL *);
static BOOL h_canOpen(id self, SEL _cmd, NSURL *u) {
    NSString *s = [[u absoluteString] lowercaseString];
    static const char *schemes[] = {
        "cydia:", "sileo:", "zbra:", "zebra:", "filza:", "trollstore:",
        "activator:", "appinst:", "undecimus:", "checkra1n:", "xina:", "odyssey:",
        NULL
    };
    for (int i = 0; schemes[i]; i++) {
        if ([s hasPrefix:[NSString stringWithUTF8String:schemes[i]]]) return NO;
    }
    return o_canOpen(self, _cmd, u);
}
static NSArray *(*o_contents)(id, SEL, NSString *, NSError **);
static NSArray *h_contents(id self, SEL _cmd, NSString *p, NSError **e) {
    if (jb_path([p fileSystemRepresentation])) return @[];
    return o_contents(self, _cmd, p, e);
}
static NSDictionary *(*o_attrs)(id, SEL, NSString *, NSError **);
static NSDictionary *h_attrs(id self, SEL _cmd, NSString *p, NSError **e) {
    if (jb_path([p fileSystemRepresentation])) {
        if (e) *e = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
        return nil;
    }
    return o_attrs(self, _cmd, p, e);
}

static void jb_swizzle(Class c, SEL s, void *rep, void **orig) {
    Method m = class_getInstanceMethod(c, s);
    if (!m) return;
    if (orig && !*orig) *orig = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)rep);
}

// ---------------------------------------------------------------- 构造
__attribute__((constructor))
static void jbb_init(void) {
    jb_marker("jbb_v617_ctor");
    {
        /* v6.10: remember our own root so jb_path() can answer the common case
         * with one strncmp instead of the token loop. */
        Dl_info selfInfo; memset(&selfInfo, 0, sizeof(selfInfo));
        if (dladdr((void *)jb_marker_msg, &selfInfo) && selfInfo.dli_fname) {
            const char *markerA = strstr(selfInfo.dli_fname, "/usr/lib/TweakInject/");
            const char *markerB = strstr(selfInfo.dli_fname, "/basebin/");
            const char *marker = markerA ? markerA : markerB;
            if (marker) {
                size_t len = (size_t)(marker - selfInfo.dli_fname);
                if (len < sizeof(gJBRootPrefix)) {
                    memcpy(gJBRootPrefix, selfInfo.dli_fname, len);
                    gJBRootPrefix[len] = '\0';
                }
            }
        }
    }
    jb_load_profile();
    if (gTokenCount == 0) jb_tokens_init(NO, nil);
    jb_prefix_len_build();   // cache prefix lengths after gJBRootPrefix is resolved

#ifdef JBB_DIAG_LOG
    /* S19 Bug B self-check: write the decisive state into the app container so a
     * tester can tell "did jbb read config, and is it enabled" without logs
     * (os_log/log show are empty under roothide). Diagnostic builds only. */
    @autoreleasepool {
        NSString *s = [NSString stringWithFormat:@"bid=%@ configFound=%d enabled=%d\n",
            [[NSBundle mainBundle] bundleIdentifier] ?: @"?", gConfigFound, gEnabled];
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        [s writeToFile:[dir stringByAppendingPathComponent:@"jbb-state.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
#endif

    if (!gEnabled || getenv("JBB_DISABLE")) { jb_marker("jbb_disabled"); return; }
    jb_load_hook_framework();
    if (!MSHook) { jb_marker("jbb_v6_nohook"); return; }
    jb_marker("jbb_v617_hookok");

    // 原始 dyld API（必须在 hook 前保存）
    o_count  = (uint32_t (*)(void))dlsym(RTLD_DEFAULT, "_dyld_image_count");
    o_name   = (const char *(*)(uint32_t))dlsym(RTLD_DEFAULT, "_dyld_get_image_name");
    o_header = (const struct mach_header *(*)(uint32_t))dlsym(RTLD_DEFAULT, "_dyld_get_image_header");
    o_slide  = (intptr_t (*)(uint32_t))dlsym(RTLD_DEFAULT, "_dyld_get_image_vmaddr_slide");
    o_dladdr = (int (*)(const void *, Dl_info *))dlsym(RTLD_DEFAULT, "dladdr");
    o_reg_add = (void (*)(void (*)(const struct mach_header *, intptr_t)))dlsym(RTLD_DEFAULT, "_dyld_register_func_for_add_image");
    o_reg_remove = (void (*)(void (*)(const struct mach_header *, intptr_t)))dlsym(RTLD_DEFAULT, "_dyld_register_func_for_remove_image");

    // 文件 API
    if (gFile) {
    jb_hook("lstat", (void *)h_lstat, (void **)&o_lstat);
    jb_hook("stat", (void *)h_stat, (void **)&o_stat);
    jb_hook("access", (void *)h_access, (void **)&o_access);
    jb_hook("faccessat", (void *)h_faccessat, (void **)&o_faccessat);
    jb_hook("open", (void *)h_open, (void **)&o_open);
    jb_hook("openat", (void *)h_openat, (void **)&o_openat);
    jb_hook("fstatat", (void *)h_fstatat, (void **)&o_fstatat);
    jb_hook("readlink", (void *)h_readlink, (void **)&o_readlink);
    jb_hook("readlinkat", (void *)h_readlinkat, (void **)&o_readlinkat);
    jb_hook("realpath", (void *)h_realpath, (void **)&o_realpath);
    jb_hook("opendir", (void *)h_opendir, (void **)&o_opendir);
    jb_hook("readdir", (void *)h_readdir, (void **)&o_readdir);
    jb_hook("getattrlistbulk", (void *)h_getattrlistbulk, (void **)&o_getattrlistbulk);
    jb_hook("getattrlist", (void *)h_getattrlist, (void **)&o_getattrlist);
    jb_hook("fopen", (void *)h_fopen, (void **)&o_fopen);
    jb_hook("statfs", (void *)h_statfs, (void **)&o_statfs);
    jb_hook("fstatfs", (void *)h_fstatfs, (void **)&o_fstatfs);
    jb_hook("getfsstat", (void *)h_getfsstat, (void **)&o_getfsstat);
    }

    // dyld（安全版：只 hook name + dladdr，不碰 count/header/slide，避免 dyld 死锁）
#ifndef JB_NO_DLADDR
    if (gDyld && o_dladdr) {
        void *o = NULL;
        MSHook((void *)o_dladdr, (void *)h_dladdr, &o);
        o_dladdr = (int (*)(const void *, Dl_info *))o;
    }
#endif
    if (gName && o_name) {
        _dyld_register_func_for_add_image(jb_map_dirty_cb);
        _dyld_register_func_for_remove_image(jb_map_dirty_cb);
        void *o = NULL;
        if (o_count)  { MSHook((void *)o_count,  (void *)h_dyld_count,  &o); o_count  = (uint32_t (*)(void))o; }
        MSHook((void *)o_name, (void *)h_name_safe, &o);
        o_name = (const char *(*)(uint32_t))o;
        if (o_header) { MSHook((void *)o_header, (void *)h_header_safe, &o); o_header = (const struct mach_header *(*)(uint32_t))o; }
        if (o_slide)  { MSHook((void *)o_slide,  (void *)h_slide_safe,  &o); o_slide  = (intptr_t (*)(uint32_t))o; }

        // 同属"隐藏镜像列表"：堵住直读 all_image_infos 的 task_info 路径
        jb_hook("task_info", (void *)h_task_info, (void **)&o_task_info);
    }


    if (gCsops) {
        jb_hook("csops", (void *)h_csops, (void **)&o_csops);
        jb_hook("csops_audittoken", (void *)h_csops_audittoken, (void **)&o_csops_audittoken);
    }
    if (gPtrace) jb_hook("ptrace", (void *)h_ptrace, (void **)&o_ptrace);
    if (gSysctl) jb_hook("sysctl", (void *)h_sysctl, (void **)&o_sysctl);
    if (gPpid)   jb_hook("getppid", (void *)h_getppid, (void **)&o_getppid);
    if (gEnv)    jb_hook("getenv", (void *)h_getenv, (void **)&o_getenv);

    // ObjC
    Class fm = gObjC ? objc_getClass("NSFileManager") : nil;
    if (fm) {
        jb_swizzle(fm, @selector(fileExistsAtPath:), (void *)h_fileExists, (void **)&o_fileExists);
        jb_swizzle(fm, @selector(contentsOfDirectoryAtPath:error:), (void *)h_contents, (void **)&o_contents);
        jb_swizzle(fm, @selector(attributesOfItemAtPath:error:), (void *)h_attrs, (void **)&o_attrs);
    }
    Class ua = gObjC ? objc_getClass("UIApplication") : nil;
    if (ua) jb_swizzle(ua, @selector(canOpenURL:), (void *)h_canOpen, (void **)&o_canOpen);

    if (gDiag) {
        jb_install_signal_handlers();
        jb_hook("exit", (void *)h_exit, (void **)&o_exit);
        jb_hook("_exit", (void *)h__exit, (void **)&o__exit);
        jb_hook("abort", (void *)h_abort, (void **)&o_abort);
        jb_hook("kill", (void *)h_kill, (void **)&o_kill);
    }
}
