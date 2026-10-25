#import "XYDCommon.h"
#import <string.h>
#import <AVFoundation/AVFoundation.h>

static dispatch_queue_t gSaveQueue;
static BOOL gPermissionRequested = NO;

static void XYDEnsurePermission(void (^done)(BOOL ok)) {
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    if (!info[@"NSPhotoLibraryAddUsageDescription"] && !info[@"NSPhotoLibraryUsageDescription"]) {
        XYD_LOG(@"host app has no photo library usage description");
        done(NO);
        return;
    }
    PHAuthorizationStatus st = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
    if (st == PHAuthorizationStatusAuthorized || st == PHAuthorizationStatusLimited) { done(YES); return; }
    if (st == PHAuthorizationStatusDenied || st == PHAuthorizationStatusRestricted) { done(NO); return; }
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus s) {
        dispatch_async(dispatch_get_main_queue(), ^{
            done(s == PHAuthorizationStatusAuthorized || s == PHAuthorizationStatusLimited);
        });
    }];
}

static void XYDDownload(NSURL *url, void (^done)(NSData *data, NSError *err)) {
    if (!url) { done(nil, [NSError errorWithDomain:@"xyd" code:10 userInfo:@{NSLocalizedDescriptionKey:@"空 URL"}]); return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 30;
    [req setValue:@"https://h5.m.goofish.com/" forHTTPHeaderField:@"Referer"];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        forHTTPHeaderField:@"User-Agent"];
    NSURLSession *s = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    [[s dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err || data.length == 0) done(nil, err ?: [NSError errorWithDomain:@"xyd" code:11
                userInfo:@{NSLocalizedDescriptionKey:@"下载失败"}]);
            else done(data, nil);
        });
    }] resume];
    [s finishTasksAndInvalidate];
}

static NSString *XYDTempPath(NSString *name) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"xyd-media"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:name];
}

static BOOL XYDDataLooksLikeWebP(NSData *d) {
    if (d.length < 12) return NO;
    const uint8_t *p = d.bytes;
    return memcmp(p, "RIFF", 4) == 0 && memcmp(p + 8, "WEBP", 4) == 0;
}

static NSData *XYDConvertToJPEG(NSData *data) {
    UIImage *img = [UIImage imageWithData:data];
    if (!img) return nil;
    return UIImageJPEGRepresentation(img, 0.95);
}

static NSString *XYDImageExtension(NSData *data) {
    if (!data.length) return @"jpg";
    const uint8_t *p = data.bytes;
    if (data.length >= 3 && p[0] == 0xFF && p[1] == 0xD8) return @"jpg";
    if (data.length >= 8 && memcmp(p, "\x89PNG\r\n\x1a\n", 8) == 0) return @"png";
    if (data.length >= 12 && memcmp(p, "GIF8", 4) == 0) return @"gif";
    if (data.length >= 12 && memcmp(p, "RIFF", 4) == 0 && memcmp(p + 8, "WEBP", 4) == 0) return @"webp";
    if (data.length >= 12 && memcmp(p + 4, "ftypheic", 8) == 0) return @"heic";
    return @"jpg";
}

static void XYDSavePhotoData(NSData *data, void (^done)(BOOL ok, NSError *err)) {
    if (!data.length) { done(NO, nil); return; }
    if (XYDDataLooksLikeWebP(data)) {
        NSData *jpeg = XYDConvertToJPEG(data);
        if (jpeg) data = jpeg;
    }
    NSString *ext = XYDImageExtension(data);
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        PHAssetCreationRequest *r = [PHAssetCreationRequest creationRequestForAsset];
        PHAssetResourceCreationOptions *o = [PHAssetResourceCreationOptions new];
        o.originalFilename = [NSString stringWithFormat:@"xyd-%@.%@", [[NSUUID UUID] UUIDString], ext];
        [r addResourceWithType:PHAssetResourceTypePhoto data:data options:o];
    } completionHandler:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(success, error); });
    }];
}

static void XYDSaveVideoData(NSData *data, NSString *ext, void (^done)(BOOL ok, NSError *err)) {
    if (!data.length) { done(NO, nil); return; }
    NSString *path = XYDTempPath([NSString stringWithFormat:@"%@.%@", [[NSUUID UUID] UUIDString], ext ?: @"mp4"]);
    NSError *we = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&we]) { done(NO, we); return; }
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        PHAssetCreationRequest *r = [PHAssetCreationRequest creationRequestForAsset];
        PHAssetResourceCreationOptions *o = [PHAssetResourceCreationOptions new];
        o.originalFilename = [path lastPathComponent];
        [r addResourceWithType:PHAssetResourceTypeVideo fileURL:fileURL options:o];
    } completionHandler:^(BOOL success, NSError *error) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ done(success, error); });
    }];
}

