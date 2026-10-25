#import "XYDCommon.h"
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>

#pragma mark - item

@implementation XYDMediaItem
- (instancetype)init {
    if ((self = [super init])) { _timestamp = [NSDate date]; }
    return self;
}
@end

#pragma mark - store

@interface XYDStore ()
@property (nonatomic, strong) NSMutableArray<XYDMediaItem *> *items;
@property (nonatomic, strong) NSMutableSet<NSString *> *keys;
@property (nonatomic) long long totalBytes;
@end

NSString *XYDCanonicalVideoKey(NSURL *url) {
    if (!url) return @"";
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!c) return url.absoluteString ?: @"";
    c.query = nil;
    c.fragment = nil;
    return c.URL.absoluteString ?: url.absoluteString ?: @"";
}

@implementation XYDStore

+ (instancetype)shared {
    static XYDStore *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [XYDStore new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _items = [NSMutableArray array];
        _keys = [NSMutableSet set];
        _onDetailPage = NO;
        _pageOpenTime = 0;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidEnterBackground)
                                                     name:UIApplicationDidEnterBackgroundNotification object:nil];
    }
    return self;
}

- (void)appDidEnterBackground {
    // 不自动退出 App（原存图插件有 AutoQuitBG，属于侵入行为，这里不做）
}

- (void)beginPage:(NSString *)itemId {
    self.onDetailPage = YES;
    self.pageOpenTime = [NSDate timeIntervalSinceReferenceDate];
    if (itemId.length && ![itemId isEqualToString:self.accountItemId ?: @""]) {
        self.accountItemId = itemId;
        [self resetForItem:itemId];
    } else if (itemId.length) {
        self.accountItemId = itemId;
    }
}

- (void)endPage {
    self.onDetailPage = NO;
    self.pageOpenTime = 0;
}

- (void)resetForItem:(NSString *)itemId {
    @synchronized (self) {
        self.accountItemId = itemId;
        [self.items removeAllObjects];
        [self.keys removeAllObjects];
        self.totalBytes = 0;
    }
}

- (BOOL)isCurrentItem:(NSString *)itemId {
    return itemId.length && [itemId isEqualToString:self.accountItemId ?: @""];
}

- (NSArray<XYDMediaItem *> *)snapshot {
    @synchronized (self) { return [self.items copy]; }
}

- (void)removeAll {
    @synchronized (self) {
        [self.items removeAllObjects];
        [self.keys removeAllObjects];
        self.totalBytes = 0;
    }
}

- (void)addItem:(XYDMediaItem *)item {
    if (!item.key.length) return;
    @synchronized (self) {
        if ([self.keys containsObject:item.key]) return;
        [self.keys addObject:item.key];
        [self.items addObject:item];
        self.totalBytes += item.byteSize;
        // 上限：120 条 / 180MB，超出按时间淘汰最旧
        while (self.items.count > 120 || self.totalBytes > 180LL * 1024 * 1024) {
            XYDMediaItem *old = self.items.firstObject;
            if (!old) break;
            self.totalBytes -= old.byteSize;
            [self.keys removeObject:old.key];
            [self.items removeObjectAtIndex:0];
        }
    }
}

