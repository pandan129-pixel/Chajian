#import "XYDCommon.h"
#import <CommonCrypto/CommonDigest.h>

static NSString *const kXYDAppKey = @"12574478";
static NSString *const kXYDApi    = @"mtop.taobao.idle.item.info";
static NSCache<NSString *, NSArray *> *gAPICache;

static NSString *XYDMD5(NSString *s) {
    const char *c = s.UTF8String ?: "";
    unsigned char d[CC_MD5_DIGEST_LENGTH];
    CC_MD5(c, (CC_LONG)strlen(c), d);
    NSMutableString *m = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [m appendFormat:@"%02x", d[i]];
    return m;
}

static NSString *XYDCookieHeader(void) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSHTTPCookie *c in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies]) {
        NSString *dom = c.domain.lowercaseString ?: @"";
        if (![dom containsString:@"goofish"] && ![dom containsString:@"taobao"]) continue;
        if (!c.name.length || !c.value.length) continue;
        [parts addObject:[NSString stringWithFormat:@"%@=%@", c.name, c.value]];
    }
    return [parts componentsJoinedByString:@"; "];
}

static NSString *XYDToken(void) {
    NSString *best = nil;
    for (NSHTTPCookie *c in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies]) {
        if (![c.name isEqualToString:@"_m_h5_tk"] || c.value.length <= 10) continue;
        NSString *dom = c.domain.lowercaseString ?: @"";
        if (![dom containsString:@"goofish"] && ![dom containsString:@"taobao"]) continue;
        if (!best || c.value.length > best.length) best = c.value;
    }
    if (!best) return nil;
    NSRange r = [best rangeOfString:@"_"];
    return r.location == NSNotFound ? best : [best substringToIndex:r.location];
}

static BOOL XYDIsImageURLString(NSString *s) {
    NSString *l = s.lowercaseString;
    return [l containsString:@".jpg"] || [l containsString:@".jpeg"] || [l containsString:@".png"] ||
           [l containsString:@".heic"] || [l containsString:@".webp"] || [l containsString:@".gif"];
}

static NSArray<NSString *> *XYDCollectKeys(NSDictionary *dict, NSString *needle) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *k in dict) {
        if ([k.lowercaseString containsString:needle]) [out addObject:k];
    }
    return out;
}

