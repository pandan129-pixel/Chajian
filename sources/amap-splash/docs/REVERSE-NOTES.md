# 逆向笔记：WKK 高德 NoAds 为什么失效，以及 17.02.1 的新开屏链路

## 1. 样本

| 项 | 值 |
|----|----|
| 文件 | `高德地图.dylib`（微信附件） |
| sha256 | `548d398b7c31c3a7350401d517d1353f33d753549961dd28409012fdbf1d1e7c` |
| 大小 | 105,875 B |
| 架构 | thin **arm64e** |
| Mach-O | dylib，`LC_ID_DYLIB` = `@rpath/xxhook.dylib`，min iOS 15.0 |
| 依赖 | CydiaSubstrate、Foundation/UIKit/QuartzCore/CoreGraphics |
| 符号 | 只导入 `MSHookMessageEx`，无 `MSHookFunction` |
| 段 | `__text` 仅 0xB64 (2,916 B)，`__cstring` 0x1C0，`__objc_methname` 0x3E3 |

同一文件也出现在 WKK 1.1-3 的 `pkgmirror` 里：

```
com.wkk.gaodehook_1.1-3_iphoneos-arm64e.deb
  data.tar.zst : var/mobile/Library/pkgmirror/.../高德地图去广告.dylib  (105875, 同 sha256)
com.wkk.gaodehook_1.1-3_iphoneos-arm64.deb
  data.tar.xz  : var/jb/Library/MobileSubstrate/DynamicLibraries/高德地图去广告.dylib (105875)
```

**注意**：两个 deb 的 `Architecture` 分别写 `iphoneos-arm64e` / `iphoneos-arm64`，
但解包后的 dylib 都是 **thin arm64e**。`lipo -info` 已确认。

## 2. 原始实现结构

一个 constructor（`__text+0x0`）线性展开 52 次：

```
objc_getClass("WINSplashScreenPresenter") -> x19
MSHookMessageEx(objc_getClass(...), @selector(...), (IMP)&replacement, &orig_slot)
```

* 类名来自 `__cstring`（24 个类）
* selector 来自 `__objc_selrefs`（arm64e chained fixup，取低 43 位）
* 替换函数全部是无参数 stub：`ret` / `return nil` / `return NO` / `return @"2"` / tail-call 原实现
* 唯一特殊点：`WINSplashScreenPresenter` 的 `resourceAvalible:presentType:` 是通过
  `object_getClass()` 取元类后挂的，即 **类方法 `+resourceAvalible:presentType:`**

用 `tools/hookmap.py` 可以完整还原这张表；`src/hooks_generated.h` 就是产物。

## 3. 原始 52 条 hook 表