- (void)addImageData:(NSData *)data {
    if (!XYDPrefBool(@"autoCapture", YES)) return;
    XYDStore *s = self;
    if (!s.onDetailPage) {
        // 页面出现前后 20 秒内的解码也算（详情页图片常在 viewDidAppear 之前开始）
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (!s.pageOpenTime || now - s.pageOpenTime > 20.0) return;
    }
    if (data.length < 4096) return;
    double minKB = XYDPrefDouble(@"minKB", 15);
    if (data.length < (NSUInteger)(minKB * 1024.0)) return;

    XYDMediaItem *it = [XYDMediaItem new];
    it.kind = XYDMediaKindPhoto;
    it.source = 2;
    it.data = data;
    it.byteSize = (long long)data.length;
    const uint8_t *p = data.bytes;
    it.key = [NSString stringWithFormat:@"%llu-%02x%02x%02x%02x",
              (unsigned long long)data.length, p[0], p[1], p[2], p[3]];

    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (src) {
        NSDictionary *props = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
        CGFloat w = [props[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
        CGFloat h = [props[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
        it.pixelSize = CGSizeMake(w, h);
        CFRelease(src);
        // 过滤广告物料/图标（极小图）
        if (w > 0 && h > 0 && (w < 80 || h < 80)) return;
    }
    double minPixel = XYDPrefDouble(@"minPixel", 300);
    if (it.pixelSize.width > 0 && it.pixelSize.height > 0 &&
        MAX(it.pixelSize.width, it.pixelSize.height) < minPixel) return;

    [self addItem:it];
}

- (void)addRemoteImageURL:(NSURL *)url pixel:(CGSize)pixel {
    if (!url) return;
    if (!XYDPrefBool(@"autoCapture", YES)) return;
    if (!self.onDetailPage) return;
    NSURL *orig = XYDOriginalImageURL(url);
    NSString *s = orig.absoluteString ?: @"";
    if (!s.length) return;
    if ([s containsString:@"BeiZiMaterial"] || [s containsString:@"/GDT"] ||
        [s containsString:@"AdMaterial"] || [s containsString:@"splash"] ||
        [s containsString:@"bu_template"]) return;
    XYDMediaItem *it = [XYDMediaItem new];
    it.kind = XYDMediaKindPhoto;
    it.source = 1;
    it.remoteURL = orig;
    it.pixelSize = pixel;
    it.key = s;
    [self addItem:it];
}

- (void)addLocalVideoURL:(NSURL *)url {
    if (!url) return;
    NSString *s = url.path;
    if (!s.length) return;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:s error:nil];
    long long size = [attrs[NSFileSize] longLongValue];
    if (size < 100 * 1024) return;
    XYDMediaItem *it = [XYDMediaItem new];
    it.kind = XYDMediaKindVideo;
    it.source = 3;
    it.localURL = url;
    it.byteSize = size;
    it.key = s;
    XYD_LOG(@"local video %@ (%lld)", s, size);
    [self addItem:it];
}

static BOOL XYDIsPlayableVideoURL(NSString *s);

- (void)addRemoteVideoURL:(NSURL *)url cover:(NSURL *)cover {
    if (!url) return;
    if (!XYDPrefBool(@"captureVideo", YES)) return;
    NSString *s = url.absoluteString ?: @"";
    if (!s.length) return;
    if (!XYDIsPlayableVideoURL(s)) return;
    NSString *ck = XYDCanonicalVideoKey(url);
    NSURL *cv = cover;
    @synchronized (self) {
        if (!cv) {
            for (XYDMediaItem *e in self.items) {
                if (e.kind == XYDMediaKindPhoto && e.remoteURL) { cv = e.remoteURL; break; }
            }
        }
        for (XYDMediaItem *e in self.items) {
            if (e.kind != XYDMediaKindVideo || !e.remoteURL) continue;
            if ([XYDCanonicalVideoKey(e.remoteURL) isEqualToString:ck]) {
                e.remoteURL = url;   // 刷新 auth_key
                if (!e.coverURL) e.coverURL = cv;
                return;
            }
        }
        if ([self.keys containsObject:ck]) return;
    }
    XYDMediaItem *it = [XYDMediaItem new];
    it.kind = XYDMediaKindVideo;
    it.source = 1;
    it.remoteURL = url;
    it.coverURL = cv;
    it.isVideoCover = NO;
    it.key = ck;
    XYD_LOG(@"video url captured %@", s);
    [self addItem:it];
}

@end

#pragma mark - capture hooks

static BOOL gCaptureReady = NO;
static dispatch_queue_t gCaptureQueue;
static id (*orig_imageWithData)(id, SEL, NSData *);
static id (*orig_imageWithDataScale)(id, SEL, NSData *, CGFloat);
static id (*orig_dataTaskReq)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
static id (*orig_dataTaskURL)(id, SEL, NSURL *, void (^)(NSData *, NSURLResponse *, NSError *));

static void XYDNoteRequestURL(NSURLRequest *req);
static BOOL XYDIsPlayableVideoURL(NSString *s) {
    if (!s.length) return NO;
    NSString *low = s.lowercaseString;
    // 绝不能把 MTOP/H5 API 自己当成视频地址
    if ([low containsString:@"h5api."] || [low containsString:@"mtop."] ||
        [low containsString:@"api="] || [low containsString:@"/h5/"]) return NO;
    if ([low containsString:@".mp4"] || [low containsString:@".mov"] || [low containsString:@".m3u8"]) return YES;
    if ([low containsString:@"cloud.video.taobao.com"] && [low containsString:@"/vod/"]) return YES;
    return NO;
}

static void XYDNoteVideoURL(NSURL *url) {
    if (!url) return;
    NSString *s = url.absoluteString;
    if (!XYDIsPlayableVideoURL(s)) return;
    if ([[XYDStore shared] onDetailPage]) [[XYDStore shared] addRemoteVideoURL:url cover:nil];
}

static id (*orig_playerItemURL)(id, SEL, NSURL *);
static id xyd_playerItemURL(id self, SEL _cmd, NSURL *url) {
    XYDNoteRequestURL([NSURLRequest requestWithURL:url]);
    XYDNoteVideoURL(url);
    return orig_playerItemURL ? orig_playerItemURL(self, _cmd, url) : nil;
}

static NSString *XYDRouterURLString(id obj);
static id (*orig_urlAsset)(id, SEL, NSURL *, id);
static void (*orig_loadVideoUrl)(id, SEL, id);
static void (*orig_setUrl)(id, SEL, id);
static void (*orig_setPlayUrl)(id, SEL, id);
static void (*orig_loadVideoId)(id, SEL, id, id, long long);

static void xyd_loadVideoUrl(id self, SEL _cmd, id url) {
    if (orig_loadVideoUrl) orig_loadVideoUrl(self, _cmd, url);
    NSString *s = XYDRouterURLString(url);
    if (s.length) { XYD_LOG(@"player url %@", s); XYDNoteVideoURL([NSURL URLWithString:s]); }
}

static void xyd_setUrl(id self, SEL _cmd, id url) {
    if (orig_setUrl) orig_setUrl(self, _cmd, url);
    NSString *s = XYDRouterURLString(url);
    if (s.length) { XYD_LOG(@"player setUrl %@", s); XYDNoteVideoURL([NSURL URLWithString:s]); }
}

static void xyd_setPlayUrl(id self, SEL _cmd, id url) {
    if (orig_setPlayUrl) orig_setPlayUrl(self, _cmd, url);
    NSString *s = XYDRouterURLString(url);
    if (s.length) { XYD_LOG(@"player playUrl %@", s); XYDNoteVideoURL([NSURL URLWithString:s]); }
}

static void xyd_loadVideoId(id self, SEL _cmd, id vid, id from, long long priority) {
    XYD_LOG(@"player loadVideoId %@ from=%@", vid, from);
    if (orig_loadVideoId) orig_loadVideoId(self, _cmd, vid, from, priority);
}
static id xyd_urlAsset(id self, SEL _cmd, NSURL *url, id options) {
    static __thread BOOL inAsset = NO;
    if (!inAsset) {
        inAsset = YES;
        XYDNoteVideoURL(url);
        inAsset = NO;
    }
    return orig_urlAsset ? orig_urlAsset(self, _cmd, url, options) : nil;
}

static void XYDScanVideoURLsInData(NSData *data) {
    if (!data.length || data.length > 512 * 1024) return;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (json) {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:json];
        NSInteger budget = 4000;
        while (stack.count && budget-- > 0) {
            id obj = stack.lastObject;
            [stack removeLastObject];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
                    NSString *key = [k isKindOfClass:[NSString class]] ? [k lowercaseString] : @"";
                    if ([v isKindOfClass:[NSString class]]) {
                        NSString *str = v;
                        NSString *low = str.lowercaseString;
                        BOOL keyHint = [key containsString:@"video"] || [key containsString:@"play"] || [key containsString:@"media"];
                        if ([low containsString:@".mp4"] || [low containsString:@".m3u8"] || [low containsString:@".mov"] ||
                            (keyHint && [low hasPrefix:@"http"])) {
                            if ([str hasPrefix:@"//"]) str = [@"https:" stringByAppendingString:str];
                            NSURL *u = [NSURL URLWithString:str];
                            if (u) XYDNoteVideoURL(u);
                        }
                    } else if ([v isKindOfClass:[NSDictionary class]] || [v isKindOfClass:[NSArray class]]) {
                        [stack addObject:v];
                    }
                }];
            } else if ([obj isKindOfClass:[NSArray class]]) {
                [stack addObjectsFromArray:obj];
            }
        }
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text.length) return;
    text = [text stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"https?://[^\"'<>\\s]+?\\.(?:mp4|mov|m3u8)(?:\\?[^\"'<>\\s]*)?" options:NSRegularExpressionCaseInsensitive error:nil];
    });
    if (!re) return;
    [re enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length) usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
        if (!m) return;
        NSURL *url = [NSURL URLWithString:[text substringWithRange:m.range]];
        if (url) XYDNoteVideoURL(url);
    }];
}

