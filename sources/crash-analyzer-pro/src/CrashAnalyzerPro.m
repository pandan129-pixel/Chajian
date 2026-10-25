// CrashAnalyzerPro.m
// Add-on for com.mowang.crashanalyzer ("AI 日志分析" 1.2.0).
//
// Adds:
//   1) batch delete of .ips / .ips.synced logs (root list + every category list)
//   2) a one-tap "DeepSeek" analysis button on every report detail page
//   3) DeepSeek defaults for the existing OpenAI-compatible AI config
//
// The dylib is loaded into Preferences.app by TweakInject and hooks the
// PreferenceBundle classes when PreferenceLoader has loaded them.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>

static NSString *const kCADefaultEndpoint = @"https://api.deepseek.com/v1/chat/completions";
static NSString *const kCADefaultModel = @"deepseek-v4.1-flash";
static NSString *const kCADefaultPrompt = @"分析 iOS IPS 日志，区分事实与推测，引用证据并给出排查步骤。";
static NSString *const kCALogRoot = @"/var/mobile/Library/Logs/CrashReporter";
static NSString *const kCAProLog = @"/var/mobile/Library/Preferences/CrashAnalyzerPro.log";

#pragma mark - logging

static void CAWriteLog(NSString *path, NSString *line) {
    if (!path.length) return;
    FILE *f = fopen(path.fileSystemRepresentation, "a");
    if (f) {
        fputs(line.UTF8String, f);
        fclose(f);
    }
}

static void CALog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];

    CAWriteLog(kCAProLog, line);
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"CrashAnalyzerPro.log"];
    if (tmp.length && ![tmp isEqualToString:kCAProLog]) CAWriteLog(tmp, line);
    NSLog(@"[CrashAnalyzerPro] %@", msg);
}

static void CARotateLog(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:kCAProLog error:nil];
    if (attrs && [attrs fileSize] > 512 * 1024) {
        [fm removeItemAtPath:kCAProLog error:nil];
    }
}

#pragma mark - runtime helpers

typedef id (*CAIdMsg)(id, SEL);
typedef id (*CAIdIdMsg)(id, SEL, id);
typedef id (*CAIdBoolErrMsg)(id, SEL, id, BOOL, NSError **);
typedef void (*CAVoidIdIdBoolBlockMsg)(id, SEL, id, id, BOOL, id);

static IMP CAReplace(Class cls, SEL sel, IMP newImp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        CALog(@"hook: %@ does not implement %@", NSStringFromClass(cls), NSStringFromSelector(sel));
        return NULL;
    }
    IMP old = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    class_replaceMethod(cls, sel, newImp, types);
    return old;
}

static void CAAddMethod(Class cls, SEL sel, IMP imp) {
    if (!cls) return;
    if (class_getInstanceMethod(cls, sel)) return;
    class_addMethod(cls, sel, imp, "v@:@");
}

static id CACallId(id obj, SEL sel) {
    return ((CAIdMsg)objc_msgSend)(obj, sel);
}

static id CACallIdId(id obj, SEL sel, id arg) {
    return ((CAIdIdMsg)objc_msgSend)(obj, sel, arg);
}

static id CAStore(void) {
    Class c = NSClassFromString(@"CALogStore");
    if (!c) return nil;
    return CACallId((id)c, @selector(sharedStore));
}

static NSString *CAString(id obj) {
    return [obj isKindOfClass:[NSString class]] ? obj : nil;
}

static void CAShowAlert(id host, NSString *title, NSString *message) {
    if (![host isKindOfClass:[UIViewController class]]) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [(UIViewController *)host presentViewController:ac animated:YES completion:nil];
}

#pragma mark - DeepSeek defaults

