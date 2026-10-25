#import <Foundation/Foundation.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        NSArray *dirs = @[
            @"/var/jb/usr/lib/TweakInject", @"/usr/lib/TweakInject",
            @"/var/jb/Library/MobileSubstrate/DynamicLibraries",
            @"/Library/MobileSubstrate/DynamicLibraries"
        ];
        NSFileManager *fm = [NSFileManager defaultManager];

        for (NSString *dir in dirs) {
            NSError *de = nil;
            NSArray *files = [fm contentsOfDirectoryAtPath:dir error:&de];
            fprintf(stderr, "DIR %s count=%lu err=%s\n", dir.UTF8String, (unsigned long)files.count, de.localizedDescription.UTF8String ?: "-");
            for (NSString *f in files) {
                if (![f hasSuffix:@".plist"]) continue;
                NSString *name = [f stringByDeletingPathExtension];
                if ([name isEqualToString:@"jbb"] || [name hasPrefix:@"jbb-"]) continue;

                NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:f]];
                id bundles = d[@"Filter"][@"Bundles"];
                if (![bundles isKindOfClass:[NSArray class]]) continue;

                for (id b in bundles) {
                    if (![b isKindOfClass:[NSString class]] || [b hasPrefix:@"com.apple."]) continue;
                    NSMutableArray *arr = map[b];
                    if (!arr) { arr = [NSMutableArray array]; map[b] = arr; }
                    if (![arr containsObject:name]) [arr addObject:name];
                }
            }
        }

        NSMutableString *out = [NSMutableString string];
        for (NSString *b in [[map allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            [out appendFormat:@"%@|%@\n", b, [map[b] componentsJoinedByString:@","]];
        }

        NSString *path = argc > 1 ? [NSString stringWithUTF8String:argv[1]]
                                  : @"/var/mobile/Library/Preferences/com.pandan.jbb.tweaks.txt";
        NSError *we = nil;
        BOOL ok = [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&we];
        fprintf(stderr, "WRITE %s ok=%d err=%s\n", path.UTF8String, ok, we.localizedDescription.UTF8String ?: "-");
        printf("%s: %lu apps\n", path.UTF8String, (unsigned long)map.count);
    }
    return 0;
}