static BOOL XYDShouldCapture(void) {
    if (!XYDPrefBool(@"enabled", YES)) return NO;
    if (!XYDPrefBool(@"autoCapture", YES)) return NO;
    XYDStore *s = [XYDStore shared];
    if (s.onDetailPage) return YES;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    return s.pageOpenTime > 0 && now - s.pageOpenTime < 20.0;
}

static id xyd_imageWithData(id self, SEL _cmd, NSData *data) {
    id img = orig_imageWithData ? orig_imageWithData(self, _cmd, data) : nil;
    if (gCaptureReady && data.length && XYDShouldCapture()) {
        NSString *iid = [XYDStore shared].accountItemId;
        dispatch_async(gCaptureQueue, ^{
            XYDStore *st = [XYDStore shared];
            if (!iid.length || [st isCurrentItem:iid]) [st addImageData:data];
        });
    }
    return img;
}

static id xyd_imageWithDataScale(id self, SEL _cmd, NSData *data, CGFloat scale) {
    id img = orig_imageWithDataScale ? orig_imageWithDataScale(self, _cmd, data, scale) : nil;
    if (gCaptureReady && data.length && XYDShouldCapture()) {
        NSString *iid = [XYDStore shared].accountItemId;
        dispatch_async(gCaptureQueue, ^{
            XYDStore *st = [XYDStore shared];
            if (!iid.length || [st isCurrentItem:iid]) [st addImageData:data];
        });
    }
    return img;
}