| # | class | selector | 原实现语义 | 17.02.1 |
|---|-------|----------|-----------|---------|
| 1 | `WINAJXVideoAuthorModule` | `hideSplashView` | void | OK |
| 2 | `WINAJXShortVideoModule` | `hideSplashView` | void | OK |
| 3 | `WINSplashScreenPresenter` | `resourceAvalible:presentType:` | pass-through | MISSING_SEL |
| 4 | `WINSplashScreenPresenter` | `splashView` | pass-through | OK |
| 5 | `WINSplashScreenPresenter` | `setSplashView:` | void | OK |
| 6 | `WINSplashScreenPresenter` | `animationFinishBlock` | pass-through | OK |
| 7 | `WINSplashScreenPresenter` | `setAnimationFinishBlock:` | void | OK |
| 8 | `WINSplashScreenPresenter` | `presentData:background:sreenData:error:` | void | MISSING_SEL |
| 9 | `WINSplashScreenPresenter` | `setPlayfinishBlock:` | void | OK |
| 10 | `WINSplashScreenPresenter` | `countForToday` | pass-through | MISSING_SEL |
| 11 | `WINSplashScreenPresenter` | `lastShowTime` | pass-through | MISSING_SEL |
| 12 | `WINSplashScreenPresenter` | `topViewDataValid:` | call-orig | MISSING_SEL |
| 13 | `WINSplashScreenPresenter` | `initFlashViewWithImageData:localPath:creative:ad:sessionId:` | void | MISSING_SEL |
| 14 | `WINSplashScreenPresenter` | `initFlashViewWithVideoPath:creative:ad:sessionId:` | void | MISSING_SEL |
| 15 | `WINSplashScreenPresenter` | `saveNowTimeStamp:` | void | MISSING_SEL |
| 16 | `WINSplashScreenPresenter` | `currentCreative` | pass-through | OK |
| 17 | `WINSplashScreenPresenter` | `currentAd` | pass-through | MISSING_SEL |
| 18 | `WINSplashScreenPresenter` | `setEverShowed:` | void | OK |
| 19 | `WINSplashScreenPresenter` | `counterdown` | pass-through | OK |
| 20 | `WINSplashScreenPresenter` | `setCounterdown:` | void | OK |
| 21 | `WINSplashScreenPresenter` | `maxShowToday` | pass-through | MISSING_SEL |
| 22 | `WINSplashScreenPresenter` | `setMaxShowToday:` | void | MISSING_SEL |
| 23 | `WINSplashScreenPresenter` | `areaButtonClicked:` | void | OK |
| 24 | `WINSplashScreenPresenter` | `viewDidFinishedRender:` | void | OK |
| 25 | `WINSplashScreenPresenter` | `isShowing` | pass-through | OK |
| 26 | `WINSplashScreenPresenter` | `setShowing:` | void | OK |
| 27 | `WINSplashScreenPresenter` | `setSkipTimer:` | void | OK |
| 28 | `FLPatch` | `apiVersion` | return-2-string | MISSING_CLASS |
| 29 | `WINSplashView` | `initWithFrame:` | nil | OK |
| 30 | `NMMessageTipView` | `initWithFrame:` | nil | OK |
| 31 | `WINQuickSearchBar` | `setPlaceholderLab:` | void | MISSING_CLASS |
| 32 | `WINQuickSearchBar` | `setScanBtn:` | void | MISSING_CLASS |
| 33 | `WINWeatherDataProvider` | `fetchWeatherDataWithImageStandard:completion:` | void | OK |
| 34 | `WINScaleLineLogoMapWidget` | `showLogoViewAndHideScaleLine` | void | OK |
| 35 | `LTMVUIFloatingView` | `initWithFrame:delegate:` | nil | MISSING_SEL |
| 36 | `NMLoginCheckManager` | `showTestFlightAMapUpgradeAlertWithInfo:` | void | MISSING_SEL |
| 37 | `NMLoginCheckManager` | `checkTestFlightAMapUpgradeConfig` | void | MISSING_SEL |
| 38 | `AMapLauncherConfig` | `isTestFlightChannel` | NO | OK |
| 39 | `AMapLauncherConfig` | `isTestFlightVersion` | NO | OK |
| 40 | `NMBasemapConfig` | `isTestFlightInstalled` | NO | OK |
| 41 | `NMBadgeButton` | `setShouldShowBadge:` | nil | MISSING_CLASS |
| 42 | `NMMainLayertNormalView` | `redPointView` | nil | MISSING_CLASS |
| 43 | `WINZoomInOutView` | `initWithFrame:` | nil | OK |
| 44 | `WINOperationWidgetView` | `loadViewWithType` | void | OK |
| 45 | `WINOperationWidgetView` | `widgetShowType` | nil | OK |
| 46 | `LTMVersionUpgradeAlertView` | `init` | nil | OK |
| 47 | `WINTabBarItem` | `showBadgeWithNumber:` | pass-through | MISSING_SEL |
| 48 | `WINTabBarItem` | `showBadgeWithText:` | void | MISSING_SEL |
| 49 | `WINTabBarItem` | `hasBadge` | NO | MISSING_SEL |
| 50 | `WINSplashScreenData` | `setAd:` | void | OK |
| 51 | `WINGroupMapWidget` | `addSubWidgetWithTag:widget:` | void | OK |
| 52 | `AJXImageView` | `setDelegate:` | call-orig | OK |