static void CAInstallDeepSeekDefaults(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d registerDefaults:@{
        @"CAAIEndpoint": kCADefaultEndpoint,
        @"CAAIMode": kCADefaultModel,
        @"CAAIPrompt": kCADefaultPrompt,
        @"CAAIIncludeSource": @NO,
    }];

    // Migrate the old shipped defaults once, without touching a custom endpoint.
    NSString *ep = [d stringForKey:@"CAAIEndpoint"];
    if (!ep.length || [ep isEqualToString:@"https://api.openai.com/v1/chat/completions"]) {
        [d setObject:kCADefaultEndpoint forKey:@"CAAIEndpoint"];
    }
    NSString *model = [d stringForKey:@"CAAIMode"];
    if (!model.length ||
        [model isEqualToString:@"deepseek-ai/DeepSeek-V4-Pro"] ||
        [model isEqualToString:@"deepseek-chat"]) {
        [d setObject:kCADefaultModel forKey:@"CAAIMode"];
    }
    if (![d stringForKey:@"CAAIPrompt"].length) {
        [d setObject:kCADefaultPrompt forKey:@"CAAIPrompt"];
    }
    [d synchronize];
}

#pragma mark - batch delete controller

@interface CABatchDeleteController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *categoryFilter;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<NSDictionary *> *items;
@property (nonatomic, strong) NSMutableSet<NSString *> *selected;
@property (nonatomic, strong) UIBarButtonItem *deleteItem;
@property (nonatomic, strong) UIBarButtonItem *selectAllItem;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UILabel *headerLabel;
@end

@implementation CABatchDeleteController

- (instancetype)initWithCategory:(NSString *)category {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _categoryFilter = [category copy];
        _selected = [NSMutableSet set];
        self.title = category.length ? [NSString stringWithFormat:@"清理 · %@", category] : @"批量删除日志";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 62;
    self.tableView.tableFooterView = [UIView new];
    [self.view addSubview:self.tableView];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center = self.view.center;
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:self.spinner];

    self.emptyLabel = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 32, 0)];
    self.emptyLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.emptyLabel.text = @"没有可删除的日志";
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.hidden = YES;
    [self.view addSubview:self.emptyLabel];

    self.deleteItem = [[UIBarButtonItem alloc] initWithTitle:@"删除"
                                                       style:UIBarButtonItemStylePlain
                                                      target:self
                                                      action:@selector(deleteSelected:)];
    self.deleteItem.enabled = NO;
    self.selectAllItem = [[UIBarButtonItem alloc] initWithTitle:@"全选"
                                                          style:UIBarButtonItemStylePlain
                                                         target:self
                                                         action:@selector(toggleSelectAll:)];
    self.navigationItem.rightBarButtonItems = @[self.deleteItem, self.selectAllItem];

    [self.spinner startAnimating];
    [self reloadItems];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Do not leave a stale selection behind if the list is reused.
    if (self.isMovingFromParentViewController) {
        [self.selected removeAllObjects];
    }
}

- (NSArray<NSDictionary *> *)scanItems {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *ipsSeen = [NSMutableSet set];
    NSMutableSet<NSString *> *syncedOnly = [NSMutableSet set];

    NSDirectoryEnumerator *en = [fm enumeratorAtPath:kCALogRoot];
    for (NSString *rel in en) {
        NSString *lower = rel.lowercaseString;
        BOOL isIps = [lower hasSuffix:@".ips"];
        BOOL isSynced = [lower hasSuffix:@".ips.synced"];
        if (!isIps && !isSynced) continue;

        NSString *full = [kCALogRoot stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir] || isDir) continue;

        if (isIps) {
            [ipsSeen addObject:full];
        } else {
            NSString *base = [full stringByDeletingPathExtension];
            if (![fm fileExistsAtPath:base]) [syncedOnly addObject:full];
            continue;
        }

        NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
        [items addObject:[@{
            @"path": full,
            @"name": rel.lastPathComponent ?: full.lastPathComponent,
            @"size": attrs[NSFileSize] ?: @0,
            @"date": attrs[NSFileModificationDate] ?: [NSDate distantPast],
        } mutableCopy]];
    }

    for (NSString *full in syncedOnly) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
        [items addObject:[@{
            @"path": full,
            @"name": full.lastPathComponent,
            @"size": attrs[NSFileSize] ?: @0,
            @"date": attrs[NSFileModificationDate] ?: [NSDate distantPast],
        } mutableCopy]];
    }

    // Attach categories from the original store when available.
    NSMutableDictionary<NSString *, NSString *> *categoryByPath = [NSMutableDictionary dictionary];
    id store = CAStore();
    if (store) {
        id reports = CACallId(store, @selector(reports));
        if ([reports isKindOfClass:[NSArray class]]) {
            for (id r in (NSArray *)reports) {
                if (![r isKindOfClass:[NSDictionary class]]) continue;
                NSString *p = CAString(((NSDictionary *)r)[@"path"]);
                NSString *cat = CAString(((NSDictionary *)r)[@"category"]);
                if (p.length && cat.length) categoryByPath[p] = cat;
            }
        }
    }

    NSString *filter = self.categoryFilter;
    NSMutableArray<NSDictionary *> *filtered = [NSMutableArray array];
    for (NSMutableDictionary *item in items) {
        NSString *p = item[@"path"];
        NSString *cat = categoryByPath[p];
        if (cat.length) item[@"category"] = cat;
        if (filter.length && ![filter isEqualToString:cat ?: @""]) continue;
        [filtered addObject:item];
    }

    [filtered sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"date"] compare:a[@"date"]];
    }];
    return filtered;
}