static void XYDParseItemJSON(NSDictionary *json, NSString *fallbackItemId,
                             NSArray<XYDMediaItem *> **outItems, NSString **outTitle) {
    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSDictionary *data = json[@"data"];
    if (![data isKindOfClass:[NSDictionary class]]) data = json;
    NSDictionary *itemDO = data[@"itemDO"];
    if (![itemDO isKindOfClass:[NSDictionary class]]) itemDO = data;
    NSDictionary *item = itemDO[@"item"];
    if (![item isKindOfClass:[NSDictionary class]]) item = data[@"item"];
    if (![item isKindOfClass:[NSDictionary class]]) item = itemDO;

    NSString *title = item[@"title"] ?: itemDO[@"title"] ?: data[@"title"];
    if (![title isKindOfClass:[NSString class]]) title = nil;

    NSMutableArray *dicts = [NSMutableArray array];
    void (^addArray)(id) = ^(id arr) {
        if (![arr isKindOfClass:[NSArray class]]) return;
        for (id o in arr) {
            if ([o isKindOfClass:[NSDictionary class]]) [dicts addObject:o];
            else if ([o isKindOfClass:[NSString class]] && XYDIsImageURLString(o)) {
                [dicts addObject:@{@"url": o}];
            }
        }
    };
    addArray(item[@"imageInfos"]);
    addArray(itemDO[@"imageInfoDOList"]);
    addArray(itemDO[@"imageInfos"]);
    addArray(item[@"images"]);
    addArray(data[@"imageInfos"]);

    for (NSDictionary *d in dicts) {
        NSString *url = nil;
        for (NSString *k in @[@"url",@"absoluteMajorPicture",@"majorUrl",@"major",@"imageUrl",@"picUrl",@"originUrl",@"hdUrl"]) {
            id v = d[k];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 8) { url = v; break; }
        }
        if (!url) continue;
        if ([url hasPrefix:@"//"]) url = [@"https:" stringByAppendingString:url];
        NSURL *u = [NSURL URLWithString:url];
        if (!u) continue;
        NSURL *orig = XYDOriginalImageURL(u);
        NSString *key = orig.absoluteString;
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        XYDMediaItem *it = [XYDMediaItem new];
        it.kind = XYDMediaKindPhoto;
        it.source = 1;
        it.remoteURL = orig;
        it.key = key;
        CGFloat w = [d[@"width"] doubleValue];
        CGFloat h = [d[@"height"] doubleValue];
        if (h <= 0) { w = [d[@"widthSize"] doubleValue]; h = [d[@"heightSize"] doubleValue]; }
        it.pixelSize = CGSizeMake(w, h);
        [items addObject:it];
    }

    // 视频：遍历 JSON 找字符串型 mp4/mov 字段（迭代，避免递归 block 开销）
    __block NSString *videoURL = nil;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:data];
    NSInteger budget = 5000;
    while (stack.count && budget-- > 0) {
        id obj = stack.lastObject;
        [stack removeLastObject];
        if ([obj isKindOfClass:[NSDictionary class]]) {
            [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
                if (videoURL) { *stop = YES; return; }
                if ([v isKindOfClass:[NSString class]]) {
                    NSString *l = [(NSString *)v lowercaseString];
                    // 只认真正的视频域名，绝不能把 img.alicdn 的封面图当视频
                    if ([v hasPrefix:@"http"] &&
                        ([l containsString:@"video.goofish.com"] || [l containsString:@"cloud.video.taobao.com/vod/"])) {
                        videoURL = v;
                    }
                } else if ([v isKindOfClass:[NSDictionary class]] || [v isKindOfClass:[NSArray class]]) {
                    [stack addObject:v];
                }
            }];
        } else if ([obj isKindOfClass:[NSArray class]]) {
            [stack addObjectsFromArray:obj];
        }
        if (videoURL) break;
    }
    if (videoURL) {
        NSURL *u = [NSURL URLWithString:videoURL];
        if (u) {
            XYD_LOG(@"api video %@", videoURL);
            XYDMediaItem *it = [XYDMediaItem new];
            it.kind = XYDMediaKindVideo;
            it.source = 1;
            it.remoteURL = u;
            it.coverURL = items.count ? [(XYDMediaItem *)items.firstObject remoteURL] : nil;
            it.key = XYDCanonicalVideoKey(u);
            [items addObject:it];
        }
    }

    if (outItems) *outItems = items;
    if (outTitle) *outTitle = title;
}

static NSURLSession *XYDAPISession(void) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 12;
        cfg.timeoutIntervalForResource = 18;
        cfg.HTTPCookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        cfg.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
        cfg.HTTPShouldSetCookies = YES;
        session = [NSURLSession sessionWithConfiguration:cfg];
    });
    return session;
}