static NSString *XYDItemIdFromRequest(NSURLRequest *req) {
    NSString *url = req.URL.absoluteString ?: @"";
    NSString *decoded = [url stringByRemovingPercentEncoding] ?: url;
    NSString *body = nil;
    if (req.HTTPBody.length && req.HTTPBody.length <= 256 * 1024)
        body = [[NSString alloc] initWithData:req.HTTPBody encoding:NSUTF8StringEncoding];
    NSArray *texts = @[url, decoded, body ?: @""];
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"itemId[\"'=:%2C%22\\s]*([0-9]{6,15})"
                                                       options:NSRegularExpressionCaseInsensitive error:nil];
    });
    for (NSString *t in texts) {
        if (!t.length) continue;
        NSString *iid = XYDExtractItemId(t);
        if (iid.length) return iid;
        if (re) {
            NSTextCheckingResult *m = [re firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
            if (m && m.numberOfRanges > 1) return [t substringWithRange:[m rangeAtIndex:1]];
        }
    }
    return nil;
}

static void XYDNoteRequestURL(NSURLRequest *req) {
    NSURL *url = req.URL;
    if (!url) return;
    NSString *s = req.URL.absoluteString;
    if (!s.length) return;
    NSString *low = s.lowercaseString;
    if ([low containsString:@"video"] || [low containsString:@"m3u8"]) {
        NSString *b = nil;
        if (req.HTTPBody.length && req.HTTPBody.length < 65536)
            b = [[NSString alloc] initWithData:req.HTTPBody encoding:NSUTF8StringEncoding];
        XYD_LOG(@"video request %@ body=%@", s, b ?: @"");
    }
    XYDStore *st = [XYDStore shared];

    // 用详情页自身的 API 请求作为“进入详情页”的可靠信号（Flutter 路由下 VC 回调不可靠）
    NSString *bodyStr = nil;
    if (req.HTTPBody.length && req.HTTPBody.length <= 256 * 1024)
        bodyStr = [[NSString alloc] initWithData:req.HTTPBody encoding:NSUTF8StringEncoding];
    NSString *decodedURL = [s stringByRemovingPercentEncoding] ?: s;
    BOOL hasItemId = ([s containsString:@"itemId"] || [decodedURL containsString:@"itemId"] ||
                      (bodyStr && [bodyStr containsString:@"itemId"]));
    BOOL detailAPI = [low containsString:@"idle.item"] || [low containsString:@"idle.pc"] ||
                     [low containsString:@"item.detail"] || [low containsString:@"itemdetail"] ||
                     [low containsString:@"xdetail"] || [low containsString:@"idle.detail"] ||
                     (hasItemId && [low containsString:@"detail"]);
    if (detailAPI) {
        XYD_LOG(@"net-detail-enter %@", url.host);
        NSString *iid = XYDItemIdFromRequest(req);
        XYD_LOG(@"net-detail-exit item=%@", iid);
        if (iid.length && ![st isCurrentItem:iid]) {
            [st beginPage:iid];
            XYD_LOG(@"network detail item=%@ url=%@", iid, url.host);
            if (XYDPrefBool(@"showBall", YES)) XYDInstallFloatingBall();
        }
    }
    if (!st.onDetailPage) return;
    if ([low containsString:@".mp4"] || [low containsString:@".mov"] ||
        [low containsString:@".m3u8"] || [low containsString:@"video" ]) {
        if ([low containsString:@"goofish.com"] || [low containsString:@"alicdn.com"] ||
            [low containsString:@"taobaocdn"] || [low containsString:@"tbcdn"] ||
            [low containsString:@"aliyuncs"]) {
            [st addRemoteVideoURL:url cover:nil];
        }
    }
}

static id xyd_dataTaskReq(id self, SEL _cmd, NSURLRequest *req, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    XYDNoteRequestURL(req);
    if (![XYDStore shared].onDetailPage) {
        return orig_dataTaskReq ? orig_dataTaskReq(self, _cmd, req, completion) : nil;
    }
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (resp) {
            NSString *mime = resp.MIMEType ?: @"";
            if ([mime hasPrefix:@"video/"] || [mime isEqualToString:@"application/octet-stream"]) {
                XYDNoteRequestURL([NSURLRequest requestWithURL:resp.URL]);
                XYDNoteVideoURL(resp.URL);
            }
            if ([XYDStore shared].onDetailPage && data.length < 512 * 1024) {
                XYDScanVideoURLsInData(data);
            }
        }
        if (completion) completion(data, resp, err);
    };
    return orig_dataTaskReq ? orig_dataTaskReq(self, _cmd, req, wrapped) : nil;
}

static id xyd_dataTaskURL(id self, SEL _cmd, NSURL *url, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    NSURLRequest *req = url ? [NSURLRequest requestWithURL:url] : nil;
    if (req) XYDNoteRequestURL(req);
    if (![XYDStore shared].onDetailPage) {
        return orig_dataTaskURL ? orig_dataTaskURL(self, _cmd, url, completion) : nil;
    }
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (resp) {
            NSString *mime = resp.MIMEType ?: @"";
            if ([mime hasPrefix:@"video/"] || [mime isEqualToString:@"application/octet-stream"]) {
                XYDNoteRequestURL([NSURLRequest requestWithURL:resp.URL]);
                XYDNoteVideoURL(resp.URL);
            }
            if ([XYDStore shared].onDetailPage && data.length < 512 * 1024) {
                XYDScanVideoURLsInData(data);
            }
        }
        if (completion) completion(data, resp, err);
    };
    return orig_dataTaskURL ? orig_dataTaskURL(self, _cmd, url, wrapped) : nil;
}

