#import <Preferences/PSSpecifier.h>
#import "JBBAppPickerController.h"
#import "JBBPrefsCommon.h"
#import "JBBAppSettingsController.h"

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSString *localizedShortName;
@property (nonatomic, readonly) NSString *bundleIdentifier;
@end
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end

@interface JBBAppPickerController () <UISearchResultsUpdating>
@property (nonatomic, strong) NSArray<NSString *> *allIDs;
@property (nonatomic, strong) NSSet<NSString *> *tweakIDs;
@property (nonatomic, copy) NSString *query;
@property (nonatomic, strong) UISearchController *searchController;
@end

@implementation JBBAppPickerController

- (void)loadAppsIfNeeded {
    if (self.allIDs) return;

    NSMutableSet *set = [NSMutableSet set];

    for (LSApplicationProxy *p in [[LSApplicationWorkspace defaultWorkspace] allInstalledApplications]) {
        NSString *bid = p.bundleIdentifier;
        if ([bid isKindOfClass:[NSString class]] && bid.length && ![bid hasPrefix:@"com.apple."]) [set addObject:bid];
    }

    /* Fallback: LS is sometimes restricted inside Settings; scan the bundle dirs. */
    if (set.count == 0) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *roots = @[@"/var/containers/Bundle/Application", @"/Applications", @"/var/jb/Applications"];
        for (NSString *root in roots) {
            for (NSString *item in [fm contentsOfDirectoryAtPath:root error:nil]) {
                NSString *dir = [root stringByAppendingPathComponent:item];
                NSArray *children = [fm contentsOfDirectoryAtPath:dir error:nil];
                if (!children.count) {
                    children = @[item]; // /Applications/Foo.app
                    dir = root;
                }
                for (NSString *child in children) {
                    if (![child hasSuffix:@".app"]) continue;
                    NSString *infoPath = [[dir stringByAppendingPathComponent:child] stringByAppendingPathComponent:@"Info.plist"];
                    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
                    NSString *bid = info[@"CFBundleIdentifier"];
                    if ([bid isKindOfClass:[NSString class]] && bid.length && ![bid hasPrefix:@"com.apple."]) [set addObject:bid];
                }
            }
        }
    }

    NSMutableArray *ids = [set.allObjects mutableCopy];
    [ids sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [JBBAppName(a) localizedCaseInsensitiveCompare:JBBAppName(b)];
    }];
    self.allIDs = ids;
    self.tweakIDs = [NSSet setWithArray:JBBAppsWithTweaks()];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self loadAppsIfNeeded];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    self.query = sc.searchBar.text ?: @"";
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (BOOL)matches:(NSString *)bid {
    if (self.query.length == 0) return YES;
    return [bid rangeOfString:self.query options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [JBBAppName(bid) rangeOfString:self.query options:NSCaseInsensitiveSearch].location != NSNotFound;
}

- (PSSpecifier *)rowFor:(NSString *)bid {
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:JBBAppName(bid)
                                                      target:self set:nil get:nil
                                                       detail:[JBBAppSettingsController class]
                                                        cell:PSLinkCell edit:nil];
    [row setProperty:bid forKey:@"jbbBundleID"];
    return row;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        [self loadAppsIfNeeded];
        NSMutableArray *specs = [NSMutableArray array];

        if (self.query.length > 0) {
            [specs addObject:[PSSpecifier groupSpecifierWithName:@"搜索结果"]];
            for (NSString *bid in self.allIDs) if ([self matches:bid]) [specs addObject:[self rowFor:bid]];
            _specifiers = specs;
            return _specifiers;
        }

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"全部 App"]];
        for (NSString *bid in self.allIDs) [specs addObject:[self rowFor:bid]];

        _specifiers = specs;
    }
    return _specifiers;
}

@end
