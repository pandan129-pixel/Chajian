// XYDCommon.h — 闲鱼助手+存图 融合版（单 dylib，纯 ObjC）
// 目标：com.taobao.fleamarket / iOS 15+ / roothide arm64e
#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define XYD_LOG(fmt, ...) do { if (XYDPrefBool(@"debug", NO)) XYDLog((fmt), ##__VA_ARGS__); } while (0)

FOUNDATION_EXPORT void XYDLog(NSString *fmt, ...);

// ---------------- prefs ----------------
FOUNDATION_EXPORT NSDictionary *XYDPrefsAll(void);
FOUNDATION_EXPORT BOOL   XYDPrefBool(NSString *key, BOOL def);
FOUNDATION_EXPORT double XYDPrefDouble(NSString *key, double def);
NSString *XYDPrefString(NSString *key, NSString *def);
FOUNDATION_EXPORT void   XYDSetPref(NSString *key, id value);
FOUNDATION_EXPORT void   XYDSyncPrefs(void);
FOUNDATION_EXPORT void   XYDDefaultsIfNeeded(void);
FOUNDATION_EXPORT void   XYDRefreshPrefs(void);

// ---------------- runtime hooks ----------------
BOOL XYDClassExists(NSString *name);
BOOL XYDHookInstance(NSString *cls, NSString *sel, IMP newImp, IMP *outOrig);
BOOL XYDHookClass(NSString *cls, NSString *sel, IMP newImp, IMP *outOrig);
BOOL XYDHookOnce(NSString *cls, NSString *sel, IMP newImp, IMP *outOrig);
BOOL XYDHookFirst(NSArray<NSString *> *classes, NSString *sel, IMP newImp, IMP *outOrig);
BOOL XYDHookAllSubclassesOf(Class base, NSArray<NSString *> *needles, NSString *sel, IMP newImp, NSMapTable *origMap);
BOOL XYDClassContainingExists(NSArray<NSString *> *needles);
NSArray<NSString *> *XYDMatchingClassNames(NSArray<NSString *> *needles, NSUInteger limit);
void XYDInvalidateClassCache(void);
BOOL XYDAdClassesMissing(void);
BOOL XYDClassHasMethod(NSString *cls, NSString *sel);

// ---------------- media model ----------------
typedef NS_ENUM(NSInteger, XYDMediaKind) {
    XYDMediaKindPhoto = 0,
    XYDMediaKindVideo = 1,
};

@interface XYDMediaItem : NSObject
@property (nonatomic) XYDMediaKind kind;
@property (nonatomic) NSInteger source;             // 1=remote 2=decoded
@property (nonatomic, copy)   NSString *key;        // dedup key
@property (nonatomic, strong) NSURL *remoteURL;
@property (nonatomic, strong) NSURL *coverURL;      // 视频封面（一般是首图）
@property (nonatomic, strong) NSData *data;         // captured original bytes (photos)
@property (nonatomic, strong) NSURL *localURL;      // temp file for video
@property (nonatomic) CGSize pixelSize;
@property (nonatomic) long long byteSize;
@property (nonatomic) BOOL isVideoCover;
@property (nonatomic, strong) NSDate *timestamp;
@end

// ---------------- shared store ----------------
@interface XYDStore : NSObject
+ (instancetype)shared;
@property (atomic, copy) NSString *accountItemId;
@property (atomic) BOOL onDetailPage;
@property (atomic) NSTimeInterval pageOpenTime;
- (void)beginPage:(NSString *)itemId;
- (void)endPage;
- (NSArray<XYDMediaItem *> *)snapshot;
- (void)resetForItem:(NSString *)itemId;
- (void)addImageData:(NSData *)data;
- (void)addRemoteImageURL:(NSURL *)url pixel:(CGSize)pixel;
- (void)addRemoteVideoURL:(NSURL *)url cover:(NSURL *)cover;
- (void)removeAll;
- (BOOL)isCurrentItem:(NSString *)itemId;
@end

// ---------------- capture ----------------
void XYDInstallCapture(void);
void XYDScanVideoCache(void);
void XYDInstallOptionalHooks(void);
void XYDInstallPlayerHooks(void);
NSString *XYDCanonicalVideoKey(NSURL *url);
void XYDInstallContext(void);

// ---------------- ad block ----------------
void XYDInstallAdBlock(void);
void XYDInstallSplashHooks(void);
void XYDInstallFeedHooks(void);
void XYDApplyAdPrefs(void);
void XYDScanAndHideAds(UIView *root);

// ---------------- item api ----------------
void XYDFetchVideoURL(NSString *videoId, void (^completion)(NSURL *url, NSError *err));
void XYDFetchItemMedia(NSString *itemId, void (^completion)(NSArray<XYDMediaItem *> *items, NSString *title, NSError *error));

// ---------------- save ----------------
void XYDSaveMediaItems(NSArray<XYDMediaItem *> *items,
                       void (^progress)(NSInteger done, NSInteger total, NSString *status),
                       void (^completion)(NSInteger saved, NSInteger failed, NSString *message));

// ---------------- ui ----------------
@interface XYDPanelVC : UIViewController
- (instancetype)initWithItemId:(NSString *)itemId;
@property (nonatomic, copy) NSString *itemId;
@property (nonatomic) BOOL startOnSettings;
@end

@interface XYDSettingsVC : UIViewController
@end

void XYDInstallEntry(void);
void XYDInstallFloatingBall(void);
void XYDUninstallFloatingBall(void);
void XYDShowToast(NSString *text);
UIViewController *XYDTopViewController(void);

// ---------------- url helpers ----------------
NSURL *XYDOriginalImageURL(NSURL *url);
NSString *XYDExtractItemId(NSString *text);
