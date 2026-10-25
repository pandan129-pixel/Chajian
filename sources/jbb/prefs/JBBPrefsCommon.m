#import "JBBPrefsCommon.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <os/log.h>

#include <signal.h>

/* libproc is not in the iOS SDK; declare the two calls we need. */
#define PROC_ALL_PIDS 1
#define PROC_PIDPATHINFO_MAXSIZE (4 * 1024)
extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
#include <sys/sysctl.h>

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSString *localizedShortName;
@property (nonatomic, readonly) NSString *bundleIdentifier;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end

NSString *JBBAppName(NSString *bundleID) {
    LSApplicationProxy *p = [LSApplicationProxy applicationProxyForIdentifier:bundleID];
    NSString *name = p.localizedShortName;
    return name.length ? name : bundleID;
}

/* ------------------------------------------------------------------ *
 * Config storage: file + cfprefsd.
 *
 * The file at /var/mobile/Library/Preferences is what Settings and host
 * tools read, but a sandboxed App cannot always read it. cfprefsd is
 * shared per-user, so the tweak reads the config through it. Keep both in
 * sync: write both here, and on load publish the file into cfprefsd so a
 * config created by an older version becomes visible to sandboxed Apps.
 * ------------------------------------------------------------------ */

static CFStringRef JBBPrefsAppID(void) { return CFSTR("com.pandan.jbb"); }

static NSMutableDictionary *JBBPrefsFromCFPrefs(void) {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionary];
    CFStringRef appID = JBBPrefsAppID();
    for (NSString *key in @[@"globalEnabled", @"globalExtraTokens", @"profiles"]) {
        CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, appID);
        if (v) {
            prefs[key] = (__bridge id)v;
            CFRelease(v);
        }
    }
    return prefs;
}

NSMutableDictionary *JBBLoadPrefs(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kJBBPrefsPath];
    if (![d isKindOfClass:[NSDictionary class]]) {
        /* migrate from the old path (also the cfprefsd-managed one) */
        d = [NSDictionary dictionaryWithContentsOfFile:kJBBLegacyPrefsPath];
        if ([d isKindOfClass:[NSDictionary class]]) {
            [d writeToFile:kJBBPrefsPath atomically:YES];
        }
    }
    NSMutableDictionary *prefs = d ? [d mutableCopy] : [NSMutableDictionary dictionary];
    if (prefs.count == 0) {
        /* Recover from cfprefsd (e.g. plist was removed but the daemon still has it) */
        prefs = JBBPrefsFromCFPrefs();
    }
    return prefs ?: [NSMutableDictionary dictionary];
}

void JBBSavePrefs(NSMutableDictionary *prefs) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:prefs
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:nil];
    [data writeToFile:kJBBPrefsPath atomically:YES];
}

NSMutableDictionary *JBBProfile(NSMutableDictionary *prefs, NSString *bundleID, BOOL create) {
    NSMutableDictionary *profiles = prefs[kJBBProfilesKey];
    if (![profiles isKindOfClass:[NSMutableDictionary class]]) {
        if (!create) return nil;
        profiles = [NSMutableDictionary dictionary];
        prefs[kJBBProfilesKey] = profiles;
    }
    NSMutableDictionary *p = profiles[bundleID];
    if (![p isKindOfClass:[NSMutableDictionary class]]) {
        if (!create) return nil;
        p = [NSMutableDictionary dictionary];
        profiles[bundleID] = p;
    }
    return p;
}

/* ------------------------------------------------------------------ *
 * Tweak discovery (Choicy-compatible)
 *
 * Choicy matches a tweak filter against a process by:
 *   1. Filter.Bundles      -> bundle identifier
 *   2. Filter.Executables  -> executable file name
 *   3. Filter.Classes      -> treat as com.apple.Security
 * We do the same, but resolve everything to bundle identifiers so the
 * Settings UI can list real apps.
 *
 * Settings is sandboxed: it cannot read /var/jb or TweakInject. The deb
 * postinst copies every filter plist into JBBPrefs.bundle/filters/, which
 * the bundle can always read. Reads go through NSDictionary, so binary
 * plists (most tweaks) work too - a plain shell grep only saw XML ones,
 * which is why WeChat / Xianyu / Douyin were missing.
 * ------------------------------------------------------------------ */

