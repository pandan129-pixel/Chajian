# 高德地图 NoAds（AmapSplash）1.1.0

针对 **高德地图 iOS 17.02.1** 的开屏广告修复版。
来源背景：WKK 源的 `高德地图NoAds 1.1-3`（与微信里发来的 `高德地图.dylib` 是同一个文件）
在 17.x 上已经失效，广告照常出现。本项目把它逆向后重新实现，并适配当前版本。

## 产物

| 文件 | 适用 |
|------|------|
| `dist/com.pandan.amapsplash_1.1.0_iphoneos-arm64e.deb` | roothide（Dopamine 3.x，`.20` 已安装） |
| `dist/com.pandan.amapsplash_1.1.0_iphoneos-arm64.deb` | rootless（Relaxin / 传统无根，`.28`） |
| `ipa/Amap-latest.ipa` | 高德地图 17.02.1（App Store 原包，262 MB） |

dylib 是 **arm64 + arm64e 胖二进制**。这一点很关键：高德主程序是 `ARM64`，
WKK 原包标着 arm64/arm64e，但两个 deb 里实际都只有 thin arm64e，根本注入不进去。

## 安装

```sh
# roothide（.20）
scp dist/com.pandan.amapsplash_1.1.0_iphoneos-arm64e.deb mobile@DEVICE_IP:/var/mobile/Documents/
ssh mobile@DEVICE_IP 'sudo dpkg -i /var/mobile/Documents/com.pandan.amapsplash_1.1.0_iphoneos-arm64e.deb'

# rootless（.28）
scp dist/com.pandan.amapsplash_1.1.0_iphoneos-arm64.deb mobile@DEVICE_IP:/var/mobile/Documents/
ssh mobile@DEVICE_IP 'sudo dpkg -i /var/mobile/Documents/com.pandan.amapsplash_1.1.0_iphoneos-arm64.deb'
```

安装后**杀一次高德再打开**：

```sh
killall -9 AMapiPhone; uiopen --bundleid com.autonavi.amap
```

## 验证

进程内日志（App 容器 `tmp/amapsplash.log`）会记录每个 hook 的安装结果和拦截点：

```
HOOK   +vapp shouldSplashScreenShow:launchCheck:  types=B28@0:8^@16B24
...
CALL   +shouldSplashScreenShow:launchCheck: -> NO (blocked)
```

`.20` 上的实测结果（详见 `docs/TEST-EVIDENCE.md`）：

* 对照组（原始 WKK 逻辑 / 不拦截）：冷启动 1.5 s 时窗口里有 `WINSplashView`，含跳过按钮与广告图。
* 修复组：同一时刻 `WINSplashView` 数量为 **0**，直接进入地图首页。
* 强制放开总开关后：`-checkAndShowRealtimeFlashView:100` 被调用并被拦截，3 s 截图仍是地图首页。
* 正式 deb 安装后：`+shouldSplashScreenShow:launchCheck:` 被调用并返回 `NO`。

## 构建

```sh
sh scripts/build.sh                       # build/AmapSplash.dylib (arm64+arm64e)
python3 scripts/pack-deb.py roothide iphoneos-arm64e
python3 scripts/pack-deb.py rootless iphoneos-arm64
```

调试用变体（会额外在 App `tmp/` 下 dump UI 层级并截图）：

```sh
clang ... -DUI_PROBE ... src/AmapSplash.m     # 见 docs/TEST-EVIDENCE.md
```

## 目录

```
src/AmapSplash.m            正式源码（runtime hook，不依赖 CydiaSubstrate）
src/amapdiag.m              只读诊断 dylib：清点类/方法是否还在
src/hooks_generated.h       从原 dylib 自动还原的 52 条 hook 表
src-dis/orig-xxhook.dylib   原始样本（sha256 548d398b...）
tools/hookmap.py            解析 MSHookMessageEx 调用表并分类 IMP
tools/frida_ui.py           frida UI 检查（高德有反调试，attach 会超时）
wkk/                        WKK 1.1-3 两个架构的 deb 与解包
ipa/Amap-latest.ipa         高德 17.02.1 原包
docs/REVERSE-NOTES.md       ？为什么失效、新版链路在哪
docs/TEST-EVIDENCE.md       时间线证据与复现命令
```

## 范围与限制

* 只处理**开屏 / 实时开屏 / 启动广告**、升级弹窗、TestFlight 提示，以及 WKK 原有的首页小部件清理。
* 首页运营位（扫街榜入口、台风位置气泡等）属于业务推荐位，未做无差别删除，避免误伤功能。
* 高德带反调试；不要用 frida attach 做常规验证，会超时。用进程内日志/探针。
* 若高德升级到 17.1x 之后再次改名，先跑 `src/amapdiag.m`，再按 `docs/REVERSE-NOTES.md` §6 的方法补 hook。
