#import <Preferences/PSSpecifier.h>
#import "JBBTweakAppsController.h"
#import "JBBAppSettingsController.h"
#import "JBBPrefsCommon.h"

@implementation JBBTweakAppsController

- (PSSpecifier *)rowFor:(NSString *)bid tweaks:(NSArray *)tweaks {
    NSString *title = [NSString stringWithFormat:@"%@  ·  %@",
                       JBBAppName(bid), [tweaks componentsJoinedByString:@", "]];
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:title
                                                      target:self set:nil get:nil
                                                       detail:[JBBAppSettingsController class]
                                                        cell:PSLinkCell edit:nil];
    [row setProperty:bid forKey:@"jbbBundleID"];
    return row;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        NSDictionary *map = JBBTweakMap();
        NSMutableArray *installed = [NSMutableArray array];
        NSUInteger missingCount = 0;
        for (NSString *bid in map.allKeys) {
            if (JBBAppIsInstalled(bid)) [installed addObject:bid];
            else missingCount++;
        }
        [installed sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return [JBBAppName(a) localizedCaseInsensitiveCompare:JBBAppName(b)];
        }];

        PSSpecifier *g = [PSSpecifier groupSpecifierWithName:
                          [NSString stringWithFormat:@"有插件的 App（%lu）", (unsigned long)installed.count]];
        NSString *footer = [NSString stringWithFormat:
                            @"已解析 %lu 个 tweak filter。这里只列出本机已安装、且 filter 会注入的 App；"
                            @"多个插件同时生效时可能互相影响。",
                            (unsigned long)JBBTweakFilterCount()];
        if (missingCount > 0) {
            footer = [footer stringByAppendingFormat:
                      @"\n已忽略 %lu 个未安装的 filter 变体（例如同一 App 的其它渠道包）。",
                      (unsigned long)missingCount];
        }
        if (JBBInstalledAppCount() < 0) {
            footer = [footer stringByAppendingString:
                      @"\n无法读取已安装 App 列表，暂时列出所有 filter 目标。"];
        }
        if (JBBTweakFilterFailedCount() > 0) {
            footer = [footer stringByAppendingFormat:@"\n另有 %lu 个 filter 读取失败。",
                      (unsigned long)JBBTweakFilterFailedCount()];
        }
        [g setProperty:footer forKey:@"footerText"];
        [specs addObject:g];

        if (installed.count == 0) {
            [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"（没有找到带 filter 的插件）"
                                                            target:nil set:nil get:nil detail:nil
                                                              cell:PSStaticTextCell edit:nil]];
        }
        for (NSString *bid in installed) {
            [specs addObject:[self rowFor:bid tweaks:map[bid]]];
        }

        _specifiers = specs;
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _specifiers = nil;
    [self reloadSpecifiers];
}

@end