static void XYDExportHLS(NSURL *url, void (^done)(NSURL *file, NSError *err)) {
    NSString *ua = @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    headers[@"Referer"] = @"https://h5.m.goofish.com/";
    headers[@"User-Agent"] = ua;
    NSString *cookie = @"";
    NSMutableArray *parts = [NSMutableArray array];
    for (NSHTTPCookie *c in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies]) {
        NSString *dom = c.domain.lowercaseString ?: @"";
        if ([dom containsString:@"goofish"] || [dom containsString:@"taobao"])
            [parts addObject:[NSString stringWithFormat:@"%@=%@", c.name, c.value]];
    }
    cookie = [parts componentsJoinedByString:@"; "];
    if (cookie.length) headers[@"Cookie"] = cookie;

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{@"AVURLAssetHTTPHeaderFieldsKey": headers}];
    AVAssetExportSession *ex = [AVAssetExportSession exportSessionWithAsset:asset presetName:AVAssetExportPresetHighestQuality];
    if (!ex) { done(nil, [NSError errorWithDomain:@"xyd" code:20 userInfo:@{NSLocalizedDescriptionKey:@"无法创建导出任务"}]); return; }
    NSString *path = XYDTempPath([NSString stringWithFormat:@"%@.mp4", [[NSUUID UUID] UUIDString]]);
    ex.outputURL = [NSURL fileURLWithPath:path];
    ex.outputFileType = AVFileTypeMPEG4;
    ex.shouldOptimizeForNetworkUse = YES;
    [ex exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ex.status == AVAssetExportSessionStatusCompleted) done(ex.outputURL, nil);
            else done(nil, ex.error ?: [NSError errorWithDomain:@"xyd" code:21 userInfo:@{NSLocalizedDescriptionKey:@"视频导出失败"}]);
        });
    }];
}

static void XYDSaveLive(NSData *imageData, NSData *videoData, void (^done)(BOOL ok, NSError *err)) {
    NSString *vid = XYDTempPath([NSString stringWithFormat:@"%@.mov", [[NSUUID UUID] UUIDString]]);
    if (![videoData writeToFile:vid options:NSDataWritingAtomic error:nil]) { done(NO, nil); return; }
    NSURL *vu = [NSURL fileURLWithPath:vid];
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        PHAssetCreationRequest *r = [PHAssetCreationRequest creationRequestForAsset];
        PHAssetResourceCreationOptions *o = [PHAssetResourceCreationOptions new];
        o.originalFilename = [NSString stringWithFormat:@"xyd-%@.%@", [[NSUUID UUID] UUIDString], XYDImageExtension(imageData)];
        [r addResourceWithType:PHAssetResourceTypePhoto data:imageData options:o];
        PHAssetResourceCreationOptions *vo = [PHAssetResourceCreationOptions new];
        vo.originalFilename = [vid lastPathComponent];
        [r addResourceWithType:PHAssetResourceTypePairedVideo fileURL:vu options:vo];
    } completionHandler:^(BOOL success, NSError *error) {
        [[NSFileManager defaultManager] removeItemAtPath:vid error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ done(success, error); });
    }];
}

void XYDSaveMediaItems(NSArray<XYDMediaItem *> *items,
                       void (^progress)(NSInteger, NSInteger, NSString *),
                       void (^completion)(NSInteger, NSInteger, NSString *)) {
    if (!items.count) { if (completion) completion(0, 0, @"没有选择媒体"); return; }
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gSaveQueue = dispatch_queue_create("com.pandan.xianyuduo.save", DISPATCH_QUEUE_SERIAL); });

    XYDEnsurePermission(^(BOOL ok) {
        if (!ok) { if (completion) completion(0, (NSInteger)items.count, @"没有相册写入权限"); return; }
        NSMutableArray *queue = [items mutableCopy];
        __block NSInteger saved = 0, failed = 0;
        __block void (^next)(void);
        next = ^{
            if (!queue.count) {
                if (completion) completion(saved, failed, nil);
                next = nil;
                return;
            }
            XYDMediaItem *it = queue.firstObject;
            [queue removeObjectAtIndex:0];
            NSInteger total = (NSInteger)items.count;
            if (progress) progress(saved + failed, total, nil);

            void (^finish)(BOOL, NSError *) = ^(BOOL success, NSError *err) {
                if (success) saved++; else { failed++; XYD_LOG(@"save failed: %@", err); }
                if (progress) progress(saved + failed, total, success ? nil : (err.localizedDescription ?: @"保存失败"));
                if (next) next();
            };

            if (it.data.length) {
                if (it.kind == XYDMediaKindPhoto) XYDSavePhotoData(it.data, finish);
                else XYDSaveVideoData(it.data, @"mp4", finish);
                return;
            }
            if (it.localURL) {
                NSData *d = [NSData dataWithContentsOfURL:it.localURL];
                if (it.kind == XYDMediaKindPhoto) XYDSavePhotoData(d, finish);
                else XYDSaveVideoData(d, it.localURL.pathExtension ?: @"mp4", finish);
                return;
            }
            if (it.remoteURL) {
                if (it.kind == XYDMediaKindPhoto) {
                    XYDDownload(it.remoteURL, ^(NSData *d, NSError *e) {
                        if (!d) { finish(NO, e); return; }
                        // 原图失败则尝试去掉尺寸后缀的 URL
                        XYDSavePhotoData(d, finish);
                    });
                } else if ([it.remoteURL.pathExtension.lowercaseString isEqualToString:@"m3u8"]) {
                    XYDExportHLS(it.remoteURL, ^(NSURL *file, NSError *e) {
                        if (!file) { finish(NO, e); return; }
                        NSData *d = [NSData dataWithContentsOfURL:file];
                        [[NSFileManager defaultManager] removeItemAtURL:file error:nil];
                        if (!d.length) { finish(NO, e); return; }
                        XYDSaveVideoData(d, @"mp4", finish);
                    });
                } else {
                    XYDDownload(it.remoteURL, ^(NSData *d, NSError *e) {
                        if (!d) { finish(NO, e); return; }
                        NSString *ext = it.remoteURL.pathExtension.lowercaseString;
                        if (![ext isEqualToString:@"mp4"] && ![ext isEqualToString:@"mov"]) ext = @"mp4";
                        XYDSaveVideoData(d, ext, finish);
                    });
                }
                return;
            }
            finish(NO, nil);
        };
        dispatch_async(dispatch_get_main_queue(), ^{ if (next) next(); });
    });
}
