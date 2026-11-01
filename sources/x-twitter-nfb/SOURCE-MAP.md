# com.nfb.tweak 目录与代码索引

包名：`com.nfb.tweak`（NeoFreeBird）  
本机项目根：`~/Desktop/iphone/plugins/x-twitter-nfb/`

---

## 1. 目录树

```
plugins/x-twitter-nfb/
├── README.md                     # 项目说明 / 打包差异 / 汉化说明
├── build-ipa.sh                  # 当前使用：从 12.39 IPA 提取 dylib 打 deb（7.3.0-7）
├── build.sh                      # 备选：从官方 7.3.0 deb 重打包
├── packaging/
│   ├── control.in                # deb control 模板（com.nfb.tweak）
│   └── BHTwitter.plist           # filter: com.atebits.Tweetie2
├── l10n/
│   ├── build_zh.py               # 生成简体中文（zh-Hans + zh_CN + RenameWords）
│   ├── zh-Hans.lproj/
│   │   ├── Localizable.strings   # 341 条简体中文（binary plist）
│   │   └── RenameWords.strings   # 帖子→推文 / 转帖→转推 / X→Twitter
│   └── zh_CN.lproj/              # 同上（旧语言码，兼容用）
├── dist/
│   ├── com.nfb.tweak_7.3.0-7_iphoneos-arm64.deb    # rootless（/var/jb）
│   └── com.nfb.tweak_7.3.0-7_iphoneos-arm64e.deb   # roothide（无前缀）
├── docs/
│   ├── RE-X1238-CRASH.md         # X 12.38+ 启动闪退根因（T1TabView/titleLabel）
│   └── SOLUTION-X-UPDATE-CRASH.md# 防“X 一更新就闪退”的 fail-open/审计方案
├── src/
│   └── NeoFreeBird-7.3.0/        # 上游 v7.3.0 源码（官方 com.nfb.tweak）
└── vendor/                       # 上游 deb 缓存（build.sh 用，可不提交）
```

源码目录（上游 v7.3.0）：

```
src/NeoFreeBird-7.3.0/
├── control                       # Package: com.nfb.tweak / Version: 7.3.0
├── Makefile                      # Theos：TWEAK_NAME = BHTwitter
├── build.sh                      # 上游构建脚本（--rootless / --rootfull）
├── check_localization.py         # 检查各语言缺哪些 key
├── BHTwitter.plist               # 注入 filter（Bundles: com.atebits.Tweetie2）
├── layout/Library/Application Support/BHT/BHTwitter.bundle/   # 各语言资源
├── src/
│   ├── Core/BHTBundle.m          # 资源包查找（“全是 key”就是这里没找到）
│   ├── Core/BHTSettings.m        # 偏好读写
│   ├── Hooks/                    # 所有 hook（*.x）
│   │   ├── Theme.x               # T1TabView / 主题（12.38 崩溃点在这里）
│   │   ├── FeatureSwitches.x     # Liquid Glass / 功能开关
│   │   ├── SplitTweetView.x      # iPad 分栏
│   │   ├── Misc.x                # 剪贴板/杂项
│   │   ├── MediaDownloads.x      # 下载
│   │   └── ...                   # 共 28 个 hook 文件
│   └── Settings/                 # 设置页 UI
└── deps/                         # ffmpeg-kit-next / flex 等（git submodule，需单独拉）
```

---

## 2. 包信息（`control`）

```
Package: com.nfb.tweak
Name: NeoFreeBird
Version: 7.3.0
Architecture: iphoneos-arm
Description: A tweak which brings back the old Twitter experience, with the features of X.
Maintainer: NeoFreeBird
Author: NeoFreeBird
Section: Tweaks
Depends: mobilesubstrate
Conflicts: com.den.twigalaxy, xyz.cypwn.twigalaxy, xyz.cypwn.bhtwitter, com.netskao.twitternoads, xyz.cypwn.bringbacktwitter
```

我们重打包时实际写入的 control（`build-ipa.sh` 里生成）：

```
Package: com.nfb.tweak
Name: NeoFreeBird (X 12.39)
Version: 7.3.0-7
Architecture: iphoneos-arm64      # rootless；arm64e 是 roothide
Depends: firmware (>= 15.0), mobilesubstrate
Conflicts: com.bandarhl.bhtwitter, com.den.twigalaxy, xyz.cypwn.twigalaxy, xyz.cypwn.bhtwitter, com.netskao.twitternoads, xyz.cypwn.bringbacktwitter
Replaces: com.bandarhl.bhtwitter
Pre-Depends: rootless-compat (>= 0.9)   # 仅 roothide flavor
```

---

## 3. 关键代码

### 3.1 资源包查找（显示 key 的根因）

`src/NeoFreeBird-7.3.0/src/Core/BHTBundle.m`：

