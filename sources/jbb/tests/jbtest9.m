#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>

extern int csops(pid_t, unsigned int, void *, size_t);
static NSMutableString *R;
static int bad(const char *p){
    static const char *t[]={"systemhook","jbroot","roothide","TweakInject","jbb","ellekit","libhooker","substrate",NULL};
    for(int i=0;t[i];i++) if(p&&strcasestr(p,t[i])) return 1;
    return 0;
}
static void L(NSString *fmt, ...){ va_list ap; va_start(ap,fmt); [R appendFormat:@"%@\n",[[NSString alloc] initWithFormat:fmt arguments:ap]]; va_end(ap); }

__attribute__((constructor)) static void run(void){
    @autoreleasepool {
        R=[NSMutableString string];
        NSString *docs=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        [[NSFileManager defaultManager] createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
        L(@"=== jbtest9 pid=%d uid=%d ===", getpid(), getuid());
        const char *paths[]={"/var/jb","/var/jb/bin/sh","/Applications/Sileo.app","/Applications/Cydia.app",
            "/usr/lib/TweakInject","/usr/lib/libellekit.dylib","/usr/lib/libsubstrate.dylib","/basebin","/.jbroot",NULL};
        for(int i=0;paths[i];i++){ struct stat st; errno=0; int r=stat(paths[i],&st); L(@"stat %-42s r=%d errno=%d",paths[i],r,errno); }
        uint32_t f=0; int cr=csops(getpid(),0,&f,sizeof(f));
        L(@"csops r=%d flags=0x%08x GET_TASK_ALLOW=%d DEBUGGED=%d", cr,f,!!(f&4),!!(f&0x10000000));
        const char *e=getenv("DYLD_INSERT_LIBRARIES"); L(@"env DYLD_INSERT=%s", e?e:"(null)");
        uint32_t n=_dyld_image_count(); int susp=0,nulln=0; NSMutableSet *seen=[NSMutableSet set]; int dup=0;
        for(uint32_t i=0;i<n;i++){ const char *nm=_dyld_get_image_name(i);
            if(!nm){nulln++;continue;}
            if(bad(nm)){susp++; L(@"dyld SUSP %s",nm); continue;}
            NSString *s=[NSString stringWithUTF8String:nm];
            if(s){ if([seen containsObject:s]) dup++; else [seen addObject:s]; } }
        L(@"dyld count=%u susp=%d null=%d dup=%d unique=%lu", n,susp,nulln,dup,(unsigned long)seen.count);
        int mib[4]={CTL_KERN,KERN_PROC,KERN_PROC_ALL,0}; size_t len=0;
        if(sysctl(mib,4,NULL,&len,NULL,0)==0&&len){ struct kinfo_proc *kp=malloc(len);
            if(kp&&sysctl(mib,4,kp,&len,NULL,0)==0){ int cnt=len/sizeof(struct kinfo_proc),hits=0;
                for(int i=0;i<cnt;i++){ const char *c=kp[i].kp_proc.p_comm;
                    if(strcasestr(c,"jailbreak")||strcasestr(c,"dopamine")||strcasestr(c,"roothide")||strcasestr(c,"ellekit")||strcasestr(c,"irisin")){hits++;L(@"proc SUSP %s",c);} }
                L(@"proc total=%d susp=%d",cnt,hits); }
            free(kp); } else L(@"proc enum failed errno=%d",errno);
        NSArray *items=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:nil];
        int jb=0; for(NSString *s in items) if([s hasPrefix:@".jbroot-"]) jb++;
        L(@"readdir Bundle/Application items=%lu jbroot=%d",(unsigned long)items.count,jb);
        L(@"canOpenURL sileo=%d filza=%d", [[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"sileo://"]], [[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"filza://"]]);
        L(@"NSFileManager /var/jb=%d TweakInject=%d", [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"], [[NSFileManager defaultManager] fileExistsAtPath:@"/usr/lib/TweakInject"]);
        [R writeToFile:[docs stringByAppendingPathComponent:@"jbb9_report.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}