## 4. 17.02.1 运行期清点

`src/amapdiag.m` 注入到 `.20` 上的高德 17.02.1（`CFBundleVersion 17.02.1.2004`，
主程序 `AMapiPhone` 为 **ARM64**），在 constructor 里向 ObjC runtime 提问：

```
summary ok=30 missing_class=5 missing_sel=17
```

仍然存在的 30 条大多是 UI 清理项（`NMMessageTipView`、`WINZoomInOutView`、
`WINOperationWidgetView`、`LTMVersionUpgradeAlertView`、TestFlight 开关等）。

失效的 22 条几乎全部集中在**开屏核心**：

| 被移除的类 | 说明 |
|-----------|------|
| `FLPatch` | 补丁/开关类，已不存在 |
| `WINQuickSearchBar` | 搜索栏，已不存在 |
| `NMBadgeButton` | 角标按钮，已不存在 |
| `NMMainLayertNormalView` | 首页图层，已不存在 |

| 被改名/移除的方法（`WINSplashScreenPresenter`） | 17.02.1 对应 |
|-----------------------------------------------|-------------|
| `resourceAvalible:presentType:` | 不再存在（类方法也一起没） |
| `presentData:background:sreenData:error:` | → `presentSplashScreenWithData:scene:fromBackground:otherInfo:filteringSuccessBlock:filteringFailureBlock:playFinishBlock:animationFinishBlock:` |
| `initFlashViewWithImageData:localPath:creative:ad:sessionId:` | → `WINSplashView -showWithImageData:localPath:creative:` |
| `initFlashViewWithVideoPath:creative:ad:sessionId:` | → `WINSplashView -showVideoWithLocalPath:creative:` |
| `countForToday` / `lastShowTime` / `maxShowToday` / `setMaxShowToday:` | 频控逻辑下沉/改名，已无这些 selector |
| `topViewDataValid:` / `saveNowTimeStamp:` / `currentAd` | 已移除 |
| `LTMVUIFloatingView -initWithFrame:delegate:` | 已移除 |
| `NMLoginCheckManager` 两个 TestFlight 方法 | 已移除 |
| `WINTabBarItem` 三个角标方法 | 已移除 |

## 5. 两个根因

1. **架构不匹配（决定性）**
   高德主程序是 `ARM64`，WKK 的 dylib 是 thin `arm64e`。dyld 不会把 arm64e 镜像
   加载进 arm64 进程，所以这个包在新版上等于没装。旧版能“感觉有效”，很可能是当时
   用了 TrollFools 之类的注入方式或不同包体，不能作为现在可用的依据。

2. **开屏 API 整体重写**
   即使把架构补成 fat，原表的 17 个 selector 也已经不存在。新版把开屏拆成了
   `WINSplashScreenVAppService`（调度/频控/占位） + `WINSplashScreenPresenter`
   （展示/动画/跳转） + `WINSplashView`（图片/视频渲染） + `WINSplashScreenData`
   （creative/ad 数据），入口方法全部换名。

## 6. 17.02.1 新链路（运行时确认）

关键方法（含 `method_getTypeEncoding`，用于确认返回值）：

