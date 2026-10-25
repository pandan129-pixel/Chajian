#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <mach/mach_time.h>
#include <unistd.h>
#include <errno.h>

static double ms_since(uint64_t a, uint64_t b) {
    mach_timebase_info_data_t t; mach_timebase_info(&t);
    return (double)(b - a) * t.numer / t.denom / 1e6;
}

static double best_ns(const char *path, int rounds) {
    struct stat st;
    double best = 1e18;
    for (int r = 0; r < rounds; r++) {
        uint64_t a = mach_absolute_time();
        for (int i = 0; i < 20000; i++) { errno = 0; stat(path, &st); }
        uint64_t b = mach_absolute_time();
        double ns = ms_since(a, b) * 1e6 / 20000.0;
        if (ns < best) best = ns;
    }
    return best;
}

static void runNow(void) {
    @autoreleasepool {
        /* warmup */
        struct stat st;
        for (int i = 0; i < 2000; i++) { stat("/var/jb", &st); stat("/System/Library/CoreServices/SystemVersion.plist", &st); }

        double blocked = best_ns("/var/jb", 3);                    /* jbb returns -1, no syscall */
        double allowed = best_ns("/System/Library/CoreServices/SystemVersion.plist", 3); /* real syscall */
        double enoent  = best_ns("/var/mobile/Library/Preferences/jbb-probe-does-not-exist.plist", 3); /* real syscall */

        NSString *r = [NSString stringWithFormat:
            @"probe pid=%d\n"
             "blocked  /var/jb        : %8.0f ns/op  (no syscall, pure jbb cost)\n"
             "allowed  SystemVersion  : %8.0f ns/op  (real stat)\n"
             "enoent   missing file   : %8.0f ns/op  (real stat, ENOENT)\n",
            getpid(), blocked, allowed, enoent];

        [r writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/jbb_cost.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

static int gDone = 0;
__attribute__((constructor)) static void probe_ctor(void) {
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 2ull * NSEC_PER_SEC), 2ull * NSEC_PER_SEC, 0);
    dispatch_source_set_event_handler(t, ^{
        if (gDone) return;
        gDone = 1;
        runNow();
        dispatch_source_cancel(t);
    });
    dispatch_resume(t);
}