- (void)reloadItems {
    self.items = @[];
    [self.tableView reloadData];
    [self updateUI];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *items = [self scanItems];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.items = items;
            [self.selected intersectSet:[NSSet setWithArray:[items valueForKey:@"path"] ?: @[]]];
            [self.spinner stopAnimating];
            [self.tableView reloadData];
            [self updateUI];
        });
    });
}

- (void)updateUI {
    NSUInteger total = self.items.count;
    NSUInteger sel = self.selected.count;
    self.deleteItem.title = sel ? [NSString stringWithFormat:@"删除 (%lu)", (unsigned long)sel] : @"删除";
    self.deleteItem.enabled = sel > 0;
    self.selectAllItem.title = (total > 0 && sel == total) ? @"取消全选" : @"全选";
    self.selectAllItem.enabled = total > 0;
    self.emptyLabel.hidden = total > 0;
    self.tableView.hidden = total == 0;
}

- (NSString *)subtitleForItem:(NSDictionary *)item {
    NSString *cat = item[@"category"] ?: @"未分类";
    unsigned long long size = [item[@"size"] unsignedLongLongValue];
    NSString *sizeText = [NSByteCountFormatter stringFromByteCount:(long long)size
                                                        countStyle:NSByteCountFormatterCountStyleFile];
    NSDate *date = item[@"date"];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm";
    NSString *dateText = [date isKindOfClass:[NSDate class]] ? [df stringFromDate:date] : @"时间未知";
    return [NSString stringWithFormat:@"%@ · %@ · %@", cat, sizeText, dateText];
}

#pragma mark table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"CABatchDeleteCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
        cell.textLabel.font = [UIFont systemFontOfSize:15];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    NSDictionary *item = self.items[(NSUInteger)indexPath.row];
    cell.textLabel.text = item[@"name"];
    cell.detailTextLabel.text = [self subtitleForItem:item];
    BOOL on = [self.selected containsObject:item[@"path"]];
    cell.accessoryType = on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = self.items[(NSUInteger)indexPath.row];
    NSString *path = item[@"path"];
    if (!path.length) return;
    if ([self.selected containsObject:path]) [self.selected removeObject:path];
    else [self.selected addObject:path];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [self updateUI];
}

#pragma mark actions

- (void)toggleSelectAll:(id)sender {
    if (self.items.count == 0) return;
    if (self.selected.count == self.items.count) {
        [self.selected removeAllObjects];
    } else {
        for (NSDictionary *item in self.items) {
            NSString *p = item[@"path"];
            if (p.length) [self.selected addObject:p];
        }
    }
    [self.tableView reloadData];
    [self updateUI];
}

