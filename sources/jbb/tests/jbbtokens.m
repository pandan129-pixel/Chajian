#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>

/* Measures only paths that jbb intercepts (no syscall), so the number is jbb's
 * own cost. Ordered by where the matching token sits in the table:
 *   /var/jb        -> first core token
 *   /zz/roothide   -> late core token
 *   /zz/substrate  -> last core token
 *   /zz/cycript    -> extra-tier token (only matched when extraTokens=true)
 */
static double cpu_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
    return (double)ts.tv_sec * 1e9 + (double)ts.tv_nsec;
}

static double bench(const char *path, int rounds) {
    struct stat st;
    double best = 1e18;
    for (int r = 0; r < rounds; r++) {
        double a = cpu_ns();
        for (int i = 0; i < 50000; i++) { errno = 0; stat(path, &st); }
        double b = cpu_ns();
        double ns = (b - a) / 50000.0;
        if (ns < best) best = ns;
    }
    return best;
}

static void runNow(void) {
    @autoreleasepool {
        const char *p1 = "/var/jb";
        const char *p2 = "/zz/roothide";
        const char *p3 = "/zz/substrate";
        const char *p4 = "/zz/cycript";
        struct stat st;
        for (int i = 0; i < 2000; i++) { stat(p1,&st); stat(p2,&st); stat(p3,&st); stat(p4,&st); }

        double a = bench(p1, 3), b = bench(p2, 3), c = bench(p3, 3), d = bench(p4, 3);

        NSString *r = [NSString stringWithFormat:
            @"cost pid=%d\n"
             "early  /var/jb       : %7.1f ns/op\n"
             "late   /zz/roothide  : %7.1f ns/op\n"
             "last   /zz/substrate : %7.1f ns/op\n"
             "extra  /zz/cycript   : %7.1f ns/op  (hit => extraTokens on; miss => syscall)\n",
            getpid(), a, b, c, d];

        [r writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/jbb_cost.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

__attribute__((constructor)) static void probe_ctor(void) { runNow(); }
