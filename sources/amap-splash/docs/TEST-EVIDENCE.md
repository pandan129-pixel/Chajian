# 验证证据（.20 / 高德 17.02.1）

设备：iPhone 14 Pro（`iPhone15,2`），iOS **16.3.1 (20D67)**，roothide 3.x。
App：`com.autonavi.amap` **17.02.1**（`CFBundleVersion 17.02.1.2004`），
主程序 `AMapiPhone` 为 **ARM64**，路径
`/var/containers/Bundle/Application/916545BE-.../AMapiPhone.app`。

安装的包：`com.pandan.amapsplash 1.1.0`（iphoneos-arm64e，roothide 布局）。

---

## 1. 对照组：原逻辑（不拦截）确实有开屏广告

构建：`-DNO_HOOKS -DUI_PROBE`，只 dump UI / 截图，不改任何方法。
冷启动 1.5 s 时的窗口层级（`docs/evidence/01-control-t1.5-splash.txt`）：

```
--- UI t1.5 pid=27943 ---
UIWindow frame={{0, 0}, {393, 852}}
  ...
  WINSplashView frame={{0, 0}, {393, 852}} hidden=0 alpha=1.00
    UIView
      UIImageView frame={{0, 726.3}, {393, 125.7}}      # 底部广告素材
      UIImageView frame={{-100, 134.7}, {593, 522.7}} hidden=1
    NMBaseButton frame={{0, 0}, {393, 852}}
    WINSplashVerticalSlideAndTextButtonInteractionView
      WINSplashScreenButton frame={{38.3, 709.3}, {316.3, 58.7}}   # 跳过按钮
```

结论：广告链路正常，`WINSplashView` 在窗口里。

## 2. 修复组：同一时刻没有开屏

构建：`-DUI_PROBE`（正式 hook 全开）。
4 个时间点（1.5 / 3 / 6 / 10 s）dump 结果：

```
device/fix-amapui-t1.5-27978.txt: WINSplashView 出现次数 = 0
device/fix-amapui-t3-27978.txt  : 0
device/fix-amapui-t6-27978.txt  : 0
device/fix-amapui-t10-27978.txt : 0
```

日志（`docs/evidence/06-fix-hook-log.txt`）显示所有关键 hook 安装成功，例如：

```
HOOK   +vapp shouldSplashScreenShow:launchCheck:  types=B28@0:8^@16B24
HOOK   -pres presentSplashScreenWithData:scene:fromBackground:otherInfo:...  types=v76@...
HOOK   -sview showWithImageData:localPath:creative:  types=v40@0:8@16@24@32
```

## 3. 强制组：排除“被频控、本来就不出广告”的疑问

构建：`-DUI_PROBE -DFORCE_SHOW`：把总闸改成返回 `YES`，但**展示层仍然拦截**。

日志（`docs/evidence/03-force-log.txt`）：

```
CALL   +shouldSplashScreenShow:launchCheck: -> YES (forced, test build)
CALL   +shouldSplashScreenShow:launchCheck: -> YES (forced, test build)
CALL   -checkAndShowRealtimeFlashView:100 -> blocked
```

说明 App **确实走到了实时开屏分支**（scene=100），但被
`-checkAndShowRealtimeFlashView:` 拦下。3 s 截图
（`docs/evidence/04-force-t3-home.png`）是地图首页，没有任何开屏素材/跳过按钮。

## 4. 正式 deb：总闸生效

安装 `com.pandan.amapsplash_1.1.0` 后冷启动，日志尾：

```
=== install done ===
CALL   +shouldSplashScreenShow:launchCheck: -> NO (blocked)
```

`+shouldSplashScreenShow:launchCheck:` 是 App 自己的入口；返回 `NO` 后不再进入
后续 `checkAndShow*` 分支。

## 5. 复现

```sh
# 设备侧（roothide）
dpkg -i com.pandan.amapsplash_1.1.0_iphoneos-arm64e.deb
killall -9 AMapiPhone
uiopen --bundleid com.autonavi.amap

# 读进程内日志（App 容器 tmp）
find /var/mobile/Containers/Data/Application -name amapsplash.log
tail -20 <path>/amapsplash.log
```

调试探针构建（会写 `amapui-t*.txt` / `.png`）：

```sh
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
clang -x objective-c -arch arm64 -arch arm64e -miphoneos-version-min=15.0 \
  -isysroot "$SDK" -O2 -DUI_PROBE -dynamiclib -framework Foundation -framework UIKit \
  -install_name /usr/lib/TweakInject/AmapSplash.dylib \
  src/AmapSplash.m -o build/AmapSplash-probe.dylib
codesign -f -s - build/AmapSplash-probe.dylib
```

## 6. 哈希

```
548d398b7c31c3a7350401d517d1353f33d753549961dd28409012fdbf1d1e7c  原始 高德地图.dylib
b7f08cd14d1c3c3d01ee111c8a5c0ef65b695e4c338a0aa5510d08d3dcc004fb  com.pandan.amapsplash_1.1.0_iphoneos-arm64e.deb
f0595350ed0e9b4f4804128d73d3e92dd02c853b5657f8abf92a2ab3ea9f6c30  com.pandan.amapsplash_1.1.0_iphoneos-arm64.deb
6f397e9ea872ff1a3737a3918c33d81fd3ad7099561c124f36a0e3041ae9f24b  Amap-latest.ipa (17.02.1)
```
