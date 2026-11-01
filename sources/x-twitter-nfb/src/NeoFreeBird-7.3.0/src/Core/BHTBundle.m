//
//  BHTBundle.m
//  NeoFreeBird
//
//  Created by BandarHelal on 07/08/2022.
//

#import "BHTBundle.h"
#import <dlfcn.h>

// The resource bundle lives in a different place per bootstrap:
//   rootful   /Library/Application Support/BHT/BHTwitter.bundle
//   rootless  /var/jb/Library/Application Support/BHT/BHTwitter.bundle
//   roothide  <randomized jbroot>/Library/Application Support/BHT/BHTwitter.bundle
// Resolving from the dylib's own location covers all three (and the sideloaded
// X.app/Frameworks layout), instead of relying on hardcoded absolute paths.
static NSString* BHTResolveBundlePath(void) {
    NSFileManager* fm = [NSFileManager defaultManager];
    Dl_info info;
    if (dladdr((void*)BHTResolveBundlePath, &info) && info.dli_fname) {
        NSString* d = [[NSString stringWithUTF8String:info.dli_fname]
                       stringByDeletingLastPathComponent];
        for (int i = 0; i < 6 && d.length > 1; i++) {
            NSString* p = [[d stringByAppendingPathComponent:@"BHTwitter.bundle"]
                           stringByStandardizingPath];
            if ([fm fileExistsAtPath:p]) {
                return p;
            }
            p = [[d stringByAppendingPathComponent:
                  @"Library/Application Support/BHT/BHTwitter.bundle"]
                 stringByStandardizingPath];
            if ([fm fileExistsAtPath:p]) {
                return p;
            }
            d = [d stringByDeletingLastPathComponent];
        }
    }
    for (NSString* p in @[
             @"/Library/Application Support/BHT/BHTwitter.bundle",
             @"/var/jb/Library/Application Support/BHT/BHTwitter.bundle"]) {
        if ([fm fileExistsAtPath:p]) {
            return p;
        }
    }
    return [[NSBundle mainBundle] URLForResource:@"BHTwitter"
                                   withExtension:@"bundle"].path;
}

@interface BHTBundle ()
@property (nonatomic, strong) NSBundle* mainBundle;
@end

@implementation BHTBundle
+ (instancetype)sharedBundle {
    static BHTBundle* sharedBundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString* path = BHTResolveBundlePath();
        NSURL* bundlePath = path ? [NSURL fileURLWithPath:path] : nil;
        sharedBundle = [[self alloc] initWithBundlePath:bundlePath];
    });
    return sharedBundle;
}
- (instancetype)initWithBundlePath:(NSURL*)bundlePath {
    if (self = [super init]) {
        self.mainBundle = [NSBundle bundleWithPath:[bundlePath path]];
    }

    return self;
}

- (NSString*)localizedStringForKey:(NSString*)key {
    return [self.mainBundle localizedStringForKey:key value:key table:nil];
}

// Fetches one of Twitter's own strings, reusing the app's translations for
// every language. These flow through the terminology rename hook like any app
// string.
- (NSString*)localizedTwitterStringForKey:(NSString*)key {
    static NSBundle* twitterBundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString* path =
            [[NSBundle mainBundle] pathForResource:@"Localization_Localization"
                                            ofType:@"bundle"];
        twitterBundle =
            path ? [NSBundle bundleWithPath:path] : [NSBundle mainBundle];
    });
    return [twitterBundle localizedStringForKey:key value:key table:nil];
}
- (NSURL*)pathForFile:(NSString*)fileName {
    return [self.mainBundle URLForResource:fileName withExtension:nil];
}
@end
