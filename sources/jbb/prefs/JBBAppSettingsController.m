#import <Preferences/PSSpecifier.h>
#import "JBBAppSettingsController.h"
#import "JBBPrefsCommon.h"

static NSArray *JBBKeys(void) {
    return @[
        @[@"enabled", @"启用 JBB"],
        @[@"file", @"文件 API (stat/open/readdir)"],
        @[@"objc", @"ObjC (NSFileManager/canOpenURL)"],
        @[@"dyld", @"dladdr"],
        @[@"name", @"dyld 镜像枚举"],
        @[@"sysctl", @"sysctl (进程/环境)"],
        @[@"ptrace", @"ptrace (反调试)"],
        @[@"ppid", @"getppid"],
        @[@"env", @"getenv (DYLD_*)"],
        @[@"csops", @"csops 标志位"],
        @[@"extraTokens", @"额外 token"],
    ];
}

@implementation JBBAppSettingsController

- (void)setSpecifier:(PSSpecifier *)specifier {
    [super setSpecifier:specifier];
    self.bundleID = [specifier propertyForKey:@"jbbBundleID"];
    self.title = JBBAppName(self.bundleID);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    NSMutableDictionary *prefs = JBBLoadPrefs();
    JBBProfile(prefs, self.bundleID, YES);
    JBBSavePrefs(prefs);
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        [specs addObject:[PSSpecifier groupSpecifierWithName:self.bundleID ?: @""]];

        for (NSArray *pair in JBBKeys()) {
            NSString *key = pair[0];
            PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:pair[1]
                                                            target:self
                                                               set:@selector(setValue:spec:)
                                                               get:@selector(getValue:)
                                                            detail:nil cell:PSSwitchCell edit:nil];
            [s setProperty:key forKey:@"jbbKey"];
            BOOL def = [@[@"env", @"extraTokens"] containsObject:key] ? NO : YES;
            [s setProperty:@(def) forKey:@"default"];
            [specs addObject:s];
        }

        PSSpecifier *applyGroup = [PSSpecifier groupSpecifierWithName:@"应用"];
        [applyGroup setProperty:@"改动会写入配置。点下面按钮会保存并尝试重启该 App，使其立即生效。" forKey:@"footerText"];
        [specs addObject:applyGroup];

        PSSpecifier *apply = [PSSpecifier preferenceSpecifierNamed:@"保存并重启 App（立即生效）"
                                                            target:nil set:nil get:nil detail:nil
                                                              cell:PSButtonCell edit:nil];
        [apply setProperty:@"apply" forKey:@"jbbAction"];
        [specs addObject:apply];

        PSSpecifier *del = [PSSpecifier preferenceSpecifierNamed:@"移除此 App 的配置"
                                                          target:nil set:nil get:nil detail:nil
                                                            cell:PSButtonCell edit:nil];
        [del setProperty:@"delete" forKey:@"jbbAction"];
        [specs addObject:del];

        _specifiers = specs;
    }
    return _specifiers;
}

- (id)getValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"jbbKey"];
    NSMutableDictionary *prefs = JBBLoadPrefs();
    NSDictionary *profile = JBBProfile(prefs, self.bundleID, NO);
    id v = profile[key];
    if (v) return v;
    return [spec propertyForKey:@"default"] ?: @YES;
}

- (void)setValue:(id)value spec:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"jbbKey"];
    NSMutableDictionary *prefs = JBBLoadPrefs();
    NSMutableDictionary *profile = JBBProfile(prefs, self.bundleID, YES);
    profile[key] = @([value boolValue]);
    JBBSavePrefs(prefs);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = [self specifierAtIndex:[self indexForIndexPath:indexPath]];
    NSString *action = [spec propertyForKey:@"jbbAction"];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if ([action isEqualToString:@"apply"]) {
        NSMutableDictionary *prefs = JBBLoadPrefs();
        time_t savedAt = time(NULL);
        JBBSavePrefs(prefs);
        /* Wait for jbbd to publish this config into the app container, otherwise
         * restarting immediately would pick up the previous config. */
        JBBWaitForDaemonPublish(savedAt, 6.0);
        pid_t pid = JBBFindPid(self.bundleID);
        BOOL killed = NO;
        if (pid > 0) killed = (kill(pid, SIGKILL) == 0);
        NSString *msg = killed
            ? [NSString stringWithFormat:@"已保存，并已重启 %@。", JBBAppName(self.bundleID)]
            : [NSString stringWithFormat:@"已保存。未能自动重启 %@，请从多任务里划掉它再打开。", JBBAppName(self.bundleID)];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"JBB" message:msg preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    } else if ([action isEqualToString:@"delete"]) {
        NSMutableDictionary *prefs = JBBLoadPrefs();
        NSMutableDictionary *profiles = prefs[kJBBProfilesKey];
        if ([profiles isKindOfClass:[NSMutableDictionary class]]) {
            [profiles removeObjectForKey:self.bundleID];
            JBBSavePrefs(prefs);
        }
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [super tableView:tableView didSelectRowAtIndexPath:indexPath];
    }
}

@end
