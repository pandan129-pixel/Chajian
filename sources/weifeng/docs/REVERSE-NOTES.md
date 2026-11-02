# WeifengAdClean.dylib 逆向笔记

分析对象：`src/WeifengAdClean.orig.dylib`（从 `Payload/WeiFeng.app/Frameworks/` 提取）
（fat：arm64 `__text` @0x78e4 size 0x22364 / arm64e 另一份布局）
编译信息：`platform 2, minos 15.0, sdk 16.4`，ObjC + C++，无 Swift。

---

## 1. 字符串混淆

`strings` 全是 `J*i(8` 之类。真实逻辑：**每条字符串一个内联解密函数**。

```asm
; 例：0x1358c 解密 "WFAdCleanEnabled"
mov  x8, #0
loop:
  cmp  x8, #(LEN-1)
  b.eq done
  ldrb w10, [x0, x8]      ; enc[i]
  lsl  w11, w8, #5
  sub  w11, w11, w8
  add  w11, w11, #0x6d    ; K
  eor  w10, w10, w11
  strb w10, [x9, x8]
  add  x8, x8, #1
  b    loop
done:
  [NSString alloc] initWithBytes:len:encoding:NSUTF8StringEncoding
```

即：

```
decoded[i] = enc[i] ^ ((i * 31 + K) & 0xff)
```

- `K` 是每条字符串的立即数（0x01…0x7f 轮换）；
- 明文数据在 `__TEXT,__const`（0x2cb78 起，0x2d11 字节）；
- 调用点是 `adr x0, #<const>` + `bl <decryptor>`。

`tools/decode_strings.py` 自动扫 432 个解密函数 + 466 个调用点，全部还原。

---

## 2. 关键函数

| VA | 作用 |
|---|---|
| `0x78e4` | 构造函数（`__init_offsets`）。bundleId 校验 → 开关判断 → 装 hook |
| `0x8990` | `isAdCleanEnabled()`：`[defaults objectForKey:@"WFAdCleanEnabled"]`，nil 视为 YES |
| `0x8a88` | 组装 hook 描述数组（大量 `arrayWithObjects:`） |
| `0x13624` | `hookClassMethod(cls, sel, repl, orig)`（`class_getClassMethod` 存在才挂） |
| `0x15ee4` | `hookInstanceMethod(cls, sel, repl, orig)`（`class_getInstanceMethod` 存在才挂） |
| `0x13b8c` | `resolveClass(NSString*)`：先 `NSClassFromString`，失败再 `objc_lookUpClass(UTF8String)` |
| `0x267a4` | `showLearningNoticeIfNeeded()` ← **已 patch** |
| `0x270e0` / `0x27178` / `0x275fc` / `0x27694` / `0x2772c` / `0x277c4` / `0x1d3d8` | 各字符串解密器 |

### 构造函数流程

```
push autorelease pool
bundleId = [[NSBundle mainBundle] bundleIdentifier]
if (![bundleId isEqualToString:@"com.feng.New.WPForumClient"]) return
if (!isAdCleanEnabled()) return
... 逐条 NSSelectorFromString + hook ...
[NSNotificationCenter addObserverForName:UIApplicationDidBecomeActive ...]
[NSNotificationCenter addObserverForName:UIApplicationWillEnterForeground ...]
```

所有 hook 都先 `resolveClass` + `class_get*Method` 双重判空，**类/选择器不存在就跳过**，
这是它能直接跑在新版本上的原因。

---

## 3. 「学习声明」弹窗

`0x267a4`：

```
strb wzr, [x8, #0x278]                  ; 清 pending 标记
if (!isAdCleanEnabled()) return
if ([defaults boolForKey:@"WFAdCleanLearningNoticeShown_v1"]) return   ; 0x26830
... 组装 UIAlertController ...
   标题  : 学习声明
   正文  : 本插件仅供个人学习使用，如有传播请直接卸载！
   按钮1 : 我知道了        -> setBool:YES forKey:@"WFAdCleanLearningNoticeShown_v1"
   按钮2 : 一起学习交流    -> openURL: https://t.me/ylr155155
```