void XYDInstallPlayerHooks(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    XYDHookClass(@"AVPlayerItem", @"playerItemWithURL:", (IMP)xyd_playerItemURL, (IMP *)&orig_playerItemURL);
    XYDHookClass(@"AVURLAsset", @"URLAssetWithURL:options:", (IMP)xyd_urlAsset, (IMP *)&orig_urlAsset);
    XYDHookOnce(@"FMVideoPlayerViewAV", @"loadWithVideoUrl:", (IMP)xyd_loadVideoUrl, (IMP *)&orig_loadVideoUrl);
    XYDHookOnce(@"FMVideoPlayerViewTB", @"loadWithVideoUrl:", (IMP)xyd_loadVideoUrl, NULL);
    XYDHookOnce(@"FishVideoPlayerView", @"setUrl:", (IMP)xyd_setUrl, (IMP *)&orig_setUrl);
    XYDHookOnce(@"FMVideoPlayerService", @"setPlayUrl:", (IMP)xyd_setPlayUrl, (IMP *)&orig_setPlayUrl);
    XYDHookOnce(@"FMVideoPlayerViewAV", @"loadWithVideoId:from:priority:", (IMP)xyd_loadVideoId, (IMP *)&orig_loadVideoId);
    XYDHookOnce(@"FMVideoPlayerViewTB", @"loadWithVideoId:from:priority:", (IMP)xyd_loadVideoId, NULL);
}

void XYDInstallOptionalHooks(void) {
    XYDInstallPlayerHooks();
    XYDHookClass(@"AVPlayerItem", @"playerItemWithURL:", (IMP)xyd_playerItemURL, (IMP *)&orig_playerItemURL);
}

void XYDInstallCapture(void) {
    if (gCaptureReady) return;
    gCaptureReady = YES;
    if (!gCaptureQueue) gCaptureQueue = dispatch_queue_create("com.pandan.xianyuduo.capture", DISPATCH_QUEUE_SERIAL);

    XYDHookClass(@"UIImage", @"imageWithData:", (IMP)xyd_imageWithData, (IMP *)&orig_imageWithData);
    XYDHookClass(@"UIImage", @"imageWithData:scale:", (IMP)xyd_imageWithDataScale, (IMP *)&orig_imageWithDataScale);

    // NSURLSession 是 class cluster：同时 hook 基类与运行时具体类
    XYDHookOnce(@"NSURLSession", @"dataTaskWithRequest:completionHandler:",
                    (IMP)xyd_dataTaskReq, (IMP *)&orig_dataTaskReq);
    XYDHookOnce(@"NSURLSession", @"dataTaskWithURL:completionHandler:",
                    (IMP)xyd_dataTaskURL, (IMP *)&orig_dataTaskURL);

    XYDInstallOptionalHooks();
    dispatch_async(dispatch_get_main_queue(), ^{
        Class concrete = object_getClass([NSURLSession sharedSession]);
        if (concrete && concrete != [NSURLSession class]) {
            NSString *cname = NSStringFromClass(concrete);
            if (!XYDHookOnce(cname, @"dataTaskWithRequest:completionHandler:",
                             (IMP)xyd_dataTaskReq, NULL)) {
                XYD_LOG(@"concrete session class %@ hook skipped", cname);
            }
            XYDHookOnce(cname, @"dataTaskWithURL:completionHandler:", (IMP)xyd_dataTaskURL, NULL);
        }
    });
}

#pragma mark - context hooks

static void (*orig_detailAppear)(id, SEL, BOOL);
static BOOL (*orig_routerOpen)(id, SEL, id, id, id);
static BOOL (*orig_routerOpen4)(id, SEL, id, id, id, id);
static BOOL (*orig_routerSafeOpen)(id, SEL, id, id, id, id);
static BOOL XYDIsDetailContainer(id self);
static BOOL XYDIsDetailPageName(NSString *pageName, NSString *spmUrl);
static void (*orig_detailDidLoad)(id, SEL);
static void (*orig_detailWillAppear)(id, SEL, BOOL);
static void (*orig_flutterWillAppear)(id, SEL, BOOL);
static void (*orig_flutterDisappear)(id, SEL, BOOL);
static void (*orig_flutterDidDisappear)(id, SEL, BOOL);
static void (*orig_detailDisappear)(id, SEL, BOOL);
static void (*orig_detailDidDisappear)(id, SEL, BOOL);
static void (*orig_flutterAppear)(id, SEL, BOOL);

static id XYDReadObjectIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable([obj class], name);
    if (!iv) return nil;
    ptrdiff_t off = ivar_getOffset(iv);
    size_t size = class_getInstanceSize([obj class]);
    if (off <= 0 || (size_t)off >= size) return nil;
    return object_getIvar(obj, iv);
}

