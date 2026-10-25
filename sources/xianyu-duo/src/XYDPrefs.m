#import "XYDCommon.h"
#import <stdarg.h>
#import <os/lock.h>
#import <string.h>

static NSString *const kXYDDomain = @"com.pandan.xianyuduo";

void XYDLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"xianyuduo.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    if (fh) {
        @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        @catch (__unused NSException *e) {}
    }
}

#pragma mark - prefs

static NSMutableDictionary *gPrefsCache;
static os_unfair_lock gPrefsLock = OS_UNFAIR_LOCK_INIT;

static id XYDCFRead(NSString *key) {
    CFStringRef k = (__bridge CFStringRef)key;
    CFStringRef d = (__bridge CFStringRef)kXYDDomain;
    CFPropertyListRef v = CFPreferencesCopyAppValue(k, d);
    if (!v) return nil;
    return (__bridge_transfer id)v;
}

NSDictionary *XYDPrefsAll(void) {
    os_unfair_lock_lock(&gPrefsLock);
    NSDictionary *d = [gPrefsCache copy];
    os_unfair_lock_unlock(&gPrefsLock);
    return d ?: @{};
}

void XYDDefaultsIfNeeded(void) {
    os_unfair_lock_lock(&gPrefsLock);
    if (!gPrefsCache) {
        NSMutableDictionary *m = [@{
            @"enabled":        @YES,
            @"blockSplash":    @YES,
            @"blockFeed":      @YES,
            @"cleanMyPage":    @YES,
            @"showBall":       @YES,
            @"myPageEntry":    @YES,
            @"autoCapture":    @YES,
            @"captureVideo":   @YES,
            @"minKB":          @15,
            @"minPixel":       @300,
            @"debug":          @NO,
        } mutableCopy];
        NSArray *keys = @[@"enabled",@"blockSplash",@"blockFeed",@"cleanMyPage",@"showBall",
                          @"myPageEntry",@"autoCapture",@"captureVideo",@"minKB",@"minPixel",@"debug"];
        for (NSString *k in keys) {
            id v = XYDCFRead(k);
            if (v) m[k] = v;
        }
        gPrefsCache = m;
    }
    os_unfair_lock_unlock(&gPrefsLock);
}

void XYDRefreshPrefs(void) {
    os_unfair_lock_lock(&gPrefsLock);
    gPrefsCache = nil;
    os_unfair_lock_unlock(&gPrefsLock);
    XYDDefaultsIfNeeded();
}

BOOL XYDPrefBool(NSString *key, BOOL def) {
    XYDDefaultsIfNeeded();
    os_unfair_lock_lock(&gPrefsLock);
    id v = gPrefsCache[key];
    os_unfair_lock_unlock(&gPrefsLock);
    return v ? [v boolValue] : def;
}

double XYDPrefDouble(NSString *key, double def) {
    XYDDefaultsIfNeeded();
    os_unfair_lock_lock(&gPrefsLock);
    id v = gPrefsCache[key];
    os_unfair_lock_unlock(&gPrefsLock);
    return v ? [v doubleValue] : def;
}

NSString *XYDPrefString(NSString *key, NSString *def) {
    XYDDefaultsIfNeeded();
    os_unfair_lock_lock(&gPrefsLock);
    id v = gPrefsCache[key];
    os_unfair_lock_unlock(&gPrefsLock);
    if (!v) v = XYDCFRead(key);
    return [v isKindOfClass:[NSString class]] ? v : def;
}

void XYDSetPref(NSString *key, id value) {
    XYDDefaultsIfNeeded();
    os_unfair_lock_lock(&gPrefsLock);
    gPrefsCache[key] = value ?: @0;
    os_unfair_lock_unlock(&gPrefsLock);
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)(value ?: @0),
                             (__bridge CFStringRef)kXYDDomain);
    XYDSyncPrefs();
}

void XYDSyncPrefs(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kXYDDomain);
}

#pragma mark - hooks

BOOL XYDClassExists(NSString *name) { return NSClassFromString(name) != nil; }

BOOL XYDClassHasMethod(NSString *cls, NSString *sel) {
    Class c = NSClassFromString(cls);
    return c && class_getInstanceMethod(c, NSSelectorFromString(sel)) != NULL;
}

static BOOL XYDClassOwnsMethod(Class c, SEL sel) {
    unsigned int count = 0;
    Method *list = class_copyMethodList(c, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(list[i]) == sel) { found = YES; break; }
    }
    if (list) free(list);
    return found;
}