实测 prefs 里从来没有出现过这个 key，所以**每次启动都弹**。

Patch：

```
0x26830  14 1c 00 37   tbnz w20, #0, 0x26bb0
      -> e0 00 00 14   b 0x26bb0
```

`0x26bb0` 是栈保护校验 + 返回，所以等价于"永远不弹"。
同一函数内再没有第二处弹窗逻辑（`学习声明` 字符串只有这一个引用点）。

---

## 4. Hook 清单（解密后）

### 4.1 App 业务类（23 个）

```
WeiFeng.AdvertisingViewModel        WeiFeng.AdvertismentModel
WeiFeng.AppDelegate                 WeiFeng.BUAdTransitObject
WeiFeng.CollectionViewAdCell        WeiFeng.FlashAlertController
WeiFeng.FullScreenAdViewController  WeiFeng.GDTAdTransitObject
WeiFeng.ImageAdView                 WeiFeng.InsertBanner
WeiFeng.InsertList                  WeiFeng.NativeAdModel
WeiFeng.NativeBuAdTransitObject     WeiFeng.NativeGDTAdTransitObject
WeiFeng.NativeTurboAdTransitObject  WeiFeng.NewsFeedAdCell
WeiFeng.NewsInsertContentResponse   WeiFeng.PostDetailAdCell
WeiFeng.PostDetailAdCellModel       WeiFeng.SearchAdInfo
WeiFeng.SearchBannerAdCell          WeiFeng.ThreadFeedAdCell
WeiFeng.UserAdInfo
```

典型选择器：

```
layoutSubviews / didMoveToSuperview / viewDidAppear: / prefersStatusBarHidden
init                     (模型层，返回 nil)
application:didFinishLaunchingWithOptions:
nativeExpressAdDidLoad: / nativeExpressAdLoadFailed:error:
nativeExpressAdOnClicked: / nativeExpressAdOnClosed: / nativeExpressAdOnShow:
splashAdDidClose:closeType: / splashAdDidClick: / splashAdDidShow: ...
```

### 4.2 广告 SDK 类（45 个）

```
穿山甲 BU*   : BUSplashAd BUNativeAdsManager BUNativeExpressRewardedVideoAd
广点通 GDT/GM: GMSplashAd GMNativeAdsManager GMNativeExpressRewardedVideoAd
快手   KS*   : KSAdSDK（framework 内类）
阿里   ABU*  : ABUSplashAd ABUBannerAd ABUInterstitialAd ABURewardedVideoAd
               ABUNativeAdsManager
WindMill     : WindMillSplashAd / SplashAdManager / BannerView / BannerAdManager
               WindMillIntersititialAd / InterstitialAdManager
               WindMillRewardVideoAd / RewardVideoAdManager
               WindMillNativeAdsManager / PrivateNativeAdsManager
XAd          : XAdSplashAd XAdBannerAd XAdInterstitialAd XAdNativeAd
               XAdNativeExpressAd XAdOrdinaryVideoAd XAdRewardedVideoAd
               XAdWMNativeAd XAdCustom* XAdVideoPlayView ...
ADJg         : ADJgSDKSplashAd ADJgSDKBannerAdView ADJgSDKNativeAd
               ADJgSDKRewardvodAd ADJgSDKIntertitialAd
```

被 hook 的方法（节选）：