static NSUInteger gJBBFilterCount = 0;
static NSUInteger gJBBFilterFailed = 0;

NSUInteger JBBTweakFilterCount(void) { return gJBBFilterCount; }
NSUInteger JBBTweakFilterFailedCount(void) { return gJBBFilterFailed; }

static BOOL JBBCheckLaunchServices(void);

/* ------------------------------------------------------------------ *
 * Installed app list written by the deb postinst.
 *
 * The postinst runs "jbb-installed -" (a root, unsandboxed helper shipped
 * in the deb) and stores "bundleID|execName" lines in JBBPrefs.bundle and in
 * /var/mobile/Library/Preferences. This avoids depending on LaunchServices,
 * which is not available inside the Settings process.
 * ------------------------------------------------------------------ */
/* Some tweaks ship old-style (OpenStep) filter plists - NSDictionary handles
 * them on macOS/iOS via CoreFoundation, but NSPropertyListSerialization is the
 * documented entry point, so try it first and fall back. */
static NSDictionary *JBBReadPlist(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length) {
        id plist = [NSPropertyListSerialization propertyListWithData:data
                                                             options:0
                                                              format:NULL
                                                               error:NULL];
        if ([plist isKindOfClass:[NSDictionary class]]) return plist;
    }
    id d = [NSDictionary dictionaryWithContentsOfFile:path];
    return [d isKindOfClass:[NSDictionary class]] ? d : nil;
}

static NSDictionary *JBBInstalledFileMap(void) {
    static NSDictionary *cached;
    static BOOL done = NO;
    if (done) return cached;
    done = YES;

    NSMutableArray *candidates = [NSMutableArray array];
    Class rootClass = NSClassFromString(@"JBBRootListController");
    if (rootClass) {
        NSString *p = [[[NSBundle bundleForClass:rootClass] bundlePath]
                       stringByAppendingPathComponent:@"jbb-installed.txt"];
        if (p) [candidates addObject:p];
    }
    [candidates addObject:@"/var/mobile/Library/Preferences/jbb-installed.txt"];

    for (NSString *p in candidates) {
        NSString *text = [NSString stringWithContentsOfFile:p
                                                   encoding:NSUTF8StringEncoding error:nil];
        if (!text.length) continue;
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            NSArray *parts = [line componentsSeparatedByString:@"|"];
            if (!parts.count) continue;
            NSString *bid = parts[0];
            if (!bid.length) continue;
            m[bid] = parts.count > 1 ? parts[1] : @"";
        }
        if (m.count) { cached = m; break; }
    }
    return cached;
}

/* executable name (lowercase) -> bundle identifier, for Filter.Executables */
static NSDictionary *JBBInstalledExecutables(void) {
    static NSDictionary *cached;
    static BOOL built = NO;
    if (built) return cached;
    built = YES;

    NSDictionary *fileMap = JBBInstalledFileMap();
    if (fileMap.count) {
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (NSString *bid in fileMap) {
            NSString *exe = fileMap[bid];
            if ([exe isKindOfClass:[NSString class]] && exe.length) m[exe.lowercaseString] = bid;
        }
        cached = m;
        return cached;
    }

    if (!JBBCheckLaunchServices()) return nil;

    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
    for (LSApplicationProxy *p in [ws allInstalledApplications]) {
        NSString *bid = p.bundleIdentifier;
        if (!bid.length) continue;

        NSString *exe = nil;
        @try {
            if ([p respondsToSelector:NSSelectorFromString(@"bundleExecutableName")]) {
                id v = [p valueForKey:@"bundleExecutableName"];
                if ([v isKindOfClass:[NSString class]]) exe = v;
            }
            if (!exe.length && [p respondsToSelector:NSSelectorFromString(@"executableURL")]) {
                id v = [p valueForKey:@"executableURL"];
                if ([v isKindOfClass:[NSURL class]]) exe = [(NSURL *)v lastPathComponent];
            }
        } @catch (__unused NSException *e) {}

        if (exe.length) m[exe.lowercaseString] = bid;
    }
    cached = m;
    return cached;
}

/* Settings does not link LaunchServices, so LSApplicationWorkspace is not
 * registered in its process and every lookup silently returns nil. Choicy gets
 * around this with PRIVATE_FRAMEWORKS = MobileCoreServices; we dlopen it so the
 * class shows up without touching the bundle's load commands. */