static BOOL XYDHookOnClass(Class c, SEL sel, IMP newImp, IMP *outOrig) {
    if (!c) return NO;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return NO;
    if (!XYDClassOwnsMethod(c, sel)) {
        // 继承自父类：必须在本类新增 override，绝不能直接改父类 Method
        IMP inherited = method_getImplementation(m);
        const char *types = method_getTypeEncoding(m);
        if (!class_addMethod(c, sel, newImp, types)) return NO;
        if (outOrig) *outOrig = inherited;
        return YES;
    }
    IMP old = method_setImplementation(m, newImp);
    if (outOrig) *outOrig = old;
    return YES;
}

BOOL XYDHookInstance(NSString *cls, NSString *sel, IMP newImp, IMP *outOrig) {
    Class c = NSClassFromString(cls);
    if (!c) return NO;
    SEL s = NSSelectorFromString(sel);
    BOOL ok = XYDHookOnClass(c, s, newImp, outOrig);
    if (ok) XYD_LOG(@"hook -[%@ %@] ok", cls, sel);
    return ok;
}

BOOL XYDHookClass(NSString *cls, NSString *sel, IMP newImp, IMP *outOrig) {
    Class c = NSClassFromString(cls);
    if (!c) return NO;
    Class mc = object_getClass(c);
    SEL s = NSSelectorFromString(sel);
    BOOL ok = XYDHookOnClass(mc, s, newImp, outOrig);
    if (ok) XYD_LOG(@"hook +[%@ %@] ok", cls, sel);
    return ok;
}

BOOL XYDHookOnce(NSString *cls, NSString *sel, IMP newImp, IMP *outOrig) {
    static NSMutableSet *done; static dispatch_once_t once;
    dispatch_once(&once, ^{ done = [NSMutableSet set]; });
    NSString *key = [NSString stringWithFormat:@"%@|%@", cls, sel];
    @synchronized (done) { if ([done containsObject:key]) return NO; }
    BOOL ok = XYDHookInstance(cls, sel, newImp, outOrig);
    if (ok) @synchronized (done) { [done addObject:key]; }
    return ok;
}

BOOL XYDHookFirst(NSArray<NSString *> *classes, NSString *sel, IMP newImp, IMP *outOrig) {
    for (NSString *c in classes) {
        if (XYDHookOnce(c, sel, newImp, outOrig)) return YES;
    }
    return NO;
}

static NSMutableSet *gHookedKeys(void) {
    static NSMutableSet *done; static dispatch_once_t once;
    dispatch_once(&once, ^{ done = [NSMutableSet set]; });
    return done;
}

static Class *gClassList;
static int gClassCount;
static NSObject *gClassLock;
static NSObject *XYDClassLock(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gClassLock = [NSObject new]; });
    return gClassLock;
}

void XYDInvalidateClassCache(void) {
    @synchronized (XYDClassLock()) {
        if (gClassList) { free(gClassList); gClassList = NULL; }
        gClassCount = 0;
    }
}

static void XYDEnsureClassList(void) {
    @synchronized (XYDClassLock()) {
        if (gClassList) return;
        int count = objc_getClassList(NULL, 0);
        if (count <= 0) return;
        Class *list = (Class *)malloc(sizeof(Class) * (size_t)(count + 128));
        if (!list) return;
        count = objc_getClassList(list, count + 128);
        gClassList = list;
        gClassCount = count > 0 ? count : 0;
    }
}

static BOOL XYDNameMatches(const char *name, NSArray<NSString *> *needles) {
    if (!name) return NO;
    for (NSString *n in needles) {
        const char *sub = n.UTF8String;
        if (sub && *sub && strstr(name, sub)) return YES;
    }
    return NO;
}

static NSArray<Class> *XYDClassesMatching(Class base, NSArray<NSString *> *needles) {
    NSString *key = [NSString stringWithFormat:@"%@|%@", base ? NSStringFromClass(base) : @"-",
                     [needles componentsJoinedByString:@","]];
    static NSMutableDictionary<NSString *, NSArray *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) {
        NSArray *hit = cache[key];
        if (hit) return hit;
    }
    XYDEnsureClassList();
    NSMutableArray *out = [NSMutableArray array];
    @synchronized (XYDClassLock()) {
        for (int i = 0; i < gClassCount; i++) {
            Class c = gClassList[i];
            if (!c) continue;
            if (!XYDNameMatches(class_getName(c), needles)) continue;
            if (base) {
                Class p = c; BOOL sub = NO;
                while (p) { if (p == base) { sub = YES; break; } p = class_getSuperclass(p); }
                if (!sub) continue;
            }
            [out addObject:c];
        }
    }
    NSArray *result = [out copy];
    @synchronized (cache) { cache[key] = result; }
    return result;
}