```
loadAd / loadAdData / loadAdData: / loadAdDataWithCount: / loadAdDataWithExtra:
loadAdAndShow / loadAdAndShowWithBottomView: / loadAdWithSlotID:
loadSplashAdWithSlotID:andParameter:
showAdInWindow: / showAdInWindow:title:desc: / showAdInWindow:withBottomView:
showSplashAdInWindow:parameter: / showSplashCardInRootVC:parameter:
showAdFromRootViewController:parameter: (+ adapter / ritScene 变体)
show / dismissSplashAd / removeSplashView
sdkInitWithParameter:success:failure:
requestAdSplashDataWithAdSlotId: / loadSplashAdWithAppId:andAdSlotId:
```

埋点上报（同样被吞掉）：

```
SDKReportWithV:andAppId:andThirdSlotId:
adMaterialReportWithObj:parameter: / adMaterialReportWithParameter:
adErrorReport:WithV:andAppId:andThirdSlotId:andAdStartTime:
adClickReportWithV:...requestId: (+extendedData:)
adShowReportWithV:...dspWinPrice:winPrice:extendedData:
mediaRequestReport / mediaRequestSuccessReportWithParameters:
mediaRequestsReportedWithParameters:
requestSuccessReportWithParameters: / requestFailureReportWithParameters:
sdkTrackPointReportWithParameters:success:failure:
sendWinNotificationReportWithWithParameters:
showReportWithWithParameters: / clickReportWithWithParameters:
adViewExposureReportEvent / dpStatusReportWithStatus:
videoAdPlayProgressReportWithProgress:
trackPointReport / trackadm / winnotice
```

### 4.3 网络层

```
[NSURL URLWithString:]                 -> 命中关键词则返回 [NSURL URLWithString:@"about:blank"]
[NSURL URLWithString:relativeToURL:]
[NSURLRequest requestWithURL:]
[NSMutableURLRequest requestWithURL:]
```

关键词：

```
advertisment advertisement advertise getadvert
adslot ad_pos adpos sdkad adsdk api/ad
/ad/ /ads/ /xad x-ad xads
trackadm trackpoint winnotice
showreport clickreport
requestsuccessreport requestfailurereport mediarequestsuccessreport
```

判定用 `rangeOfString:options:`（不区分大小写），命中即拦截。

### 4.4 其它

```
[NSUserDefaults standardUserDefaults] boolForKey:@"WFAdCleanEnabled"
NSLog  subsystem: com.local.weifeng-adclean   message: ad request blocked
广告占位识别字段: imageUrl / resourceUrl / jumpUrl / jumpDestination /
                 matSdkId / cellId / adModel / cellWidth / cellHeight / isNewsAd
splashAd / interstitialAd / SplashAd / InterstitialAd / FullScreenAd /
RewardedVideoAd / BannerAd / NativeAd / Advert
```

---

## 5. 7.1.1 vs 7.1.2

| 项 | 7.1.1 (IPA) | 7.1.2 (手机) |
|---|---|---|
| 主二进制 | arm64, 71.9 MB | arm64, 74.1 MB |
| `WeiFeng.PostDetailAdCell` | ✓ | ✓ |
| `WeiFeng.SearchBannerAdCell` | ✓ | ✓ |
| `WeiFeng.CollectionViewAdCell` | ✓ | ✓ |
| `WeiFeng.ThreadFeedAdCell` | ✓ | ✓ |
| `WeiFeng.NewsFeedAdCell` | ✓ | ✓ |
| `WeiFeng.FullScreenAdViewController` | ✓ | ✓ |
| `WeiFeng.AdvertisingViewModel` | ✓ | ✓ |
| `WeiFeng.NativeAdModel` / `AdvertismentModel` | ✓ | ✓ |
| `WeiFeng.SearchAdInfo` / `UserAdInfo` | ✓ | ✓ |
| `WeiFeng.PostDetailAdCellModel` | ✓ | ✓ |
| `WeiFeng.InsertBanner` / `InsertList` | ✓ | ✓ |
| `WeiFeng.NewsInsertContentResponse` | ✓ | ✓ |
| `WeiFeng.FlashAlertController` | ✓ | ✓ |

结论：类名完全一致，插件无需改选择器即可工作。