static NSString *XYDStringFromValue(id v) {
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSURL class]]) return [(NSURL *)v absoluteString];
    return nil;
}

static NSString *iidFromDigits(NSString *s);

static NSString *XYDItemIdFromQueryObject(id query) {
    if ([query isKindOfClass:[NSString class]]) return XYDExtractItemId(query);
    if ([query isKindOfClass:[NSURL class]]) return XYDExtractItemId([(NSURL *)query absoluteString]);
    if ([query isKindOfClass:[NSDictionary class]]) {
        for (NSString *k in @[@"id", @"itemId", @"item_id", @"itemID", @"targetId"]) {
            id v = ((NSDictionary *)query)[k];
            NSString *s = XYDStringFromValue(v);
            if (s.length && [s rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location != NSNotFound) {
                return iidFromDigits(s);
            }
        }
        for (id v in ((NSDictionary *)query).allValues) {
            NSString *s = XYDStringFromValue(v);
            if (s.length) {
                NSString *iid = XYDExtractItemId(s);
                if (iid.length) return iid;
            }
        }
    }
    return nil;
}

static NSString *iidFromDigits(NSString *s) {
    static NSRegularExpression *re; static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"\\b(\\d{6,15})\\b" options:0 error:nil];
    });
    if (re) {
        NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
        if (m) return [s substringWithRange:[m rangeAtIndex:1]];
    }
    return nil;
}