BOOL XYDHookAllSubclassesOf(Class base, NSArray<NSString *> *needles, NSString *sel, IMP newImp, NSMapTable *origMap) {
    SEL s = NSSelectorFromString(sel);
    BOOL any = NO;
    NSMutableSet *done = gHookedKeys();
    for (Class c in XYDClassesMatching(base, needles)) {
        NSString *name = NSStringFromClass(c);
        NSString *key = [NSString stringWithFormat:@"%@|%@", name, sel];
        @synchronized (done) { if ([done containsObject:key]) continue; }
        IMP orig = NULL;
        if (XYDHookOnClass(c, s, newImp, &orig)) {
            @synchronized (done) { [done addObject:key]; }
            if (origMap && orig) [origMap setObject:[NSValue valueWithPointer:orig] forKey:c];
            XYD_LOG(@"hook -[%@ %@] ok", name, sel);
            any = YES;
        }
    }
    return any;
}

BOOL XYDClassContainingExists(NSArray<NSString *> *needles) {
    XYDEnsureClassList();
    @synchronized (XYDClassLock()) {
        for (int i = 0; i < gClassCount; i++) {
            if (gClassList[i] && XYDNameMatches(class_getName(gClassList[i]), needles)) return YES;
        }
    }
    return NO;
}

NSArray<NSString *> *XYDMatchingClassNames(NSArray<NSString *> *needles, NSUInteger limit) {
    XYDEnsureClassList();
    NSMutableArray *out = [NSMutableArray array];
    @synchronized (XYDClassLock()) {
        for (int i = 0; i < gClassCount && out.count < limit; i++) {
            Class c = gClassList[i];
            if (!c || !XYDNameMatches(class_getName(c), needles)) continue;
            NSString *n = NSStringFromClass(c);
            if (n) [out addObject:n];
        }
    }
    return out;
}

BOOL XYDAdClassesMissing(void) {
    BOOL splash = XYDClassExists(@"FMSplashModule") || XYDClassExists(@"IFMSplashModule");
    BOOL feed = XYDClassContainingExists(@[@"WaterfallItemCell", @"SingleRowItemCell"]);
    BOOL mine = XYDClassContainingExists(@[@"FloatingUserInfoContentView"]);
    return !(splash && feed && mine);
}

#pragma mark - url helpers

NSURL *XYDOriginalImageURL(NSURL *url) {
    if (!url) return nil;
    NSString *s = url.absoluteString;
    if (!s.length) return url;
    // alicdn: .../xxx.jpg_800x800q80.jpg  -> .../xxx.jpg
    //          .../xxx.jpg_.webp          -> .../xxx.jpg
    //          .../xxx.png_300x300.png    -> .../xxx.png
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"\\.(jpg|jpeg|png|heic|gif|webp)_[^/]*$"
                                                       options:NSRegularExpressionCaseInsensitive error:nil];
    });
    if (!re) return url;
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (m && m.numberOfRanges > 1) {
        NSString *base = [s substringToIndex:m.range.location];
        NSString *ext  = [s substringWithRange:[m rangeAtIndex:1]];
        NSString *fixed = [base stringByAppendingFormat:@".%@", ext];
        NSURL *u = [NSURL URLWithString:fixed];
        if (u) return u;
    }
    return url;
}

NSString *XYDExtractItemId(NSString *text) {
    if (!text.length) return nil;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"[?&#](?:id|itemId|item_id|itemID)=([0-9]{6,15})"
                                                       options:NSRegularExpressionCaseInsensitive error:nil];
    });
    if (re) {
        NSTextCheckingResult *m = [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
        if (m && m.numberOfRanges > 1) return [text substringWithRange:[m rangeAtIndex:1]];
    }
    NSString *trim = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trim.length >= 6 && trim.length <= 15) {
        NSCharacterSet *nonDigit = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        if ([trim rangeOfCharacterFromSet:nonDigit].location == NSNotFound) return trim;
    }
    return nil;
}