static BOOL JBBCheckLaunchServices(void) {
    static int state = -1;          /* -1 unknown, 0 unavailable, 1 available */
    if (state >= 0) return state == 1;

    if (NSClassFromString(@"LSApplicationWorkspace")) {
        state = 1;
        return YES;
    }

    const char *paths[] = {
        "/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices",
        "/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
        "/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices",
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        if (dlopen(paths[i], RTLD_NOW | RTLD_GLOBAL)) break;
    }

    state = NSClassFromString(@"LSApplicationWorkspace") ? 1 : 0;
    os_log_with_type(os_log_create("com.pandan.jbb.prefs", "ls"),
                     OS_LOG_TYPE_DEFAULT, "LaunchServices available=%d", state);
    return state == 1;
}

NSInteger JBBInstalledAppCount(void) {
    NSDictionary *fileMap = JBBInstalledFileMap();
    if (fileMap.count) return (NSInteger)fileMap.count;
    if (!JBBCheckLaunchServices()) return -1;
    return (NSInteger)[[[LSApplicationWorkspace defaultWorkspace] allInstalledApplications] count];
}

BOOL JBBAppIsInstalled(NSString *bundleID) {
    if (!bundleID.length) return NO;

    NSDictionary *fileMap = JBBInstalledFileMap();
    if (fileMap.count) return fileMap[bundleID] != nil;

    /* Cannot ask LaunchServices -> do not hide anything. */
    if (!JBBCheckLaunchServices()) return YES;

    return [LSApplicationProxy applicationProxyForIdentifier:bundleID] != nil;
}

/* Every directory that may hold a copy of the filter plists. */
static NSArray<NSString *> *JBBFilterRoots(void) {
    NSMutableArray *roots = [NSMutableArray array];

    /* Off-device testing hook: JBB_FILTERS_DIR=/path/to/filters */
    const char *env = getenv("JBB_FILTERS_DIR");
    if (env) [roots addObject:[NSString stringWithUTF8String:env]];

    Class rootClass = NSClassFromString(@"JBBRootListController");
    if (rootClass) {
        NSBundle *b = [NSBundle bundleForClass:rootClass];
        NSString *p = b.bundlePath;
        if (p.length) [roots addObject:[p stringByAppendingPathComponent:@"filters"]];
        NSString *r = [b pathForResource:@"filters" ofType:nil];
        if (r.length && ![roots containsObject:r]) [roots addObject:r];
    }

    /* Last resort for a non-sandboxed caller (e.g. a root helper). */
    [roots addObject:@"/var/mobile/Library/Preferences/jbb-filters"];
    [roots addObject:@"/var/jb/Library/PreferenceBundles/JBBPrefs.bundle/filters"];
    [roots addObject:@"/Library/PreferenceBundles/JBBPrefs.bundle/filters"];
    return roots;
}

static void JBBAddTweak(NSMutableDictionary *map, NSString *bundleID, NSString *tweak) {
    if (!bundleID.length || !tweak.length) return;
    /* System apps / daemons are not interesting here (Choicy hides them too). */
    if ([bundleID hasPrefix:@"com.apple."]) return;
    NSMutableArray *arr = map[bundleID];
    if (!arr) { arr = [NSMutableArray array]; map[bundleID] = arr; }
    if (![arr containsObject:tweak]) [arr addObject:tweak];
}

