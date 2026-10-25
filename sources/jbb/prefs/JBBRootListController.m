#import <Preferences/PSSpecifier.h>
#import "JBBRootListController.h"
#import "JBBPrefsCommon.h"
#import "JBBAppSettingsController.h"
#import "JBBAppPickerController.h"
#import "JBBTweakAppsController.h"

@interface JBBRootListController ()
- (PSSpecifier *)rowFor:(NSString *)bid;
@end

@implementation JBBRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        NSMutableDictionary *prefs = JBBLoadPrefs();

        PSSpecifier *g = [PSSpecifier groupSpecifierWithName:@"全局"];
        [g setProperty:@"默认对所有 App 生效。只有下面单独添加过的 App 才会用它的配置覆盖默认值。" forKey:@"footerText"];
        [specs addObject:g];

        PSSpecifier *master = [PSSpecifier preferenceSpecifierNamed:@"启用 JBB"
                                                             target:self set:@selector(setGlobal:spec:) get:@selector(getGlobal:)
                                                              detail:nil cell:PSSwitchCell edit:nil];
        [master setProperty:@"globalEnabled" forKey:@"key"];
        [master setProperty:@YES forKey:@"default"];
        [specs addObject:master];

        PSSpecifier *extra = [PSSpecifier preferenceSpecifierNamed:@"额外 token（Cydia/apt/cycript 等）"
                                                            target:self set:@selector(setExtra:spec:) get:@selector(getExtra:)
                                                             detail:nil cell:PSSwitchCell edit:nil];
        [extra setProperty:@YES forKey:@"default"];
        [specs addObject:extra];

        PSSpecifier *tweakGroup = [PSSpecifier groupSpecifierWithName:@"插件"];
        [tweakGroup setProperty:@"列出装了插件的 App，方便先处理冲突。" forKey:@"footerText"];
        [specs addObject:tweakGroup];
        NSUInteger tweakAppCount = 0;
        for (NSString *bid in JBBTweakMap().allKeys) {
            if (JBBAppIsInstalled(bid)) tweakAppCount++;
        }
        PSSpecifier *tweakRow = [PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:@"有插件的 App（%lu）", (unsigned long)tweakAppCount]
                                                               target:self set:nil get:nil
                                                                detail:[JBBTweakAppsController class] cell:PSLinkCell edit:nil];
        [specs addObject:tweakRow];

        PSSpecifier *appGroup = [PSSpecifier groupSpecifierWithName:@"按 App 配置（可选）"];
        [appGroup setProperty:@"没有添加的 App 全部用默认值。添加某个 App 后，可以单独关掉它敏感的 hook（例如 QQ 要关 ObjC）。" forKey:@"footerText"];
        [specs addObject:appGroup];

        NSDictionary *profiles = prefs[kJBBProfilesKey];
        NSArray *keys = [[profiles allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return [JBBAppName(a) localizedCaseInsensitiveCompare:JBBAppName(b)];
        }];
        if (keys.count == 0) {
            [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"（还没有配置，点下面添加）"
                                                            target:nil set:nil get:nil detail:nil
                                                              cell:PSStaticTextCell edit:nil]];
        } else {
            for (NSString *bid in keys) [specs addObject:[self rowFor:bid]];
        }

        [specs addObject:[PSSpecifier groupSpecifierWithName:@""]];
        PSSpecifier *add = [PSSpecifier preferenceSpecifierNamed:@"添加 App 覆盖默认设置…"
                                                          target:self set:nil get:nil
                                                           detail:[JBBAppPickerController class] cell:PSLinkCell edit:nil];
        [specs addObject:add];

        _specifiers = specs;
    }
    return _specifiers;
}

- (PSSpecifier *)rowFor:(NSString *)bid {
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:JBBAppName(bid)
                                                      target:self set:nil get:nil
                                                       detail:[JBBAppSettingsController class]
                                                        cell:PSLinkCell edit:nil];
    [row setProperty:bid forKey:@"jbbBundleID"];
    return row;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (id)getGlobal:(PSSpecifier *)spec {
    NSNumber *v = JBBLoadPrefs()[@"globalEnabled"];
    return v ?: @YES;
}
- (void)setGlobal:(id)value spec:(PSSpecifier *)spec {
    NSMutableDictionary *p = JBBLoadPrefs();
    p[@"globalEnabled"] = @([value boolValue]);
    JBBSavePrefs(p);
}
- (id)getExtra:(PSSpecifier *)spec {
    NSNumber *v = JBBLoadPrefs()[@"globalExtraTokens"];
    return v ?: @NO;
}
- (void)setExtra:(id)value spec:(PSSpecifier *)spec {
    NSMutableDictionary *p = JBBLoadPrefs();
    p[@"globalExtraTokens"] = @([value boolValue]);
    JBBSavePrefs(p);
}

@end