- (void)deleteSelected:(id)sender {
    if (self.selected.count == 0) return;
    NSUInteger count = self.selected.count;
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"删除日志？"
                         message:[NSString stringWithFormat:
                                     @"将删除 %lu 个日志文件（同时删除对应的 .ips.synced）。\n此操作不可撤销，不会删除案例库或 AI 历史。",
                                     (unsigned long)count]
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"删除"
                                           style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *action) {
        [weakSelf performDelete];
    }]];
    ac.popoverPresentationController.barButtonItem = self.deleteItem;
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)performDelete {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger deletedFiles = 0;
    NSUInteger failedFiles = 0;

    for (NSString *path in [self.selected allObjects]) {
        NSString *companion = [path hasSuffix:@".ips.synced"]
            ? [path stringByDeletingPathExtension]
            : [path stringByAppendingString:@".synced"];

        for (NSString *p in @[path, companion]) {
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:p isDirectory:&isDir] || isDir) continue;
            NSError *err = nil;
            if ([fm removeItemAtPath:p error:&err]) {
                deletedFiles++;
            } else {
                failedFiles++;
                CALog(@"delete failed %@: %@", p, err.localizedDescription);
            }
        }
    }

    [self.selected removeAllObjects];

    id store = CAStore();
    if (store) {
        ((void (*)(id, SEL))objc_msgSend)(store, @selector(refreshReports));
        [[NSNotificationCenter defaultCenter] postNotificationName:@"CALogStoreDidRefreshNotification" object:store];
    }

    [self reloadItems];

    NSString *msg = failedFiles
        ? [NSString stringWithFormat:@"已删除 %lu 个文件，%lu 个失败。", (unsigned long)deletedFiles, (unsigned long)failedFiles]
        : [NSString stringWithFormat:@"已删除 %lu 个文件。", (unsigned long)deletedFiles];
    NSString *title = failedFiles ? @"部分删除失败" : @"删除完成";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CAShowAlert(self, title, msg);
    });
    CALog(@"batch delete: files=%lu failed=%lu", (unsigned long)deletedFiles, (unsigned long)failedFiles);
}

@end

#pragma mark - DeepSeek result controller

@interface CADeepSeekResultController : UIViewController
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIBarButtonItem *pasteButton;
@property (nonatomic, strong) UIBarButtonItem *stopItem;
@property (nonatomic, assign) BOOL loading;
@end

@implementation CADeepSeekResultController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"DeepSeek 分析";

    self.textView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.editable = NO;
    self.textView.selectable = YES;
    self.textView.alwaysBounceVertical = YES;
    self.textView.font = [UIFont systemFontOfSize:14];
    self.textView.textContainerInset = UIEdgeInsetsMake(14, 14, 14, 14);
    [self.view addSubview:self.textView];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];

    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    self.pasteButton = [[UIBarButtonItem alloc] initWithTitle:@"复制"
                                                     style:UIBarButtonItemStylePlain
                                                    target:self
                                                    action:@selector(copyResult:)];
    self.pasteButton.enabled = NO;
    self.stopItem = [[UIBarButtonItem alloc] initWithTitle:@"停止"
                                                     style:UIBarButtonItemStylePlain
                                                    target:self
                                                    action:@selector(stopRequest:)];
    self.navigationItem.rightBarButtonItems = @[self.pasteButton, self.stopItem];
}

- (void)setStatus:(NSString *)status {
    [self loadViewIfNeeded];
    self.loading = YES;
    self.pasteButton.enabled = NO;
    self.stopItem.enabled = YES;
    self.textView.text = status;
    [self.spinner startAnimating];
}

- (void)setResult:(NSString *)text {
    [self loadViewIfNeeded];
    self.loading = NO;
    self.pasteButton.enabled = text.length > 0;
    self.stopItem.enabled = NO;
    self.textView.text = text.length ? text : @"(空响应)";
    [self.spinner stopAnimating];
    [self.textView setContentOffset:CGPointZero animated:NO];
}

- (void)copyResult:(id)sender {
    if (!self.textView.text.length) return;
    [UIPasteboard generalPasteboard].string = self.textView.text;
    self.pasteButton.title = @"已复制";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.pasteButton.title = @"复制";
    });
}

- (void)stopRequest:(id)sender {
    Class c = NSClassFromString(@"CAAIService");
    if (c) {
        id svc = CACallId((id)c, @selector(shared));
        if (svc) ((void (*)(id, SEL))objc_msgSend)(svc, @selector(cancelAnalysis));
    }
    self.stopItem.enabled = NO;
    [self.spinner stopAnimating];
    self.textView.text = @"已取消请求。服务端可能已计费。";
}

@end

#pragma mark - buttons / actions