static NSString *XYDItemIdFromDetailVC(id vc) {
    if (!vc) return nil;
    id ctx = XYDReadObjectIvar(vc, "detailContext");
    if (ctx) {
        // 只走 KVC：Swift 计算属性/结构体 ivar 直接读会拿到非对象指针
        for (NSString *key in @[@"routerURL", @"routerQuery", @"routerCombinedParams"]) {
            @try {
                id v = [ctx valueForKey:key];
                NSString *iid = XYDItemIdFromQueryObject(v);
                if (iid.length) return iid;
            } @catch (__unused NSException *e) {}
        }
    }
    for (NSString *key in @[@"routerURL", @"routerQuery"]) {
        @try {
            id v = [vc valueForKey:key];
            NSString *iid = XYDItemIdFromQueryObject(v);
            if (iid.length) return iid;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

static NSString *XYDRouterURLString(id obj) {
    if ([obj isKindOfClass:[NSURL class]]) return [(NSURL *)obj absoluteString];
    if ([obj isKindOfClass:[NSString class]]) return obj;
    for (NSString *k in @[@"urlString", @"url", @"h5Url"]) {
        @try {
            id v = [obj valueForKey:k];
            if ([v isKindOfClass:[NSString class]]) return v;
            if ([v isKindOfClass:[NSURL class]]) return [(NSURL *)v absoluteString];
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

static void XYDNoteRoute(id urlObj, id query, id params, const char *where) {
    NSString *s = XYDRouterURLString(urlObj);
    if (!s.length) return;
    BOOL itemRoute = [s.lowercaseString containsString:@"item"] || [s.lowercaseString containsString:@"detail"];
    if (!itemRoute) return;
    NSString *iid = XYDExtractItemId(s);
    if (!iid.length) iid = XYDItemIdFromQueryObject(query);
    if (!iid.length) iid = XYDItemIdFromQueryObject(params);
    NSURL *u = [NSURL URLWithString:s];
    NSString *host = u.host.lowercaseString ?: @"";
    BOOL nonDetail = [host isEqualToString:@"home"] || [host isEqualToString:@"message"] ||
                     [host isEqualToString:@"x_chat"] || [host isEqualToString:@"account"] ||
                     [host isEqualToString:@"personalpage"] || [host isEqualToString:@"publishentry"] ||
                     [s.lowercaseString containsString:@"personal-home"];
    XYD_LOG(@"router(%s) %@ item=%@ nonDetail=%d", where, s, iid, nonDetail);
    if (nonDetail) {
        [[XYDStore shared] endPage];
        XYDUninstallFloatingBall();
        return;
    }
    if (iid.length) {
        [[XYDStore shared] beginPage:iid];
        if (XYDPrefBool(@"showBall", YES)) XYDInstallFloatingBall();
    }
}

static BOOL xyd_routerOpen(id self, SEL _cmd, id url, id query, id params) {
    BOOL ok = orig_routerOpen ? orig_routerOpen(self, _cmd, url, query, params) : NO;
    XYDNoteRoute(url, query, params, "open3");
    return ok;
}

static BOOL xyd_routerOpen4(id self, SEL _cmd, id url, id query, id params, id uid) {
    BOOL ok = orig_routerOpen4 ? orig_routerOpen4(self, _cmd, url, query, params, uid) : NO;
    XYDNoteRoute(url, query, params, "open4");
    return ok;
}

static BOOL xyd_routerSafeOpen(id self, SEL _cmd, id url, id query, id params, id uid) {
    BOOL ok = orig_routerSafeOpen ? orig_routerSafeOpen(self, _cmd, url, query, params, uid) : NO;
    XYDNoteRoute(url, query, params, "safe");
    return ok;
}

static BOOL XYDIsDetailContainer(id self) {
    NSString *name = NSStringFromClass([self class]) ?: @"";
    if ([name containsString:@"XDetail"]) return YES;
    if ([name containsString:@"PCNoTrack"]) return YES;
    return NO;
}

static BOOL XYDIsDetailPageName(NSString *pageName, NSString *spmUrl) {
    NSString *p = [pageName isKindOfClass:[NSString class]] ? pageName.lowercaseString : @"";
    NSString *u = [spmUrl isKindOfClass:[NSString class]] ? spmUrl.lowercaseString : @"";
    if ([p containsString:@"detail"] || [p containsString:@"item"]) return YES;
    if ([u containsString:@"/item"] || [u containsString:@"item?id"] || [u containsString:@"xdetail"]) return YES;
    return NO;
}

static void xyd_detailDidLoad(id self, SEL _cmd) {
    XYD_LOG(@"enter detailDidLoad");
    if (orig_detailDidLoad) orig_detailDidLoad(self, _cmd);
    XYD_LOG(@"exit detailDidLoad");
    if (XYDPrefBool(@"showBall", YES)) XYDInstallFloatingBall();
}

static void xyd_detailWillAppear(id self, SEL _cmd, BOOL animated) {
    XYD_LOG(@"enter detailWillAppear");
    if (orig_detailWillAppear) orig_detailWillAppear(self, _cmd, animated);
    XYD_LOG(@"exit detailWillAppear");
    XYDStore *st = [XYDStore shared];
    if (st.accountItemId.length) [st beginPage:st.accountItemId];
    if (XYDPrefBool(@"showBall", YES)) XYDInstallFloatingBall();
}

static void xyd_flutterWillAppear(id self, SEL _cmd, BOOL animated) {
    XYD_LOG(@"enter flutterWillAppear %@", NSStringFromClass([self class]));
    if (orig_flutterWillAppear) orig_flutterWillAppear(self, _cmd, animated);
    XYD_LOG(@"exit flutterWillAppear %@", NSStringFromClass([self class]));
    NSString *page = nil;
    @try { page = [self valueForKey:@"pageName"]; } @catch (__unused NSException *e) {}
    if (![page isKindOfClass:[NSString class]]) page = nil;
    XYD_LOG(@"flutter willAppear %@ page=%@", NSStringFromClass([self class]), page);
    if (XYDIsDetailPageName(page, nil)) {
        NSString *iid = XYDExtractItemId(page);
        if (iid.length) [[XYDStore shared] beginPage:iid];
        if (XYDPrefBool(@"showBall", YES)) XYDInstallFloatingBall();
        XYD_LOG(@"flutter willAppear detail item=%@", iid);
    }
}

static void xyd_detailAppear(id self, SEL _cmd, BOOL animated) {
    XYD_LOG(@"enter detailAppear");
    if (orig_detailAppear) orig_detailAppear(self, _cmd, animated);
    XYD_LOG(@"exit detailAppear");
    XYDInstallPlayerHooks();
    XYDStore *st = [XYDStore shared];
    if (st.accountItemId.length) [st beginPage:st.accountItemId];
    if (XYDPrefBool(@"showBall", YES)) XYDInstallFloatingBall();
}

static void xyd_detailDisappear(id self, SEL _cmd, BOOL animated) {
    if (orig_detailDisappear) orig_detailDisappear(self, _cmd, animated);
    XYD_LOG(@"detail willDisappear");
}

static void xyd_detailDidDisappear(id self, SEL _cmd, BOOL animated) {
    if (orig_detailDidDisappear) orig_detailDidDisappear(self, _cmd, animated);
    UIViewController *vc = [self isKindOfClass:[UIViewController class]] ? (UIViewController *)self : nil;
    BOOL leaving = vc.isMovingFromParentViewController || vc.isBeingDismissed ||
                   (vc.navigationController && vc.navigationController.isBeingDismissed);
    if (!leaving) {
        XYD_LOG(@"detail didDisappear (pushed/modal) keep ball");
        return;
    }
    XYD_LOG(@"detail didDisappear -> remove ball");
    XYDUninstallFloatingBall();
    [[XYDStore shared] endPage];
}

static void xyd_flutterAppear(id self, SEL _cmd, BOOL animated) {
    XYD_LOG(@"enter flutterAppear %@", NSStringFromClass([self class]));
    if (orig_flutterAppear) orig_flutterAppear(self, _cmd, animated);
    XYD_LOG(@"exit flutterAppear %@", NSStringFromClass([self class]));
    NSString *page = nil;
    @try { page = [self valueForKey:@"pageName"]; } @catch (__unused NSException *e) {}
    if (![page isKindOfClass:[NSString class]]) page = nil;
    XYD_LOG(@"flutter appear %@ page=%@", NSStringFromClass([self class]), page);
    if (XYDIsDetailPageName(page, nil)) {
        NSString *iid = XYDExtractItemId(page);
        if (iid.length) [[XYDStore shared] beginPage:iid];
        if (XYDPrefBool(@"showBall", YES)) XYDInstallFloatingBall();
        XYD_LOG(@"flutter appear detail item=%@", iid);
    }
}

static void xyd_flutterDisappear(id self, SEL _cmd, BOOL animated) {
    if (orig_flutterDisappear) orig_flutterDisappear(self, _cmd, animated);
}

static void xyd_flutterDidDisappear(id self, SEL _cmd, BOOL animated) {
    if (orig_flutterDidDisappear) orig_flutterDidDisappear(self, _cmd, animated);
    if (!XYDIsDetailContainer(self)) return;
    XYD_LOG(@"flutter didDisappear -> remove ball");
    XYDUninstallFloatingBall();
    [[XYDStore shared] endPage];
}

void XYDInstallContext(void) {
    // 只 hook 明确存在的“页面生命周期”方法；不碰 init/路由 setter（之前踩过 ARC 返回值与递归的坑）
    if (!XYDHookOnce(@"XDetailViewController", @"viewDidLoad", (IMP)xyd_detailDidLoad, (IMP *)&orig_detailDidLoad)) {
        XYD_LOG(@"XDetailViewController not found (app version?)");
    }
    XYDHookOnce(@"XDetailViewController", @"viewWillAppear:", (IMP)xyd_detailWillAppear, (IMP *)&orig_detailWillAppear);
    XYDHookOnce(@"XDetailViewController", @"viewDidAppear:", (IMP)xyd_detailAppear, (IMP *)&orig_detailAppear);
    XYDHookOnce(@"XDetailViewController", @"viewWillDisappear:", (IMP)xyd_detailDisappear, (IMP *)&orig_detailDisappear);
    XYDHookOnce(@"XDetailViewController", @"viewDidDisappear:", (IMP)xyd_detailDidDisappear, (IMP *)&orig_detailDidDisappear);
    XYDHookOnce(@"FM3FlutterViewContainer", @"viewWillAppear:", (IMP)xyd_flutterWillAppear, (IMP *)&orig_flutterWillAppear);
    XYDHookOnce(@"FM3FlutterViewContainer", @"viewDidAppear:", (IMP)xyd_flutterAppear, (IMP *)&orig_flutterAppear);
    XYDHookOnce(@"FM3FlutterViewContainer", @"viewWillDisappear:", (IMP)xyd_flutterDisappear, (IMP *)&orig_flutterDisappear);
    XYDHookOnce(@"FM3FlutterViewContainer", @"viewDidDisappear:", (IMP)xyd_flutterDidDisappear, (IMP *)&orig_flutterDidDisappear);

    // 商品页路由：所有手动点击/外链最终都会走 FMURLRouter；只读 URL，不碰 Flutter 路由 setter
    XYDHookOnce(@"FMURLRouter", @"openURL:withQuery:withParams:", (IMP)xyd_routerOpen, (IMP *)&orig_routerOpen);
    XYDHookOnce(@"FMURLRouter", @"openURL:withQuery:withParams:withUniqueid:", (IMP)xyd_routerOpen4, (IMP *)&orig_routerOpen4);
    XYDHookClass(@"FMURLRouter", @"safeOpenURL:withQuery:withParams:withUniqueid:", (IMP)xyd_routerSafeOpen, (IMP *)&orig_routerSafeOpen);
}


void XYDScanVideoCache(void) {
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableArray<NSString *> *dirs = [NSMutableArray array];
        NSString *caches = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"];
        [dirs addObject:caches];
        NSString *tmp = NSTemporaryDirectory();
        if (tmp.length) [dirs addObject:tmp];
        // 常见播放器缓存目录
        [dirs addObject:[caches stringByAppendingPathComponent:@"AliyunPlayer"]];
        [dirs addObject:[caches stringByAppendingPathComponent:@"com.taobao.fleamarket"]];
        NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-1800];
        NSMutableArray<NSDictionary *> *found = [NSMutableArray array];
        NSInteger budget = 6000;
        for (NSString *dir in dirs) {
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;
            NSDirectoryEnumerator *e = [fm enumeratorAtPath:dir];
            for (NSString *rel in e) {
                if (budget-- <= 0) break;
                NSString *ext = rel.pathExtension.lowercaseString;
                if (![ext isEqualToString:@"mp4"] && ![ext isEqualToString:@"mov"]) continue;
                NSString *full = [dir stringByAppendingPathComponent:rel];
                NSDictionary *a = [e fileAttributes];
                NSDate *m = a[NSFileModificationDate];
                if (m && [m compare:cutoff] == NSOrderedAscending) continue;
                long long size = [a[NSFileSize] longLongValue];
                if (size < 200 * 1024) continue;
                [found addObject:@{@"path": full, @"mtime": m ?: [NSDate date], @"size": @(size)}];
                if (found.count >= 30) break;
            }
            if (found.count >= 30) break;
        }
        [found sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"mtime"] compare:a[@"mtime"]];
        }];
        for (NSDictionary *d in found) {
            [[XYDStore shared] addLocalVideoURL:[NSURL fileURLWithPath:d[@"path"]]];
        }
    }
}
