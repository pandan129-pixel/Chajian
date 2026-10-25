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
#include "litehook/litehook.h"

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

static void jb_load_profile(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid) return;
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
        NSDictionary *pp = all[bid];
        if (![pp isKindOfClass:[NSDictionary class]]) return;
        gFile = [pp[@"file"] boolValue]; gDyld = [pp[@"dyld"] boolValue];
        gName = [pp[@"name"] boolValue]; gSysctl = [pp[@"sysctl"] boolValue];
        gPtrace = [pp[@"ptrace"] boolValue]; gEnv = [pp[@"env"] boolValue];
        gPpid = [pp[@"ppid"] boolValue]; gObjC = [pp[@"objc"] boolValue];
        gCsops = [pp[@"csops"] boolValue];
        gDiag = [pp[@"diag"] boolValue];
        if (pp[@"enabled"]) gEnabled = [pp[@"enabled"] boolValue];
        jb_tokens_init([pp[@"extraTokens"] boolValue], pp[@"tokens"]);
        char m[160];
        snprintf(m, sizeof(m), "file=%d dyld=%d name=%d sysctl=%d ptrace=%d env=%d objc=%d",
                 gFile, gDyld, gName, gSysctl, gPtrace, gEnv, gObjC);
        jb_marker_msg("jbb_v62_profile", m);
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
static int jb_exempt(const char *p) {
    if (!p) return 0;
    /* These are absolute prefixes, so strncmp is both correct and cheaper than
     * the old strstr-anywhere match. */
    static const char *ok[] = {
        "/etc/hosts", "/etc/resolv.conf", "/etc/passwd",
        "/usr/lib/dyld", "/usr/lib/system/", "/System/Library",
        "/System/Volumes/Preboot/Cryptexes/OS/",
        "/private/preboot/Cryptexes/OS/",
        NULL
    };
    for (int i = 0; ok[i]; i++) {
        size_t len = strlen(ok[i]);
        if (!strncmp(p, ok[i], len)) return 1;
    }
    return 0;
}

static char gJBRootPrefix[PATH_MAX];

/* v6.10 fast path: most calls are either under /System (exempt) or under the
 * jbroot. Two strncmp checks answer the common cases before the token loop. */
static int jb_path(const char *p) {
    if (!p || p[0] != '/') return 0;
    if (jb_exempt(p)) return 0;

    if (gJBRootPrefix[0] && !strncmp(p, gJBRootPrefix, strlen(gJBRootPrefix))) return 1;

    static const char *kFastPrefixes[] = {
        "/var/jb", "/basebin", "/.jbroot",
        "/usr/lib/TweakInject", "/Library/MobileSubstrate",
        "/private/preboot", "/usr/lib/libjailbreak",
        "/usr/lib/libroothide", "/usr/lib/systemhook", NULL,
    };
    for (int i = 0; kFastPrefixes[i]; i++) {
        if (!strncmp(p, kFastPrefixes[i], strlen(kFastPrefixes[i]))) return 1;
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

// ---------------------------------------------------------------- dyld 快照
#define JB_MAX_IMAGES 2048
static uint32_t (*o_count)(void);
static const char *(*o_name)(uint32_t);
static const struct mach_header *(*o_header)(uint32_t);
static intptr_t (*o_slide)(uint32_t);
static int (*o_dladdr)(const void *, Dl_info *);
static void (*o_reg_add)(void (*)(const struct mach_header *, intptr_t));
static void (*o_reg_remove)(void (*)(const struct mach_header *, intptr_t));

typedef struct {
    uint32_t n;
    const char *name[JB_MAX_IMAGES];
    const struct mach_header *hdr[JB_MAX_IMAGES];
    intptr_t slide[JB_MAX_IMAGES];
} jb_snap_t;

static jb_snap_t gSnap;
static pthread_mutex_t gSnapLock = PTHREAD_MUTEX_INITIALIZER;
static volatile int gSnapDirty = 1;

static void jb_rebuild_snap(void) {
    pthread_mutex_lock(&gSnapLock);
    if (o_count && o_name) {
        uint32_t n = o_count();
        uint32_t k = 0;
        for (uint32_t i = 0; i < n && k < JB_MAX_IMAGES; i++) {
            const char *nm = o_name(i);
            if (!nm || jb_token(nm)) continue;
            gSnap.name[k] = nm;
            gSnap.hdr[k] = o_header ? o_header(i) : NULL;
            gSnap.slide[k] = o_slide ? o_slide(i) : 0;
            k++;
        }
        __atomic_store_n(&gSnap.n, k, __ATOMIC_RELEASE);
    }
    gSnapDirty = 0;
    pthread_mutex_unlock(&gSnapLock);
}

static int jb_try_rebuild(void) {
    if (pthread_mutex_trylock(&gSnapLock) != 0) return 0;
    if (o_count && o_name) {
        uint32_t n = o_count();
        uint32_t k = 0;
        for (uint32_t i = 0; i < n && k < JB_MAX_IMAGES; i++) {
            const char *nm = o_name(i);
            if (!nm || jb_token(nm)) continue;
            gSnap.name[k] = nm;
            gSnap.hdr[k] = o_header ? o_header(i) : NULL;
            gSnap.slide[k] = o_slide ? o_slide(i) : 0;
            k++;
        }
        __atomic_store_n(&gSnap.n, k, __ATOMIC_RELEASE);
    }
    gSnapDirty = 0;
    pthread_mutex_unlock(&gSnapLock);
    return 1;
}

static void jb_img_cb(const struct mach_header *mh, intptr_t slide) {
    (void)mh; (void)slide;
    gSnapDirty = 1;
}

static uint32_t h_count(void) {
    if (gSnapDirty) jb_try_rebuild();
    return __atomic_load_n(&gSnap.n, __ATOMIC_ACQUIRE);
}
static const char *h_name(uint32_t i) {
    if (gSnapDirty) jb_try_rebuild();
    return (i < gSnap.n) ? gSnap.name[i] : NULL;
}
static const struct mach_header *h_header(uint32_t i) {
    if (gSnapDirty) jb_try_rebuild();
    return (i < gSnap.n) ? gSnap.hdr[i] : NULL;
}
static intptr_t h_slide(uint32_t i) {
    if (gSnapDirty) jb_try_rebuild();
    return (i < gSnap.n) ? gSnap.slide[i] : 0;
}
// ---- v4 的 dladdr 自实现（litehook，无 orig）----
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
    jb_dyld_map_rebuild();
    return __atomic_load_n(&gMapVisible, __ATOMIC_ACQUIRE);
}

static const char *h_name_safe(uint32_t i) { return o_name ? o_name(jb_map_index(i)) : NULL; }
static const struct mach_header *h_header_safe(uint32_t i) { return o_header ? o_header(jb_map_index(i)) : NULL; }
static intptr_t h_slide_safe(uint32_t i) { return o_slide ? o_slide(jb_map_index(i)) : 0; }

static int h_dladdr(const void *addr, Dl_info *info) {
    if (!o_dladdr) return 0;
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
    jb_marker("jbb_v615_ctor");
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

    if (!gEnabled || getenv("JBB_DISABLE")) { jb_marker("jbb_disabled"); return; }
    jb_load_hook_framework();
    if (!MSHook) { jb_marker("jbb_v6_nohook"); return; }
    jb_marker("jbb_v615_hookok");

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
    jb_hook("getattrlist", (void *)h_getattrlist, (void **)&o_getattrlist);
    jb_hook("fopen", (void *)h_fopen, (void **)&o_fopen);
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
