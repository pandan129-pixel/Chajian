# 威锋 7.1.1 去广告 IPA — 提取、打包技巧与 7.1.2 适配

源包：`~/Downloads/威锋_7.1.1_去广告@巨魔商店.ipa`
目标机：iPhone 15 Pro / iOS 17.0 / RootHide（`DEVICE_IP`）
目标 App：`com.feng.New.WPForumClient` 7.1.2（已安装，干净 App Store 包）

---

## 1. 包结构：它是怎么"塞"进去的

解开 IPA 后，`Payload/WeiFeng.app/Frameworks/` 里有 6 个第三方 dylib：

| dylib | 大小 | 作用 |
|---|---|---|
| `LoadControl.dylib` | 6.4 MB | **唯一被主程序加载的 loader**（Swift，`LCAI.swift`） |
| `WeifengAdClean.dylib` | 499 KB | **去广告插件**（本文主角） |
| `FakeTools.dylib` | 18 MB | 伪造工具（机型/设备信息等） |
| `120hz.dylib` | 200 KB | 强制高刷（原 CAHighFPS） |
| `录屏触摸轨迹.dylib` | 204 KB | 录屏触摸点（原 TouchVis） |
| `libsubstrate.dylib` | — | 自带 Substrate，App 不依赖越狱环境 |

### 技巧一：只注入一个 loader，其余插件运行时加载

```
otool -L WeiFeng | grep -v "usr/lib\|System/Library"
  @executable_path/Frameworks/LoadControl.dylib (... weak)
```

主程序的 `LC_LOAD_DYLIB` 里**只有 `LoadControl.dylib` 一条**，而且还是 **weak**。
`WeifengAdClean.dylib` 等根本没进 load commands，是 `LoadControl` 在运行时 `dlopen` 的。

`LoadControl` 里能直接读到它的说明：

> 在 Esign 未签名应用中点击「查看文件位置」，把你想被管理的插件（必须 dylib）放到目标软件 .app 目录下的 Frameworks 文件夹。

也就是：**扫 `Frameworks/` 目录 → `dlopen` 每个 dylib**。

好处：
- 主二进制只改 1 条 load command，签名/校验面最小；
- 增删插件只动 `Frameworks/`，不用重新 patch 主程序；
- 换插件版本不用重签整个 App。

### 技巧二：自带 libsubstrate，插件用 `@loader_path`

`WeifengAdClean.dylib` 依赖：

```
@loader_path/libsubstrate.dylib
```

`@loader_path` = `Frameworks/`，所以 App 自带一份 Substrate，**不依赖越狱**（TrollStore 场景）。插件里 `MSHookMessageEx` 用的就是这份。

### 技巧三：fat 二进制 + 临时签名

- 所有插件都是 `arm64 + arm64e` fat；
- `codesign -dv` 显示 `WeifengAdClean.dylib.af633153.unsigned` / `no signature`，靠 TrollStore 安装时整体重签。

### 技巧四：字符串全量 XOR 混淆

`WeifengAdClean.dylib` 里所有类名/选择器都不以明文存在，`strings` 只能看到
`J*i(8` 这种垃圾。规则是每个字符串一个内联解密函数：

```c
decoded[i] = enc[i] ^ ((i * 31 + K) & 0xff)   // K 每条字符串不同
```

反混淆脚本见 `tools/decode_strings.py`，解出 432 条明文（见 `docs/REVERSE-NOTES.md`）。

---

## 2. 去广告插件到底做了什么

`WeifengAdClean.dylib` 是一个**类名驱动**的通用广告拦截器：

- 入口是 `__init_offsets` 构造函数（`0x78e4`）；
- 先校验 `[NSBundle mainBundle].bundleIdentifier == "com.feng.New.WPForumClient"`，不是就静默退出；
- 读 `NSUserDefaults` 的 `WFAdCleanEnabled`，缺省 = 开启；
- 用 `NSClassFromString` / `objc_lookUpClass` 解析类名，**找不到就跳过**（不会崩）；
- 用 `MSHookMessageEx` 挂 hook。

拦截分四层：

| 层 | 目标 | 做法 |
|---|---|---|
| App 业务层 | `WeiFeng.PostDetailAdCell` / `SearchBannerAdCell` / `CollectionViewAdCell` / `ThreadFeedAdCell` / `NewsFeedAdCell` / `ImageAdView` / `FullScreenAdViewController` | hook `layoutSubviews` / `didMoveToSuperview` / `viewDidAppear:`，隐藏或直接 dismiss |
| 数据模型层 | `WeiFeng.NativeAdModel` / `AdvertismentModel` / `SearchAdInfo` / `UserAdInfo` / `PostDetailAdCellModel` / `AdvertisingViewModel` | hook `init`，让广告对象不进入数据源 |
| SDK 层 | 穿山甲 `BU*`、广点通 `GDT*`/`GM*`、快手 `KS*`、阿里 `ABU*`、WindMill、`XAd*`、`ADJg*` | hook `loadAd*` / `showAd*` / `splashAd*` 全部 no-op |
| 网络层 | `NSURL` / `NSURLRequest` / `NSMutableURLRequest` | `URLWithString:` / `requestWithURL:` 命中广告关键词就改写成 `about:blank` |