```objc
+ (instancetype)sharedBundle {
    static BHTBundle* sharedBundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSFileManager* fileManager = [NSFileManager defaultManager];
        NSURL* bundlePath = nil;
        if ([fileManager fileExistsAtPath:
                @"/Library/Application Support/BHT/BHTwitter.bundle"]) {
            bundlePath = [NSURL fileURLWithPath:
                @"/Library/Application Support/BHT/BHTwitter.bundle"];
        } else if ([fileManager fileExistsAtPath:
                @"/var/jb/Library/Application Support/BHT/BHTwitter.bundle"]) {
            bundlePath = [NSURL fileURLWithPath:
                @"/var/jb/Library/Application Support/BHT/BHTwitter.bundle"];
        } else {
            bundlePath = [[NSBundle mainBundle] URLForResource:@"BHTwitter"
                                                 withExtension:@"bundle"];
        }
        sharedBundle = [[self alloc] initWithBundlePath:bundlePath];
    });
    return sharedBundle;
}
```

> 12.39 IPA 里的构建是改过的版本：会先找 **dylib 同目录**的 `BHTwitter.bundle`
> （`tweakDylibPath` + `realpath`），所以 7.3.0-7 在
> `Library/MobileSubstrate/DynamicLibraries/BHTwitter.bundle` 也放了一份。

### 3.2 hook 入口（Logos）

以 `%ctor` 为例（`src/Hooks/Tenor.x:535`）：

```objc
%ctor {
    %init;
}
```

所有 hook 都在 `src/Hooks/*.x`，每个文件是 `%hook Class ... %end` 形式；
`Makefile` 自动收集 `src/**/*.x` 和 `src/**/*.m`。

### 3.3 12.38 崩溃点（`Theme.x`）

旧版：

```objc
%new
- (void)applyCurrentThemeToIcon {
    [self _t1_updateImageViewAnimated:NO];
    [self _t1_updateTitleLabel];     // 12.38 已删除该方法
}
```

7.3.0 改成了：

```objc
- (void)_t1_updateImageViewAnimated:(BOOL)animated {
    ...
    self.iconColor = ...;            // 不再调用 applyCurrentThemeToIcon
    %orig(animated);
}
```

新版还 hook 了 `applyTintColor:`，不再依赖 `_t1_updateTitleLabel`。

---

## 4. 构建命令

### 4.1 重打包成 deb（不需要编译）

```sh
cd ~/Desktop/iphone/plugins/x-twitter-nfb

# 当前方案：从 12.39 IPA 提取 dylib，改写 substrate 依赖，带汉化
./build-ipa.sh "~/Downloads/X_Twitter_12.39_NFB730_秋名山.ipa"

# 或者：从官方 7.3.0 deb 重打包（不带 12.39 的 T1TabView 修复）
./build.sh
```

产物在 `dist/`。

### 4.2 重新生成汉化

```sh
python3 l10n/build_zh.py "/path/to/BHTwitter.bundle"
```

会写回 `l10n/zh-Hans.lproj` 和 `l10n/zh_CN.lproj`，下次 `build-ipa.sh` 自动覆盖进包。

### 4.3 从源码编译上游（需要 Theos + 子模块 + FFmpeg）

```sh
cd src/NeoFreeBird-7.3.0
git submodule update --init --recursive     # deps/flex、deps/ffmpeg-kit-next 等
./build.sh --rootless                       # 或 --rootfull
```

> 本机当前的 7.3.0-7 dylib 不是这份源码编译的，而是从 12.39 IPA 里提取的
> 定制构建（带 `resolvedBundleURL` / `applyTintColor:` / 12.38 修复）。
> 那份定制源码没有公开，只有二进制。

---

## 5. 已发布的包

```
plugins/x-twitter-nfb/dist/com.nfb.tweak_7.3.0-7_iphoneos-arm64.deb
plugins/x-twitter-nfb/dist/com.nfb.tweak_7.3.0-7_iphoneos-arm64e.deb
repo/docs/debs/com.nfb.tweak_7.3.0-7_iphoneos-arm64.deb
repo/docs/debs/com.nfb.tweak_7.3.0-7_iphoneos-arm64e.deb
```

deb 内部布局：

```
Library/Application Support/BHT/BHTwitter.bundle/            # 资源（含 zh-Hans）
Library/MobileSubstrate/DynamicLibraries/BHTwitter.dylib
Library/MobileSubstrate/DynamicLibraries/BHTwitter.plist
Library/MobileSubstrate/DynamicLibraries/BHTwitter.bundle/   # dylib 同目录副本
Library/MobileSubstrate/DynamicLibraries/libbhFLEX.dylib
Library/MobileSubstrate/DynamicLibraries/libbhFLEX.plist
```