```
+[WINSplashScreenVAppService shouldSplashScreenShow:launchCheck:]   B28@0:8^@16B24
+[WINSplashScreenVAppService enableXDays]                           B16@0:8
-[WINSplashScreenVAppService isLocalSplashDataCanExposure]          @16@0:8
-[WINSplashScreenVAppService checkAndShowRealtimeFlashView:]        v24@0:8Q16
-[WINSplashScreenVAppService checkAndShowLocalRealtimeAndPreloadFlashView:] v24@0:8Q16
-[WINSplashScreenVAppService checkAndShowPreloadFlashView:otherInfo:]       v32@0:8Q16@24
-[WINSplashScreenVAppService checkAndShowLocalRealtimeFlashView:data:otherInfo:] v40@0:8Q16@24@32
-[WINSplashScreenPresenter presentSplashScreenWithData:scene:fromBackground:otherInfo:filteringSuccessBlock:filteringFailureBlock:playFinishBlock:animationFinishBlock:]
                                                                    v76@0:8@16Q24B32@36@?44@?52@?60@?68
-[WINSplashScreenPresenter presentRealTimeSplashScreen:scene:customFilterBlock:filteringSuccessBlock:filteringFailureBlock:playFinishBlock:animationFinishBlock:]
                                                                    v72@0:8@16Q24@?32@?40@?48@?56@?64
-[WINSplashScreenPresenter addSplashViewForResource:creative:sessionId:] v40@0:8@16@24@32
-[WINSplashView showWithImageData:localPath:creative:]             v40@0:8@16@24@32
-[WINSplashView showVideoWithLocalPath:creative:]                   v32@0:8@16@24
-[WINSplashScreenData setAd:]                                       v24@0:8@16
```

`checkAndShowRealtimeFlashView:` 的参数是 `Q`（unsigned long long），实测传入 `100`
（scene 枚举）。这说明广告是走“实时开屏”分支进来的。

## 7. 复刻实现（`src/AmapSplash.m`）

不依赖 CydiaSubstrate，直接 `method_setImplementation`：

* 用 `class_copyMethodList` 确认方法**定义在当前类**，避免误改父类（例如 `NSObject init`）。
* 类方法走 `object_getClass(cls)` + `class_getClassMethod`。
* 只替换确实存在的方法；缺类/缺方法写 `SKIP` 日志，不 crash。
* 返回值按 type encoding 对齐：`B` → `NO`，`@` → `nil`/`@NO`，`v` → 空实现，`q` → 0。

拦截顺序（从外到内）：

1. `+shouldSplashScreenShow:launchCheck:` → `NO`（总闸）
2. `+enableXDays` → `0`（关闭开屏实验/天数开关）
3. `-isLocalSplashDataCanExposure` → `@NO`
4. `-checkAndShowRealtimeFlashView:` / `-checkAndShowLocalRealtimeAndPreloadFlashView:` /
   `-checkAndShowPreloadFlashView:otherInfo:` / `-checkAndShowLocalRealtimeFlashView:data:otherInfo:` → 空
5. `-presentSplashScreenWithData:...` / `-presentRealTimeSplashScreen:...` → 空
6. `-addSplashViewForResource:creative:sessionId:` → `nil`
7. `-showWithImageData:...` / `-showVideoWithLocalPath:...` / `-initWithFrame:` → 空/`nil`
8. `-setAd:` → 空
9. `fetchSplashDataWithScene:` → 空（不再拉取新的开屏素材）

这样即使某一条被版本微调绕过，外层总闸和展示层仍然是双保险。

## 8. 复现命令

```sh
# 1) 还原 WKK 的 hook 表
python3 tools/hookmap.py src-dis/orig-xxhook.dylib \
        --json build/hookmap.json --header src/hooks_generated.h

# 2) 跑只读诊断（装到 /var/jb/usr/lib/TweakInject，启动高德，读 tmp/amapdiag.txt）
#    见 src/amapdiag.m

# 3) 构建 + 打包
sh scripts/build.sh
python3 scripts/pack-deb.py roothide iphoneos-arm64e
```

## 9. 遗留

* 首页运营位（扫街榜、台风气泡、登录引导条）是业务推荐，未做无差别删除。
  如果用户希望“首页也干净”，需要单独定位 `WINGroupMapWidget` / `WINSplashLinkage`
  之外的运营位容器，再逐项确认不影响功能。
* 高德一旦再升级，优先重跑 §4 的清点，确认下面这 4 个入口是否还在：
  `+shouldSplashScreenShow:launchCheck:`、`-checkAndShowRealtimeFlashView:`、
  `-presentSplashScreenWithData:...`、`-showWithImageData:localPath:creative:`。