static NSURL *XYDAPIURLFor(NSString *api, NSString *dataStr, NSString *token, NSString *t) {
    NSURLComponents *comp = [NSURLComponents componentsWithString:
        [NSString stringWithFormat:@"https://h5api.m.goofish.com/h5/%@/1.0/", api]];
    NSMutableArray *q = [NSMutableArray arrayWithArray:@[
        [NSURLQueryItem queryItemWithName:@"jsv" value:@"2.7.2"],
        [NSURLQueryItem queryItemWithName:@"appKey" value:kXYDAppKey],
        [NSURLQueryItem queryItemWithName:@"t" value:t],
        [NSURLQueryItem queryItemWithName:@"api" value:api],
        [NSURLQueryItem queryItemWithName:@"v" value:@"1.0"],
        [NSURLQueryItem queryItemWithName:@"type" value:@"originaljson"],
        [NSURLQueryItem queryItemWithName:@"dataType" value:@"json"],
        [NSURLQueryItem queryItemWithName:@"timeout" value:@"20000"],
        [NSURLQueryItem queryItemWithName:@"data" value:dataStr],
    ]];
    if (token.length) {
        NSString *sign = XYDMD5([NSString stringWithFormat:@"%@&%@&%@&%@", token, t, kXYDAppKey, dataStr]);
        [q insertObject:[NSURLQueryItem queryItemWithName:@"sign" value:sign] atIndex:3];
    }
    comp.queryItems = q;
    return comp.URL;
}

static void XYDAPICall(NSString *api, NSString *dataStr, NSString *token, NSInteger attempt,
                       void (^done)(NSDictionary *json, NSError *err)) {
    NSString *t = [NSString stringWithFormat:@"%lld", (long long)([[NSDate date] timeIntervalSince1970] * 1000)];
    NSURL *url = XYDAPIURLFor(api, dataStr, token, t);
    if (!url) { done(nil, [NSError errorWithDomain:@"xyd" code:3 userInfo:@{NSLocalizedDescriptionKey:@"URL 构造失败"}]); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 12;
    [req setValue:@"https://h5.m.goofish.com/" forHTTPHeaderField:@"Referer"];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    NSString *cookie = XYDCookieHeader();
    if (cookie.length) [req setValue:cookie forHTTPHeaderField:@"Cookie"];

    [[XYDAPISession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data.length) { done(nil, err ?: [NSError errorWithDomain:@"xyd" code:5 userInfo:@{NSLocalizedDescriptionKey:@"网络失败"}]); return; }
        NSError *jerr = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jerr];
        if (![json isKindOfClass:[NSDictionary class]]) { done(nil, jerr ?: [NSError errorWithDomain:@"xyd" code:6 userInfo:@{NSLocalizedDescriptionKey:@"响应解析失败"}]); return; }
        NSArray *ret = ((NSDictionary *)json)[@"ret"];
        NSString *retStr = [ret isKindOfClass:[NSArray class]] ? [ret componentsJoinedByString:@","] : @"";
        if ([retStr containsString:@"SUCCESS"]) { done(json, nil); return; }
        if (!token.length && attempt < 2) {
            NSString *newToken = XYDToken();
            if (newToken.length) { XYDAPICall(api, dataStr, newToken, attempt + 1, done); return; }
        } else if (attempt < 2 && ([retStr containsString:@"TOKEN"] || [retStr containsString:@"SIGN"])) {
            XYDAPICall(api, dataStr, nil, attempt + 1, done);
            return;
        }
        done(nil, [NSError errorWithDomain:@"xyd" code:4
                                 userInfo:@{NSLocalizedDescriptionKey: retStr.length ? retStr : @"MTOP 返回异常"}]);
    }] resume];
}

static NSString *XYDFindVideoId(id obj) {
    NSMutableArray *stack = [NSMutableArray arrayWithObject:obj ?: @{}];
    NSInteger budget = 3000;
    while (stack.count && budget-- > 0) {
        id o = stack.lastObject;
        [stack removeLastObject];
        if ([o isKindOfClass:[NSDictionary class]]) {
            id v = ((NSDictionary *)o)[@"videoId"];
            if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
            if ([v isKindOfClass:[NSString class]] && [v length]) return v;
            for (id x in ((NSDictionary *)o).allValues) {
                if ([x isKindOfClass:[NSDictionary class]] || [x isKindOfClass:[NSArray class]]) [stack addObject:x];
            }
        } else if ([o isKindOfClass:[NSArray class]]) {
            [stack addObjectsFromArray:o];
        }
    }
    return nil;
}

