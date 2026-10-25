#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <unistd.h>

static double ms_since(uint64_t a, uint64_t b) {
    mach_timebase_info_data_t t; mach_timebase_info(&t);
    return (double)(b - a) * t.numer / t.denom / 1e6;
}

static void runNow(void) {
    @autoreleasepool {
        struct stat st; Dl_info di;
        const char *sys  = "/System/Library/CoreServices/SystemVersion.plist";
        const char *miss = "/var/mobile/Library/Preferences/com.apple.mobilesafari.plist";
        void *hidden = (void *)&runNow; /* lives under TweakInject -> a token path */

        for (int i = 0; i < 2000; i++) { stat(sys, &st); stat(miss, &st); dladdr(hidden, &di); }

        double bestA = 1e9, bestB = 1e9, bestC = 1e9;
        for (int round = 0; round < 3; round++) {
            uint64_t a = mach_absolute_time();
            for (int i = 0; i < 5000; i++) stat(sys, &st);
            uint64_t b = mach_absolute_time();
            for (int i = 0; i < 5000; i++) stat(miss, &st);
            uint64_t c = mach_absolute_time();
            for (int i = 0; i < 500; i++) dladdr(hidden, &di);
            uint64_t d = mach_absolute_time();
            double x = ms_since(a,b), y = ms_since(b,c), z = ms_since(c,d);
            if (x < bestA) bestA = x;
            if (y < bestB) bestB = y;
            if (z < bestC) bestC = z;
        }
        double x = bestA, y = bestB, z = bestC;

        NSString *r = [NSString stringWithFormat:
            @"bench pid=%d\n"
             "exempt stat : %.2f ms / 20k  (%.0f ns/op)\n"
             "miss   stat : %.2f ms / 20k  (%.0f ns/op)\n"
             "dladdr hidden: %.2f ms / 20k  (%.0f ns/op)\n",
            getpid(),
            x, x * 1e6 / 5000,
            y, y * 1e6 / 5000,
            z, z * 1e6 / 5000];

        [r writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/jbb_bench.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

__attribute__((constructor)) static void bench_ctor(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        runNow();
    });
}