网络层关键词（明文）：
`advertisment / advertisement / advertise / getadvert / adslot / ad_pos / adpos /
sdkad / adsdk / api/ad / /ad/ /ads/ /xad / x-ad / xads / trackadm / trackpoint /
winnotice / showreport / clickreport / requestsuccessreport / requestfailurereport /
mediarequestsuccessreport`

另外还 hook 了 `WeiFeng.AppDelegate application:didFinishLaunchingWithOptions:` 和
`UIApplicationDidBecomeActive` / `WillEnterForeground` 通知。

> ⚠️ 包里还带了一个**每次启动都弹的「学习声明」**（`FlashAlertController`，
> 含 `https://t.me/ylr155155`）。它的 `WFAdCleanLearningNoticeShown_v1` 标记
> 从来没被写进 prefs，所以每次冷启动都弹。已在 1.0.1 里 patch 掉。

---

## 3. 适配 7.1.2

### 为什么不直接装这个 IPA

- 设备是 **RootHide**，不是 TrollStore，TrollStore IPA 装不上；
- 手机上已经是干净的 7.1.2，重装成 7.1.1 反而降级。

### 做法：把插件改成 TweakInject 注入

7.1.2 主二进制是 thin **arm64**，7.1.1 也是 arm64，所以直接取 arm64 slice。

改动只有三处（`scripts/patch-dylib.py`）：

1. `lipo -thin arm64`（App 是 arm64，arm64e slice 永远用不到）；
2. `install_name_tool -change` 把
   `@loader_path/libsubstrate.dylib` →
   `@loader_path/.jbroot/usr/lib/libsubstrate.dylib`
   （RootHide 惯例，`.jbroot` 是 TweakInject 目录里指向真实 jbroot 的符号链接，
   设备上 `.jbroot -> /`，和已装的 `WCLite.dylib` 一致）；
3. 去掉「学习声明」：
   ```
   0x26830:  tbnz w20, #0, 0x26bb0   ; boolForKey: 已读 → 跳过
        ↓
   0x26830:  b 0x26bb0                ; 永远跳过
   ```

类名是运行时解析的，7.1.2 里 23 个 `WeiFeng.*` 类、广告 SDK 类都还在，
找不到的 hook 会自动跳过，所以不需要改任何类名/选择器。

### 产物

```
dist/com.pandan.weifengadclean_1.0.1_iphoneos-arm64e.deb   # RootHide
dist/com.pandan.weifengadclean_1.0.1_iphoneos-arm64.deb    # rootless
```

安装布局：

```
/usr/lib/TweakInject/WeifengAdClean.dylib
/usr/lib/TweakInject/WeifengAdClean.plist   # Filter -> com.feng.New.WPForumClient
```

---

## 4. 构建 / 安装

```sh
cd ~/Desktop/iphone/weifeng
sh scripts/pack-deb.sh          # 生成两个 deb

# 装机（.28）
.buildtools/scp-put28.exp dist/com.pandan.weifengadclean_1.0.1_iphoneos-arm64e.deb /var/mobile/wfac.deb
.buildtools/ssh28.exp 'echo 67352356 | sudo -S -p "" /var/jb/usr/bin/dpkg -i /var/mobile/wfac.deb'
```

装完 kill 掉威锋重新打开即可。

### 开关

```sh
# 关掉拦截
sudo defaults write com.feng.New.WPForumClient WFAdCleanEnabled -bool NO
# 恢复
sudo defaults delete com.feng.New.WPForumClient WFAdCleanEnabled
```

### 卸载

```sh
sudo /var/jb/usr/bin/dpkg -r com.pandan.weifengadclean
```

---

## 5. 目录

```
weifeng/
├── src/WeifengAdClean.orig.dylib   从 IPA 提取的原始 fat dylib（arm64+arm64e）
├── build/                   中间产物（patch 后的 dylib）
├── dist/                    可安装的 deb
├── packaging/               control + TweakInject filter plist
├── scripts/
│   ├── patch-dylib.py       lipo + 路径改写 + 去弹窗
│   └── pack-deb.sh          打 deb
├── tools/
│   ├── mdis.py              带符号/选择器注解的 arm64 反汇编
│   └── decode_strings.py    XOR 字符串反混淆
└── docs/REVERSE-NOTES.md    逆向细节与完整 hook 清单
```

## 6. 备注

- 手机上原本还有一个 `wfhook.dylib`（Nov 2025，另一套威锋广告 hook，hook `WindMillSplashAd` /
  `ABUNativeAdView` / `WFRefreshView`）。测试时临时禁用过，已恢复启用。
  两套同时开一般没问题；若发现冲突可把 `wfhook.plist` 改名为 `.disabled`。
- `WeifengAdClean.dylib` 是原作者作品（Telegram `ylr155155`），本仓库只做提取与适配。
