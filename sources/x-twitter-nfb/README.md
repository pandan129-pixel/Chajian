# NeoFreeBird 7.3.0（X 12.39）deb 重打包

从 `X_Twitter_12.39_NFB730_秋名山.ipa` 提取 NFB 7.3.0 的 dylib/资源包，
按越狱约定重打包成 Pandan 源用的两个 flavor。

```
dist/com.nfb.tweak_7.3.0-7_iphoneos-arm64.deb    rootless（/var/jb，.28）
dist/com.nfb.tweak_7.3.0-7_iphoneos-arm64e.deb   roothide（无前缀，.20）
```

## 为什么用 IPA 里的 dylib，而不是官方 7.3.0 deb

官方 7.3.0 deb 的 `T1TabView` 仍然定义 `applyCurrentThemeToIcon`，内部调用
`_t1_updateTitleLabel`（X 12.38+ 已删除）；改主题时仍有崩溃风险。

12.39 IPA 里的构建更新：

- `T1TabView` 改用 `applyTintColor:`；
- 不再 hook `_t1_updateTitleLabel`；
- 保留 12.38 的 Liquid Glass 保护（`installGateWithRedesignEnabled:` 用
  `respondsToSelector` 包住）；
- 用 12.39 的 ObjC 元数据审计：308 个 hook，0 个 hook 体内调用 12.39 已删 selector。

## 简体中文

`l10n/` 里维护了 341 条简体中文文案（`zh-Hans.lproj` + 旧语言码 `zh_CN.lproj`），
以及「还原 Twitter 术语」用的 `RenameWords.strings`。构建时覆盖 IPA 里的 bundle。

- iOS 9+ 的简体中文语言码是 `zh-Hans`，原 bundle 只有旧的 `zh_CN`，补上后系统才能稳定命中；
- 修了若干机翻/错译（如 `酷小孩`→`大佬们`、`自主刷时间线`→`时间线自动刷新`、
  `复制简介链接`→`复制网站`、`禁用`统一为`关闭` 等）；
- 界面语言跟随 X 的 App 语言。X 是英文时插件也会显示英文，可在
  iOS 设置 → X → 语言 里改成「简体中文」。

重新生成文案：

```sh
python3 l10n/build_zh.py /path/to/BHTwitter.bundle
```

## 本地化资源包修复（0NFBBundleFix.dylib）

NFB 7.3.0 的 `BHTBundle` 只认几个写死路径，roothide 上经常找不到
`BHTwitter.bundle`，界面就会显示 `NFB_SETTINGS_TITLE` 这类 key。

`fix/NFBBundleFix.m` 编译出的 `0NFBBundleFix.dylib` 会在启动时：

1. 从自己的 dylib 目录逐级向上找 `BHTwitter.bundle`；
2. 精确重定向 `+[NSBundle bundleWithPath:]` 和
   `-[NSFileManager fileExistsAtPath:]`（只对 `BHTwitter.bundle` 路径生效）。

它不改 NFB 二进制，也不依赖 `/Library`、`/var/jb` 是否存在；找不到时只打日志，
不会影响 App 启动。本地用 macOS 版验证过：对一个不存在的路径调用
`bundleWithPath:` 也能拿到真实 bundle 并读出中文。

## 打包差异

侧载 dylib 依赖：

```
@executable_path/Frameworks/libellekit.dylib
```

两个 flavor 分别改写成：

| flavor | 改写为 |
|---|---|
| roothide | `@loader_path/.jbroot/usr/lib/libsubstrate.dylib` |
| rootless | `/var/jb/usr/lib/libsubstrate.dylib` |

然后 ad-hoc 重签（`codesign -f -s -`），其余字节不变。

包名用上游的 `com.nfb.tweak`，并写：

```
Conflicts: com.bandarhl.bhtwitter, ...
Replaces:  com.bandarhl.bhtwitter
```

安装时会移除旧的 NFX 7.2，避免两个 `BHTwitter.dylib` 同时注入。

## 构建

```sh
./build-ipa.sh /path/to/X_Twitter_12.39_NFB730_秋名山.ipa
```

`build.sh` 保留为「从官方 7.3.0 deb 重打包」的备选路径。

## 验证

`build-ipa.sh` 会检查：

- `ar` 成员、control 的 Package/Version/Architecture
- dylib arm64、ad-hoc 签名
- 依赖已改成对应 bootstrap 的 substrate 路径，且不含 ellekit
- filter 只针对 `com.atebits.Tweetie2`
- 资源包存在

## 中文化

源码级方案见 `docs/LOCALIZATION.md`：

- `layout/.../zh-Hans.lproj` + `zh_CN.lproj`：318/318；
- `src/Core/BHTBundle.m`：用 `dladdr` 从 dylib 位置解析 bundle，覆盖 rootful/rootless/roothide/侧载；
- `src/Hooks/Branding.x`：`NSRegularExpressionUseUnicodeWordBoundaries`，中文术语可在句中替换；
- 打包用 341 条（12.39 构建）在 `l10n/`，成品 7.3.0-7 内置 `0NFBBundleFix.dylib`。

## 长期方案

「X 一更新就闪退」的根治（fail-open 版本闸门、发版审计清单）见
`docs/SOLUTION-X-UPDATE-CRASH.md`。