static void CAEnsureBarButton(id self, SEL action, NSString *title) {
    if (![self isKindOfClass:[UIViewController class]]) return;
    UINavigationItem *ni = [(UIViewController *)self navigationItem];
    if (!ni) return;

    NSMutableArray<UIBarButtonItem *> *items = [ni.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    if (ni.rightBarButtonItem && ![items containsObject:ni.rightBarButtonItem]) {
        [items addObject:ni.rightBarButtonItem];
    }
    for (UIBarButtonItem *item in items) {
        if (item.target == self && item.action == action) return;
    }
    UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:title
                                                           style:UIBarButtonItemStylePlain
                                                          target:self
                                                          action:action];
    [items insertObject:btn atIndex:0];
    ni.rightBarButtonItems = items;
}

static void CAEnsureManageButton(id self) {
    CAEnsureBarButton(self, @selector(ca_openBatchDelete:), @"管理");
}

static void CAEnsureDeepSeekButton(id self) {
    CAEnsureBarButton(self, @selector(ca_deepSeek:), @"DeepSeek");
}

static void CAOpenBatchDelete(id self, SEL _cmd, id sender) {
    NSString *category = nil;
    if ([self respondsToSelector:@selector(reportCategory)]) {
        NSString *c = CAString(CACallId(self, @selector(reportCategory)));
        if (c.length) category = c;
    }
    CABatchDeleteController *vc = [[CABatchDeleteController alloc] initWithCategory:category];
    UINavigationController *nav = [(UIViewController *)self navigationController];
    if (nav) {
        [nav pushViewController:vc animated:YES];
    } else {
        UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:vc];
        n.modalPresentationStyle = UIModalPresentationFormSheet;
        [(UIViewController *)self presentViewController:n animated:YES completion:nil];
    }
    CALog(@"open batch delete category=%@", category ?: @"(all)");
}