NSDictionary *JBBTweakMap(void) {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    gJBBFilterCount = 0;
    gJBBFilterFailed = 0;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableSet *seen = [NSMutableSet set];
    NSDictionary *executables = JBBInstalledExecutables();

    for (NSString *root in JBBFilterRoots()) {
        for (NSString *sub in @[@"TweakInject", @"MobileSubstrate"]) {
            NSString *dir = [root stringByAppendingPathComponent:sub];
            if (![fm fileExistsAtPath:dir]) continue;

            for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
                if (![f hasSuffix:@".plist"]) continue;
                if ([seen containsObject:f]) continue;

                NSString *tweak = [f stringByDeletingPathExtension];
                if ([tweak isEqualToString:@"jbb"] || [tweak hasPrefix:@"jbb-"]) continue;

                NSDictionary *d = JBBReadPlist([dir stringByAppendingPathComponent:f]);
                if (![d isKindOfClass:[NSDictionary class]]) {
                    gJBBFilterFailed++;
                    continue;
                }
                NSDictionary *filter = d[@"Filter"];
                if (![filter isKindOfClass:[NSDictionary class]]) continue;

                gJBBFilterCount++;
                [seen addObject:f];

                id bundles = filter[@"Bundles"];
                if ([bundles isKindOfClass:[NSArray class]]) {
                    for (id b in bundles) {
                        if (![b isKindOfClass:[NSString class]]) continue;
                        if ([b hasPrefix:@"com.apple."]) continue;   /* system apps */
                        JBBAddTweak(map, b, tweak);
                    }
                }

                id execs = filter[@"Executables"];
                if ([execs isKindOfClass:[NSArray class]]) {
                    for (id e in execs) {
                        if (![e isKindOfClass:[NSString class]]) continue;
                        NSString *bid = executables[((NSString *)e).lowercaseString];
                        if (bid.length) JBBAddTweak(map, bid, tweak);
                    }
                }

                /* Choicy treats a class filter as a Security tweak. */
                id classes = filter[@"Classes"];
                if ([classes isKindOfClass:[NSArray class]] && [classes count]) {
                    JBBAddTweak(map, @"com.apple.Security", tweak);
                }
            }
        }
        if (map.count) break;   /* first readable copy wins */
    }

    /* If the bundle copy disappeared (e.g. tools/ dir wiped), fall back to
     * the text cache written by older versions so the list is never empty. */
    if (map.count == 0) {
        NSString *text = [NSString stringWithContentsOfFile:
                          @"/var/mobile/Library/Preferences/com.pandan.jbb.tweaks.txt"
                                                  encoding:NSUTF8StringEncoding error:nil];
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            NSRange sep = [line rangeOfString:@"|"];
            if (sep.location == NSNotFound) continue;
            NSString *bid = [line substringToIndex:sep.location];
            NSString *tweaks = [line substringFromIndex:sep.location + 1];
            if (!bid.length) continue;
            for (NSString *one in [tweaks componentsSeparatedByString:@","])
                JBBAddTweak(map, bid, one);
        }
    }

    os_log_with_type(os_log_create("com.pandan.jbb.prefs", "scan"), OS_LOG_TYPE_DEFAULT,
                     "filters=%lu failed=%lu apps=%lu installed=%ld",
                     (unsigned long)gJBBFilterCount, (unsigned long)gJBBFilterFailed,
                     (unsigned long)map.count, (long)JBBInstalledAppCount());

    return map;
}

NSArray *JBBAppsWithTweaks(void) {
    NSDictionary *map = JBBTweakMap();
    return [[map allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        BOOL ia = JBBAppIsInstalled(a), ib = JBBAppIsInstalled(b);
        if (ia != ib) return ia ? NSOrderedAscending : NSOrderedDescending;
        return [JBBAppName(a) localizedCaseInsensitiveCompare:JBBAppName(b)];
    }];
}

/* jbbd republishes on a 3 s loop; waiting 4 s is enough for the new config to
 * land in the app container. Polling a status file turned out to be unreliable
 * on roothide (the daemon and Settings see different /var/mobile namespaces). */
void JBBWaitForDaemonPublish(time_t since, NSTimeInterval timeout) {
    (void)since; (void)timeout;
    sleep(4);
}

pid_t JBBFindPid(NSString *bundleID) {
    int count = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (count <= 0) return -1;
    pid_t *pids = malloc(sizeof(pid_t) * count);
    count = proc_listpids(PROC_ALL_PIDS, 0, pids, sizeof(pid_t) * count);
    pid_t found = -1;
    for (int i = 0; i < count; i++) {
        if (pids[i] <= 1) continue;
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pids[i], path, sizeof(path)) <= 0) continue;
        NSString *p = [NSString stringWithUTF8String:path];
        NSArray *comps = [p pathComponents];
        for (NSUInteger c = 0; c + 1 < comps.count; c++) {
            if ([comps[c] hasSuffix:@".app"]) {
                NSString *plist = [[p stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Info.plist"];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
                if ([info[@"CFBundleIdentifier"] isEqualToString:bundleID]) found = pids[i];
                break;
            }
        }
        if (found > 0) break;
    }
    free(pids);
    return found;
}
