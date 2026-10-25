#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <unistd.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <mach-o/dyld_images.h>
#include <mach/mach.h>

extern int csops(pid_t, unsigned int, void *, size_t);

static NSMutableString *R;

static int tok(const char *p) {
    static const char *t[] = {"systemhook","jbroot","roothide","TweakInject","jbb","ellekit","libhooker","substrate",NULL};
    for (int i = 0; t[i]; i++) if (p && strcasestr(p, t[i])) return 1;
    return 0;
}
static void L(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    [R appendFormat:@"%@\n", [[NSString alloc] initWithFormat:fmt arguments:ap]];
    va_end(ap);
}

static void run(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            R = [NSMutableString string];
            L(@"=== jbprobe pid=%d ===", getpid());

            uint32_t f = 0;
            int cr = csops(getpid(), 0, &f, sizeof(f));
            L(@"csops r=%d flags=0x%08x GET_TASK_ALLOW=%d DEBUGGED=%d", cr, f, !!(f & 4), !!(f & 0x10000000));

            const char *e = getenv("DYLD_INSERT_LIBRARIES");
            L(@"env DYLD_INSERT=%s", e ? e : "(null)");

            uint32_t n = _dyld_image_count();
            NSMutableSet *seen = [NSMutableSet set];
            int susp = 0, dup = 0;
            for (uint32_t i = 0; i < n; i++) {
                const char *nm = _dyld_get_image_name(i);
                if (!nm) continue;
                if (tok(nm)) { susp++; continue; }
                NSString *s = [NSString stringWithUTF8String:nm];
                if ([seen containsObject:s]) dup++; else [seen addObject:s];
            }
            L(@"dyld count=%u susp=%d dup=%d unique=%lu", n, susp, dup, (unsigned long)seen.count);

            /* direct dyld_all_image_infos read: the known blind spot */
            task_dyld_info_data_t di; uint32_t dc = TASK_DYLD_INFO_COUNT;
            if (task_info(mach_task_self(), TASK_DYLD_INFO, (task_info_t)&di, &dc) == KERN_SUCCESS) {
                struct dyld_all_image_infos *ai = (struct dyld_all_image_infos *)di.all_image_info_addr;
                int leak = 0;
                for (uint32_t i = 0; ai && i < ai->infoArrayCount; i++) {
                    if (tok(ai->infoArray[i].imageFilePath)) leak++;
                }
                L(@"infoarray count=%u token_hits=%d", ai ? ai->infoArrayCount : 0, leak);
            }

            const char *paths[] = {"/var/jb","/var/jb/bin/sh","/usr/lib/TweakInject","/usr/lib/libellekit.dylib",
                                   "/usr/lib/libsubstrate.dylib","/basebin","/.jbroot","/Applications/Sileo.app",NULL};
            for (int i = 0; paths[i]; i++) {
                struct stat st; errno = 0;
                int r = stat(paths[i], &st);
                L(@"stat %-34s r=%d errno=%d", paths[i], r, errno);
            }

            uid_t uid = getuid();
            L(@"getppid=%d uid=%u", getppid(), uid);

            int fd = socket(AF_INET, SOCK_STREAM, 0);
            int conn = -1;
            if (fd >= 0) {
                struct sockaddr_in sa; memset(&sa, 0, sizeof(sa));
                sa.sin_family = AF_INET; sa.sin_port = htons(27042);
                sa.sin_addr.s_addr = inet_addr("127.0.0.1");
                struct timeval tv = {1, 0};
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
                conn = connect(fd, (struct sockaddr *)&sa, sizeof(sa));
                close(fd);
            }
            L(@"connect 127.0.0.1:27042 = %d errno=%d", conn, errno);

            void *h = dlopen("/usr/lib/libjailbreak.dylib", RTLD_NOW);
            L(@"dlopen libjailbreak = %s", h ? "SUCCESS" : dlerror());

            NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
            [R writeToFile:[docs stringByAppendingPathComponent:@"jbprobe.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    });
}

__attribute__((constructor)) static void ctor(void) { run(); }