static void CADeepSeekAction(id self, SEL _cmd, id sender) {
    NSDictionary *report = nil;
    @try {
        id r = [(UIViewController *)self valueForKey:@"report"];
        if ([r isKindOfClass:[NSDictionary class]]) report = r;
    } @catch (__unused NSException *e) {
    }
    if (!report) {
        CAShowAlert(self, @"无法分析", @"没有读到这条日志的详情，请返回后重新打开。");
        return;
    }

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *key = [d stringForKey:@"CAAIKey"];
    NSString *endpoint = [d stringForKey:@"CAAIEndpoint"];
    NSString *model = [d stringForKey:@"CAAIMode"];
    BOOL includeSource = [d boolForKey:@"CAAIIncludeSource"];
    BOOL forcedSource = NO;
    id parseError = [report objectForKey:@"parseError"];
    NSString *bugType = CAString([report objectForKey:@"bug_type"]);
    if (parseError || !bugType.length || [bugType isEqualToString:@"unknown"]) {
        if (!includeSource) {
            includeSource = YES;
            forcedSource = YES;
        }
    }

    if (!key.length) {
        CAShowAlert(self, @"还没有 API Key",
                    @"请先进入「AI 分析配置」填写 DeepSeek API Key（只保存在本机），然后再点 DeepSeek。");
        return;
    }
    if (!endpoint.length || !model.length) {
        CAShowAlert(self, @"AI 配置不完整", @"请先在「AI 分析配置」填写接口地址和模型。");
        return;
    }

    Class svcClass = NSClassFromString(@"CAAIService");
    id svc = svcClass ? CACallId((id)svcClass, @selector(shared)) : nil;
    if (!svc) {
        CAShowAlert(self, @"AI 服务不可用", @"找不到 CAAIService，请确认原插件已正确加载。");
        return;
    }

    NSError *err = nil;
    id prepared = ((CAIdBoolErrMsg)objc_msgSend)(svc,
                                                 @selector(prepareReport:includeSource:error:),
                                                 report, includeSource, &err);
    if (!prepared) {
        CAShowAlert(self, @"预检失败", err.localizedDescription ?: @"无法准备请求。");
        return;
    }

    NSNumber *bytes = [prepared isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)prepared)[@"bytes"] : nil;
    NSString *scope = includeSource ? @"source（含完整源文件）" : @"structured（结构化信息）";
    NSString *host = [NSURL URLWithString:endpoint].host ?: endpoint;
    NSString *msg = [NSString stringWithFormat:
        @"模型：%@\n接口：%@\n范围：%@\npayload：%@ 字节\n\n将直接调用 DeepSeek，可能产生费用。",
        model, host, scope, bytes ?: @0];
    if (forcedSource) {
        msg = [@"该日志未能结构化解析，已自动改为发送完整源文件。\n\n" stringByAppendingString:msg];
    }

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"DeepSeek 直接分析"
                                                                 message:msg
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"开始分析"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action) {
        UIViewController *hostVC = weakSelf;
        if (!hostVC) return;
        CADeepSeekResultController *vc = [[CADeepSeekResultController alloc] initWithNibName:nil bundle:nil];
        UINavigationController *nav = hostVC.navigationController;
        if (nav) [nav pushViewController:vc animated:YES];
        else [hostVC presentViewController:vc animated:YES completion:nil];

        [vc setStatus:@"正在请求 DeepSeek，请稍候…\n\n（只发送上方预检显示的范围；不会自动重试）"];
        CALog(@"deepseek start model=%@ host=%@ scope=%@ bytes=%@", model, host, includeSource ? @"source" : @"structured", bytes ?: @0);

        __weak CADeepSeekResultController *weakVC = vc;
        void (^completion)(id, id) = ^(id text, id error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                CADeepSeekResultController *strongVC = weakVC;
                if (!strongVC) return;
                if (error) {
                    NSString *desc = [error respondsToSelector:@selector(localizedDescription)]
                        ? [error localizedDescription] : [error description];
                    [strongVC setResult:[NSString stringWithFormat:@"分析失败：%@", desc ?: @"未知错误"]];
                    CALog(@"deepseek failed: %@", desc);
                } else {
                    NSString *out = [text isKindOfClass:[NSString class]] ? text : [text description];
                    [strongVC setResult:out];
                    CALog(@"deepseek done bytes=%lu", (unsigned long)out.length);
                }
            });
        };

        ((CAVoidIdIdBoolBlockMsg)objc_msgSend)(svc,
                                               @selector(runPrepared:report:fresh:completion:),
                                               prepared, report, YES, completion);
    }]];
    [(UIViewController *)self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - hooks

static IMP gOrigRootViewDidLoad;
static IMP gOrigRootViewWillAppear;
static IMP gOrigReportViewDidLoad;
static IMP gOrigReportViewWillAppear;
static IMP gOrigDetailViewDidLoad;
static IMP gOrigDetailViewWillAppear;
static IMP gOrigPayload;

static void CARootViewDidLoad(id self, SEL _cmd) {
    if (gOrigRootViewDidLoad) ((void (*)(id, SEL))gOrigRootViewDidLoad)(self, _cmd);
    CAEnsureManageButton(self);
}

static void CARootViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigRootViewWillAppear) ((void (*)(id, SEL, BOOL))gOrigRootViewWillAppear)(self, _cmd, animated);
    CAEnsureManageButton(self);
}

static void CAReportViewDidLoad(id self, SEL _cmd) {
    if (gOrigReportViewDidLoad) ((void (*)(id, SEL))gOrigReportViewDidLoad)(self, _cmd);
    CAEnsureManageButton(self);
}

static void CAReportViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigReportViewWillAppear) ((void (*)(id, SEL, BOOL))gOrigReportViewWillAppear)(self, _cmd, animated);
    CAEnsureManageButton(self);
}

static void CADetailViewDidLoad(id self, SEL _cmd) {
    if (gOrigDetailViewDidLoad) ((void (*)(id, SEL))gOrigDetailViewDidLoad)(self, _cmd);
    CAEnsureDeepSeekButton(self);
}

static void CADetailViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigDetailViewWillAppear) ((void (*)(id, SEL, BOOL))gOrigDetailViewWillAppear)(self, _cmd, animated);
    CAEnsureDeepSeekButton(self);
}

