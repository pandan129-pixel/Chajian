/* jbbd - root helper that publishes the Settings config into each app's
 * container. A sandboxed app can only read its own container, so this is the
 * only way to make per-app settings actually reach the tweak.
 *
 * Runs as a LaunchDaemon, re-reads the config when its mtime changes, and
 * writes <container>/Documents/jbb-config.plist for every app that jbb injects
 * into (read from TweakInject/jbb.plist). */
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <unistd.h>

#define PREFS   @"/var/mobile/Library/Preferences/com.pandan.jbb.cfg.plist"
#define PREFS_OLD @"/var/mobile/Library/Preferences/com.pandan.jbb.plist"
#define LOGPATH @"/var/mobile/Library/Preferences/jbbd.log"
static NSString *JBRoot(void);

static NSString *StatusPath(void) {
    return [JBRoot() stringByAppendingPathComponent:@"Library/PreferenceBundles/JBBPrefs.bundle/jbbd.status"];
}

static NSString *gFilterPath = nil;
static NSString *JBRoot(void) {
    if (gFilterPath) return gFilterPath;
    NSString *exe = [[NSBundle mainBundle] executablePath] ?: @"/var/jb/usr/lib/jbb/jbbd";
    NSRange r = [exe rangeOfString:@"/usr/lib/jbb/"];
    NSString *root = r.location != NSNotFound ? [exe substringToIndex:r.location] : @"/var/jb";
    gFilterPath = [root stringByAppendingPathComponent:@"usr/lib/TweakInject/jbb.plist"];
    return gFilterPath;
}

static void Log(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    NSString *line = [s stringByAppendingString:@"\n"];
    FILE *f = fopen(LOGPATH.fileSystemRepresentation, "a");
    if (f) { fputs(line.UTF8String, f); fclose(f); }
}

static NSDictionary *ReadDict(NSString *p) {
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (!d.length) return nil;
    id o = [NSPropertyListSerialization propertyListWithData:d options:0 format:NULL error:NULL];
    return [o isKindOfClass:[NSDictionary class]] ? o : nil;
}

/* bundle id -> data container path */
static NSDictionary *Containers(void) {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    NSString *root = @"/var/mobile/Containers/Data/Application";
    for (NSString *uuid in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil]) {
        NSString *dir = [root stringByAppendingPathComponent:uuid];
        NSDictionary *meta = ReadDict([dir stringByAppendingPathComponent:
                                       @".com.apple.mobile_container_manager.metadata.plist"]);
        NSString *bid = meta[@"MCMMetadataIdentifier"];
        if ([bid isKindOfClass:[NSString class]] && bid.length) m[bid] = dir;
    }
    return m;
}

static NSSet *InjectedApps(void) {
    NSDictionary *f = ReadDict(JBRoot());
    NSArray *bundles = f[@"Filter"][@"Bundles"];
    return [bundles isKindOfClass:[NSArray class]] ? [NSSet setWithArray:bundles] : nil;
}

static void Publish(void) {
    NSDictionary *prefs = ReadDict(PREFS) ?: ReadDict(PREFS_OLD);
    if (!prefs) { Log(@"prefs unreadable"); return; }
    NSSet *injected = InjectedApps();
    if (!injected.count) { Log(@"filter unreadable: %@", JBRoot()); return; }
    Log(@"publish: injected=%lu prefs=%lu", (unsigned long)injected.count, (unsigned long)prefs.count);

    NSDictionary *profiles = prefs[@"profiles"];
    if (![profiles isKindOfClass:[NSDictionary class]]) profiles = @{};

    NSDictionary *containers = Containers();
    Log(@"containers=%lu", (unsigned long)containers.count);
    int written = 0;
    for (NSString *bid in containers) {
        if (![injected containsObject:bid]) continue;
        NSMutableDictionary *cfg = [NSMutableDictionary dictionary];
        if (prefs[@"globalEnabled"]) cfg[@"globalEnabled"] = prefs[@"globalEnabled"];
        if (prefs[@"globalExtraTokens"]) cfg[@"globalExtraTokens"] = prefs[@"globalExtraTokens"];
        id p = profiles[bid];
        cfg[@"profiles"] = [p isKindOfClass:[NSDictionary class]] ? @{ bid: p } : @{};

        NSString *dir = [[containers[bid] stringByAppendingPathComponent:@"Documents"]
                         stringByAppendingPathComponent:@"jbb"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *path = [dir stringByAppendingPathComponent:@"config.plist"];
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:cfg
                                                                 format:NSPropertyListXMLFormat_v1_0
                                                                options:0 error:NULL];
        [data writeToFile:path atomically:YES];
        chown(path.fileSystemRepresentation, 501, 501);
        chmod(path.fileSystemRepresentation, 0644);
        written++;
    }

    /* Stamp completion so Settings can wait for the publish before restarting
     * the app. Lives in the prefs bundle because Settings can always read it. */
    char buf[64];
    snprintf(buf, sizeof(buf), "ts=%ld\n", (long)time(NULL));
    NSString *sp = StatusPath();
    FILE *sf = fopen(sp.fileSystemRepresentation, "w");
    if (sf) { fputs(buf, sf); fclose(sf); chmod(sp.fileSystemRepresentation, 0644); }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && !strcmp(argv[1], "--once")) { Publish(); return 0; }
        /* Republish unconditionally: the config file is tiny and this avoids
         * mtime/namespace edge cases on roothide. */
        while (1) {
            Publish();
            sleep(3);
        }
    }
    return 0;
}
