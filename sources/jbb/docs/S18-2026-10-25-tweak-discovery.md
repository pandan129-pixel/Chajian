# S18 · 6.18.2 — 插件 App 识别（对齐 Choicy）

日期：2026-10-25
设备：`.20` iPhone 14 Pro / 16.3.1 / Dopamine 3.0.12-28（roothide）
      `.28` iPhone 15 Pro / 17.0 / Relaxin（roothide 风格，arch `iphoneos-arm64e`）

## 1. 问题

设置里「插件 → 有插件的 App」只显示 3 个（X / QQ / 小红书），微信、闲鱼、抖音缺失。

## 2. 根因（两条）

1. **plist 格式**：postinst 用 shell `grep '<string>'` 扫描 filter plist，只能读 XML。
   微信（WCLite）、闲鱼（XianYuPlus）、抖音（DYYY）的 filter 都是 **binary plist**，直接被跳过。
   能显示的那 3 个恰好都是 XML 的（BHTwitter / NTQQ_AntiRecall / XHS.J）。
2. **`JBBAppsWithTweaks()` 丢失**：重写 `JBBPrefsCommon.m` 时把函数删了，二进制里是未定义符号
   `_JBBAppsWithTweaks (dynamically looked up)` → 打开「添加 App 覆盖默认设置…」必崩。

## 3. 修法（Choicy 语义）

Choicy 的匹配规则（`ChoicyPrefs/CHPTweakInfo.m` + `CHPTweakList.m:tweakListForExecutableAtPath:`）：

| filter key | Choicy 匹配方式 | jbb 6.18 处理 |
|---|---|---|
| `Filter.Bundles` | bundle identifier | 直接入表，跳过 `com.apple.*` |
| `Filter.Executables` | 可执行文件名 | 经 LaunchServices 反查 bundle id 入表 |
| `Filter.Classes` | 视为 `com.apple.Security` | 已按 Choicy 语义处理，但列表里过滤掉系统项 |
| 链接的 framework | 解析 Mach-O | 未做（对 App 列表无影响） |

解析位置从「postinst 生成文本缓存」改成 **postinst 复制 plist + Settings 运行时用 NSDictionary 解析**
（NSDictionary 天然支持 binary plist，也不需要任何 root 工具 —— `jbb-scan` 在 iOS 17 会被 AMFI SIGKILL）。

数据源（按优先级，第一个解析出结果的生效）：

```
1. <JBBPrefs.bundle>/filters/{TweakInject,MobileSubstrate}/*.plist   root:wheel 644
2. /var/mobile/Library/Preferences/jbb-filters/{...}                 mobile:mobile 644
3. 旧文本缓存 /var/mobile/Library/Preferences/com.pandan.jbb.tweaks.txt（仅兜底，XML-only）
```

第 2 条是保险：`.20` 上 6.17.4 证明 Settings 能读 `/var/mobile/Library/Preferences`，
而 bundle 里的文件能否读取决于 roothide 给的 sandbox 范围。两份内容相同，读哪份都对。

## 4. UI

- 根页：「有插件的 App（N）」的 N 只统计**已安装**的 App。
- 列表页分两段：`已安装（N）` / `未安装（M）`，每组标题下 footer 显示
  `已解析 N 个 tweak filter，识别出 M 个 App（其中 K 个已安装）`，读取失败会额外提示失败数。
- `JBBAppIsInstalled()` 在 LaunchServices 不可用时返回 YES（宁可全列，也不要把列表清空）。
- 「添加 App」页仍是一个「全部 App」+ 搜索，不再有置顶分组。

## 4.1 去噪（6.18.3）

列表只显示**已安装**的 App；未安装的 filter 变体（例如 DYYY 里的 `Aweme3760/3800/3861/3890/3920/3950`）
不再逐条列出，只在 footer 里汇总成一句「已忽略 N 个未安装的 filter 变体」。
未安装的 App 本来也不会被注入、不加载 dylib，对性能零影响，纯粹是列表噪音。

## 4.2 6.18.4：Settings 里拿不到 LaunchServices

6.18.3 之后根页仍显示「有插件的 App（15）」，即 map 里所有条目都被当成已安装。

原因：`JBBAppIsInstalled()` 用 `LSApplicationWorkspace` 判断，但 **Settings 进程压根没链接
MobileCoreServices**（`grep MobileCoreServices /Applications/Preferences.app/Preferences` = 0），
`[nil allInstalledApplications]` 返回 nil → 计数为 0 → 触发「无法判断就全当已安装」的兜底。

Choicy 的做法是 `ChoicyPrefs_PRIVATE_FRAMEWORKS = Preferences MobileCoreServices`。
jbb 改成运行时 `dlopen`，不动 bundle 的 load commands：

```c
"/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices"
"/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices"
"/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices"
```

验证：用注入探针（`opainject`）把 dylib 塞进 Settings 进程后读镜像列表，`MobileCoreServices`
确实出现在 Settings 的已加载镜像里；SDK 的 `MobileCoreServices.tbd` 也导出了
`OBJCCLASS_$_LSApplicationWorkspace` / `LSApplicationProxy`。

另外确认：`.28` 的 `opainject` 其实可用（`[injectDylibViaRop] dlopen succeeded`），
之前判断"不可用"是 pid 没拿到（`launchctl list` 要用 mobile 身份，pid 在第 1 列）。

## 5. 实测数据

本地用两台设备真实 filter 跑同一份解析代码（`JBB_FILTERS_DIR=<dir>` 测试钩子）：

`.28`（13 个 filter 去重后）→ 16 个 App：

```
com.atebits.Tweetie2     BHTwitter, libbhFLEX
com.ss.iphone.ugc.Aweme  DYYY   (+ Aweme3760/3800/3861/3890/3920/3950, aweme.lite)
com.taobao.fleamarket    XianYuPlus
com.tencent.mqq          NTQQ_AntiRecall
com.tencent.xin          WCLite
com.xingin.discover      XHS.J
net.whatsapp.WhatsApp    WATrans
```

`.20`（15 个 filter）→ 12 个 App，额外有 `TGExtra`（Telegram/Nicegram）、`XianyuAdBlock`、`CallAssist`。

## 6. 验证方式

用户在 设置 → JBB 检测绕过 → 插件 → 有插件的 App 里应看到：
footer 的 `已解析 N 个 tweak filter` N > 0，且微信/闲鱼/抖音（装了的话）都在「已安装」段。

若 N 为 0：说明两条数据源都读不到，footer 会直接暴露，下一步改用「postinst 生成二进制 plist 缓存」。

## 7. 顺带

- 设备上清理了 6.17.3–6.18.1 的 deb、`jbbmap.dylib`/`sprobe.dylib` 调试探针。
- X（BHTwitter）结论不变：注入成功、jbb 已对 X 关闭，问题在 BHTwitter 7.0 与 X 12.37 的兼容性。
