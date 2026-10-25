/* Enumerate installed apps and write "bundleID|execName" lines.
 * Meant to be run as root from the deb postinst, from inside the jbroot
 * (adhoc binaries outside the jbroot get SIGKILLed by AMFI on iOS 17). */
#import <Foundation/Foundation.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *outPath = argc > 1 ? [NSString stringWithUTF8String:argv[1]]
                                     : @"/var/mobile/Library/Preferences/jbb-installed.txt";
        NSMutableArray *lines = [NSMutableArray array];
        NSFileManager *fm = [NSFileManager defaultManager];

        NSArray *roots = @[@"/var/containers/Bundle/Application",
                           @"/Applications",
                           @"/var/jb/Applications"];
        for (NSString *root in roots) {
            for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:nil]) {
                NSString *dir = [root stringByAppendingPathComponent:uuid];
                NSArray *children = [fm contentsOfDirectoryAtPath:dir error:nil];
                BOOL nested = (children.count > 0);
                for (NSString *child in (nested ? children : @[uuid])) {
                    if (![child hasSuffix:@".app"]) continue;
                    NSString *appDir = nested ? [dir stringByAppendingPathComponent:child] : dir;
                    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                          [appDir stringByAppendingPathComponent:@"Info.plist"]];
                    NSString *bid = info[@"CFBundleIdentifier"];
                    NSString *exe = info[@"CFBundleExecutable"];
                    if (![bid isKindOfClass:[NSString class]] || !bid.length) continue;
                    if ([bid hasPrefix:@"com.apple."]) continue;
                    [lines addObject:[NSString stringWithFormat:@"%@|%@", bid, exe ?: @""]];
                }
            }
        }

        NSArray *sorted = [[NSSet setWithArray:lines] allObjects];
        NSString *text = [[sorted componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];

        /* "-" means stdout: roothide runs jbroot binaries in a namespace where
         * writes outside the jbroot do not show up for the host, but stdout is
         * fine. The postinst (a host process) does the redirection. */
        if ([outPath isEqualToString:@"-"]) {
            fputs(text.UTF8String, stdout);
            fflush(stdout);
        } else {
            [text writeToFile:outPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        fprintf(stderr, "apps=%lu\n", (unsigned long)sorted.count);
    }
    return 0;
}
