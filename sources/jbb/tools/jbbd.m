/* jbbd - root helper that publishes the Settings config into each app's
 * container. A sandboxed app can only read its own container, so this is the
 * only way to make per-app settings actually reach the tweak.
 *
 * IMPORTANT: LaunchDaemons run under a 6 MB jetsam limit on iOS. Keep the
 * working set tiny: cache the container map, wrap every app write in its own
 * autorelease pool, and only republish when the config actually changed. */
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <unistd.h>

#define PREFS     @"/var/mobile/Library/Preferences/com.pandan.jbb.cfg.plist"
#define PREFS_OLD @"/var/mobile/Library/Preferences/com.pandan.jbb.plist"

static NSString *JBRoot(void) {
    static NSString *root = nil;
    if (root) return root;
    NSString *exe = [[NSBundle mainBundle] executablePath] ?: @"/var/jb/usr/lib/jbb/jbbd";
    NSRange r = [exe rangeOfString:@"/usr/lib/jbb/"];
    root = r.location != NSNotFound ? [exe substringToIndex:r.location] : @"/var/jb";
    return root;
}

static NSDictionary *ReadDict(NSString *p) {
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (!d.length) return nil;
    id o = [NSPropertyListSerialization propertyListWithData:d options:0 format:NULL error:NULL];
    return [o isKindOfClass:[NSDictionary class]] ? o : nil;
}

/* bundle id -> data container path, cached (enumeration is the expensive part). */
static NSDictionary *Containers(BOOL refresh) {
    static NSDictionary *cached = nil;
    static time_t built = 0;
    if (!refresh && cached && time(NULL) - built < 300) return cached;

    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    NSString *root = @"/var/mobile/Containers/Data/Application";
    for (NSString *uuid in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil]) {
        @autoreleasepool {
            NSString *dir = [root stringByAppendingPathComponent:uuid];
            NSDictionary *meta = ReadDict([dir stringByAppendingPathComponent:
                                           @".com.apple.mobile_container_manager.metadata.plist"]);
            NSString *bid = meta[@"MCMMetadataIdentifier"];
            if ([bid isKindOfClass:[NSString class]] && bid.length) m[bid] = dir;
        }
    }
    cached = m;
    built = time(NULL);
    return cached;
}

static NSSet *InjectedApps(void) {
    NSDictionary *f = ReadDict([JBRoot() stringByAppendingPathComponent:@"usr/lib/TweakInject/jbb.plist"]);
    NSArray *bundles = f[@"Filter"][@"Bundles"];
    return [bundles isKindOfClass:[NSArray class]] ? [NSSet setWithArray:bundles] : nil;
}

static void WriteStatus(void) {
    char buf[64];
    snprintf(buf, sizeof(buf), "ts=%ld\n", (long)time(NULL));
    NSString *sp = [JBRoot() stringByAppendingPathComponent:
                    @"Library/PreferenceBundles/JBBPrefs.bundle/jbbd.status"];
    FILE *f = fopen(sp.fileSystemRepresentation, "w");
    if (f) { fputs(buf, f); fclose(f); chmod(sp.fileSystemRepresentation, 0644); }
}

static void Publish(BOOL refreshContainers) {
    @autoreleasepool {
        NSDictionary *prefs = ReadDict(PREFS) ?: ReadDict(PREFS_OLD);
        if (!prefs) return;
        NSSet *injected = InjectedApps();
        if (!injected.count) return;

        NSDictionary *profiles = prefs[@"profiles"];
        if (![profiles isKindOfClass:[NSDictionary class]]) profiles = @{};
        NSNumber *gEnabled = prefs[@"globalEnabled"];
        NSNumber *gExtra = prefs[@"globalExtraTokens"];

        NSDictionary *containers = Containers(refreshContainers);
        for (NSString *bid in containers) {
            if (![injected containsObject:bid]) continue;
            @autoreleasepool {
                NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithCapacity:3];
                if (gEnabled) cfg[@"globalEnabled"] = gEnabled;
                if (gExtra) cfg[@"globalExtraTokens"] = gExtra;
                id p = profiles[bid];
                cfg[@"profiles"] = [p isKindOfClass:[NSDictionary class]] ? @{ bid: p } : @{};

                NSString *dir = [[containers[bid] stringByAppendingPathComponent:@"Documents"]
                                 stringByAppendingPathComponent:@"jbb"];
                NSData *data = [NSPropertyListSerialization dataWithPropertyList:cfg
                                                                          format:NSPropertyListBinaryFormat_v1_0
                                                                         options:0 error:NULL];
                if (!data) continue;
                NSString *path = [dir stringByAppendingPathComponent:@"config.plist"];
                if (![data writeToFile:path atomically:YES]) {
                    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                              withIntermediateDirectories:YES attributes:nil error:NULL];
                    [data writeToFile:path atomically:YES];
                }
                chown(path.fileSystemRepresentation, 501, 501);
                chmod(path.fileSystemRepresentation, 0644);
            }
        }
        WriteStatus();
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && !strcmp(argv[1], "--once")) { Publish(YES); return 0; }

        struct stat st;
        time_t lastMtime = 0, lastSize = 0, lastPublish = 0;
        Publish(YES);
        lastPublish = time(NULL);
        while (1) {
            sleep(3);
            @autoreleasepool {
                BOOL changed = NO;
                if (stat(PREFS.fileSystemRepresentation, &st) == 0 &&
                    (st.st_mtime != lastMtime || st.st_size != lastSize)) {
                    lastMtime = st.st_mtime; lastSize = st.st_size; changed = YES;
                }
                /* Only do the 84-app rewrite when the config changed, plus a
                 * 5-minute heartbeat to pick up newly installed apps. */
                if (changed || time(NULL) - lastPublish >= 300) {
                    Publish(changed);
                    lastPublish = time(NULL);
                }
            }
        }
    }
    return 0;
}