static NSURL *XYDFindVideoURL(id obj) {
    NSMutableArray *stack = [NSMutableArray arrayWithObject:obj ?: @{}];
    NSInteger budget = 5000;
    while (stack.count && budget-- > 0) {
        id o = stack.lastObject;
        [stack removeLastObject];
        if ([o isKindOfClass:[NSDictionary class]]) {
            for (id k in (NSDictionary *)o) {
                id v = ((NSDictionary *)o)[k];
                if ([v isKindOfClass:[NSString class]]) {
                    NSString *low = [v lowercaseString];
                    if ([low containsString:@".mp4"] || [low containsString:@".m3u8"] || [low containsString:@".mov"]) {
                        NSString *s = v;
                        if ([s hasPrefix:@"//"]) s = [@"https:" stringByAppendingString:s];
                        return [NSURL URLWithString:s];
                    }
                } else if ([v isKindOfClass:[NSDictionary class]] || [v isKindOfClass:[NSArray class]]) {
                    [stack addObject:v];
                }
            }
        } else if ([o isKindOfClass:[NSArray class]]) {
            [stack addObjectsFromArray:o];
        }
    }
    return nil;
}

void XYDFetchVideoURL(NSString *videoId, void (^completion)(NSURL *url, NSError *err)) {
    if (!videoId.length) { completion(nil, nil); return; }
    NSString *dataStr = [NSString stringWithFormat:
        @"{\"playScene\":\"xianyu\",\"from\":\"XLivePhoto\",\"videoId\":\"%@\",\"expectedCode\":\"\"}", videoId];
    XYDAPICall(@"mtop.idle.cloud.video.query", dataStr, XYDToken(), 0, ^(NSDictionary *json, NSError *err) {
        if (!json) { XYD_LOG(@"video query fail: %@", err.localizedDescription); completion(nil, err); return; }
        NSURL *u = XYDFindVideoURL(json[@"data"]);
        XYD_LOG(@"video query ok url=%@", u);
        completion(u, u ? nil : err);
    });
}

void XYDFetchItemMedia(NSString *itemId, void (^completion)(NSArray<XYDMediaItem *> *, NSString *, NSError *)) {
    if (!completion) return;
    if (!itemId.length) {
        completion(@[], nil, [NSError errorWithDomain:@"xyd" code:1 userInfo:@{NSLocalizedDescriptionKey:@"缺少商品 ID"}]);
        return;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gAPICache = [NSCache new]; gAPICache.countLimit = 8; });

    NSArray *cached = [gAPICache objectForKey:itemId];
    if (cached) { completion(cached, nil, nil); return; }

    NSString *dataStr = [NSString stringWithFormat:@"{\"itemId\":\"%@\"}", itemId];
    XYDAPICall(kXYDApi, dataStr, XYDToken(), 0, ^(NSDictionary *json, NSError *err) {
        if (!json) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], nil, err); });
            return;
        }
        NSArray *items = @[]; NSString *title = nil;
        XYDParseItemJSON(json, itemId, &items, &title);
        NSString *videoId = XYDFindVideoId(json[@"data"]);
        void (^finish)(NSArray *) = ^(NSArray *all) {
            if (all.count) [gAPICache setObject:all forKey:itemId];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(all, title, nil); });
        };
        if (!videoId.length || !XYDPrefBool(@"videoQuery", NO)) { finish(items); return; }
        XYDFetchVideoURL(videoId, ^(NSURL *vu, NSError *ve) {
            NSMutableArray *all = [items mutableCopy];
            if (vu) {
                XYDMediaItem *v = [XYDMediaItem new];
                v.kind = XYDMediaKindVideo;
                v.source = 1;
                v.remoteURL = vu;
                v.coverURL = items.count ? [(XYDMediaItem *)items.firstObject remoteURL] : nil;
                v.key = XYDCanonicalVideoKey(vu);
                [all addObject:v];
            }
            finish(all);
        });
    });
}