// DeepSeek "flash" models spend most of the output budget on reasoning_content.
// The original payload hard-codes max_tokens=2048, which can leave content empty.
static id CAPayload(id self, SEL _cmd, id report, id source, id model, id prompt) {
    id result = gOrigPayload
        ? ((id (*)(id, SEL, id, id, id, id))gOrigPayload)(self, _cmd, report, source, model, prompt)
        : nil;
    if ([result isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *dict = [result mutableCopy];
        dict[@"max_tokens"] = @8192;
        return dict;
    }
    return result;
}

static void CAWalkViewController(UIViewController *vc) {
    if (!vc) return;
    Class rootCls = NSClassFromString(@"CAPRootListController");
    Class reportCls = NSClassFromString(@"CAReportViewController");
    Class detailCls = NSClassFromString(@"CAReportDetailController");

    if (rootCls && [vc isKindOfClass:rootCls]) CAEnsureManageButton(vc);
    if (reportCls && [vc isKindOfClass:reportCls]) CAEnsureManageButton(vc);
    if (detailCls && [vc isKindOfClass:detailCls]) CAEnsureDeepSeekButton(vc);

    for (UIViewController *child in vc.childViewControllers) CAWalkViewController(child);
    if (vc.presentedViewController) CAWalkViewController(vc.presentedViewController);
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *child in ((UINavigationController *)vc).viewControllers) CAWalkViewController(child);
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *child in ((UITabBarController *)vc).viewControllers) CAWalkViewController(child);
    }
    if ([vc isKindOfClass:[UISplitViewController class]]) {
        for (UIViewController *child in ((UISplitViewController *)vc).viewControllers) CAWalkViewController(child);
    }
}

static void CAEnsureButtonsInHierarchy(void) {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            CAWalkViewController(window.rootViewController);
        }
    }
}

static BOOL CAInstallHooks(void) {
    static BOOL installed = NO;
    if (installed) return YES;

    Class root = NSClassFromString(@"CAPRootListController");
    Class report = NSClassFromString(@"CAReportViewController");
    Class detail = NSClassFromString(@"CAReportDetailController");
    if (!root || !report || !detail) return NO;

    installed = YES;
    gOrigRootViewDidLoad = CAReplace(root, @selector(viewDidLoad), (IMP)CARootViewDidLoad);
    gOrigRootViewWillAppear = CAReplace(root, @selector(viewWillAppear:), (IMP)CARootViewWillAppear);
    gOrigReportViewDidLoad = CAReplace(report, @selector(viewDidLoad), (IMP)CAReportViewDidLoad);
    gOrigReportViewWillAppear = CAReplace(report, @selector(viewWillAppear:), (IMP)CAReportViewWillAppear);
    gOrigDetailViewDidLoad = CAReplace(detail, @selector(viewDidLoad), (IMP)CADetailViewDidLoad);
    gOrigDetailViewWillAppear = CAReplace(detail, @selector(viewWillAppear:), (IMP)CADetailViewWillAppear);

    CAAddMethod(root, @selector(ca_openBatchDelete:), (IMP)CAOpenBatchDelete);
    CAAddMethod(report, @selector(ca_openBatchDelete:), (IMP)CAOpenBatchDelete);
    CAAddMethod(detail, @selector(ca_deepSeek:), (IMP)CADeepSeekAction);

    Class workbench = NSClassFromString(@"CAWorkbench");
    if (workbench) {
        gOrigPayload = CAReplace(object_getClass(workbench),
                                 @selector(payload:source:model:prompt:),
                                 (IMP)CAPayload);
    }

    CALog(@"hooks installed (root=%@ report=%@ detail=%@)",
          NSStringFromClass(root), NSStringFromClass(report), NSStringFromClass(detail));
    CAEnsureButtonsInHierarchy();
    return YES;
}

static void CAScheduleInstall(int tries) {
    if (CAInstallHooks()) return;
    if (tries <= 0) {
        CALog(@"hooks not installed: classes never appeared");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CAScheduleInstall(tries - 1);
    });
}

#pragma mark - entry

__attribute__((constructor)) static void CAProInit(void) {
    @autoreleasepool {
        CARotateLog();
        CALog(@"loaded pid=%d home=%@ tmp=%@", getpid(), NSHomeDirectory(), NSTemporaryDirectory());
        CAInstallDeepSeekDefaults();
        if (!CAInstallHooks()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                CAScheduleInstall(300); // ~60s, covers lazy bundle loading
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                CAEnsureButtonsInHierarchy();
            });
        }
    }
}
