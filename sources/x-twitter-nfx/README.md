# BHTwitter 7.2（从 X 12.37 NFX7.2 / 秋名山 IPA 提取）

从 `X_Twitter_12.37_NFX7.2_秋名山.ipa` 里取出插件本体，按越狱包规约重新打包成 deb。

```
src/BHTwitter.dylib          原始插件（arm64，2.1 MB，含 FLEX）
src/BHTwitter.bundle/        资源包（25 个文件，640 KB）
src/zxPluginsInject.dylib    参考用：侧载容器修补，不打包
dist/com.bandarhl.bhtwitter_7.2_iphoneos-arm64e.deb   roothide（本机两台都用这个）
dist/com.bandarhl.bhtwitter_7.2_iphoneos-arm64.deb    rootless（/var/jb）
```

## 为什么不能直接把 IPA 里的 dylib 打包

IPA 里的 dylib 有一条加载命令指向**侧载注入器**：

```
@executable_path/Frameworks/libellekit.dylib
```

`@executable_path` 是 App 可执行文件所在目录。侧载的 X 里有
`Frameworks/libellekit.dylib`，所以能加载；但 App Store 装的 X 里没有这个文件，
直接打成 deb 会在注入时 `dlopen` 失败（tweak 不生效，甚至拖崩 App）。

所以两个 flavor 在打包时分别改写成各自 bootstrap 真正有的路径，然后**重新签名**
（`install_name_tool` 会让原签名失效）：

| flavor | 改写为 | 依据 |
|---|---|---|
| roothide | `@loader_path/.jbroot/usr/lib/libsubstrate.dylib` | 本机 `0hello120hz`、`XianYuPlus` 等可用插件都是这个写法 |
| rootless | `/var/jb/usr/lib/libsubstrate.dylib` | rootless 的 ElleKit 安装路径 |

除这一条加载命令和签名外，dylib 其余字节与 IPA 内完全一致。

## 包里装了什么

```
Library/MobileSubstrate/DynamicLibraries/BHTwitter.dylib
Library/MobileSubstrate/DynamicLibraries/BHTwitter.plist   Filter: com.atebits.Tweetie2
Library/Application Support/BHT/BHTwitter.bundle/...
```

- Package: `com.bandarhl.bhtwitter`（与本机已装的 7.0 同 id，可原地升级）
- Version: `7.2`
- Architecture: `iphoneos-arm64e` / `arm64`（按 bootstrap，不按 dylib 的 slice）
- Depends: `firmware (>= 14.0), mobilesubstrate`；Pre-Depends: `rootless-compat (>= 0.9)`

## 没有打包的东西（以及原因）

| 文件 | 为什么不要 |
|---|---|
| `Frameworks/libellekit.dylib` | 侧载用的注入框架；越狱设备由 ElleKit 提供，重复放会冲突 |
| `Frameworks/zxPluginsInject.dylib` | 侧载容器修补（rebind Security + 重定向 NSUserDefaults app group），不是插件；装进越狱环境只会多一个全局 hook |
| `Twitter` 主程序、Info.plist 等 | 不属于插件；deb 只做注入 |

## 安装

```sh
# Irisin / Sileo / Zebra 直接点开 deb，或：
scp -O dist/com.bandarhl.bhtwitter_7.2_iphoneos-arm64e.deb mobile@DEVICE_IP:/var/mobile/
ssh mobile@DEVICE_IP 'sudo dpkg -i /var/mobile/com.bandarhl.bhtwitter_7.2_iphoneos-arm64e.deb'
```

- 已装 7.0 的机器会被直接升级（同 package id）。
- 装完**杀掉 X 再重开**即可，不需要 respring（filter 只针对 X）。
- 不要同时保留 IPA 侧载版和这个 deb：两边都会注入 BHTwitter，等于加载两次。
- 设置入口在 X 自己的设置页里（BHTwitter 面板），偏好文件在
  `/var/mobile/Library/Preferences/` 下。

## 自检 / 复现

```sh
./extract.sh                 # 从 Downloads 里的 IPA 重新提取到 src/
./build.sh                   # 生成两个 deb，并做完整校验
```

`build.sh` 的校验项：

- `machocheck`：arm64、已签名、filter 命名正确、无指针签名丢失
- 改写的 substrate 路径确实存在，且旧 ellekit 引用已消失
- `ar` 成员、control 的 Package/Version/Architecture
- 解包后再跑一次 `machocheck`，并确认资源包存在

当前产物（各约 1 MB）：

```
dist/com.bandarhl.bhtwitter_7.2_iphoneos-arm64e.deb
dist/com.bandarhl.bhtwitter_7.2_iphoneos-arm64.deb
```

deb 的 SHA-256 每次构建都会变（codesign 的签名与 dm.pl 的时间戳），
要核对内容请用 `build.sh` 里的校验项，而不是记 hash。

## 来源与校验

| 项 | 值 |
|---|---|
| IPA | `X_Twitter_12.37_NFX7.2_秋名山.ipa`，268 MB |
| IPA SHA-256 | `047455412359a8382835674d7ec4cdeae9c127d16a1e9b5f50e9ed1a84d7e989` |
| X 版本 | 12.37（build 28），bundle `com.atebits.Tweetie2` |
| BHTwitter.dylib SHA-256 | `fa3221fab00bad460c777631b5412bf081baebde9dd62df505778b67ea98526f` |
| BHTwitter.dylib UUID | `8147B7FC-A902-3D6E-A7DE-0C0B42BD5345`（arm64，iOS 14.0+，chained fixups） |
| 资源包 BHTVersion | 5.1（bundle 自身的 version key，与插件 7.2 不是一回事）；与 7.0 同结构 23 个文件，17 个 Localizable.strings 已更新 |
| 参考：本机已装 7.0 | `com.bandarhl.bhtwitter 7.0 iphoneos-arm64e`，dylib 19 MB（未 strip 的构建） |

插件代码与资源版权归原作者 BandarHL；7.2 的修改来自 NFX / 秋名山。本目录只为在自有设备上
复现与升级，不包含也不分发 IPA。

## 安装记录：.20（iPhone 14 Pro / iOS 16.3.1 / Dopamine roothide）

2026-10-25 实测，官方 App Store X 12.37（build 28）：

- 包：`com.bandarhl.bhtwitter 7.2 iphoneos-arm64e`，装到
  `<jbroot>/usr/lib/TweakInject/BHTwitter.dylib`（`Library/MobileSubstrate/DynamicLibraries`
  在 roothide 下与之同一目录）。
- 注入验证：临时 canary dylib 写文件到 X 的沙盒 → 成功；BHT 启动后
  `com.atebits.Tweetie2.plist` 里出现 BHTwitter 键。
- **资源包路径**：注入进程看到的是真实内核路径，`/Library/Application Support/BHT`
  并不存在；BHT 自己通过 `dlopen("libroot.dylib")` +
  `libroot_get_jbroot_prefix()` 拼出
  `<jbroot>/Library/Application Support/BHT/BHTwitter.bundle`。实测该前缀 +
  `/Library/Application Support/BHT/BHTwitter.bundle/Info.plist` 存在（rootless-compat 2.0.1）。
  所以**不要**把这个 bundle 装到 rootless 的 `/var/jb` 或系统 `/Library`。
- 如果以后遇到“面板在但文字是键名”，说明 bundle 没被找到：按上面机制核对 `libroot` 前缀，
  或在 deb 里加一个只针对 `com.atebits.Tweetie2` 的 `NSBundle` 路径重定向小 dylib。

侧载 X 的注意事项（本次不再使用侧载版）：侧载包自带一份 `Frameworks/BHTwitter.dylib`
（同 UUID，weak link），与 deb 同时存在会双注入；换官方 X 后此问题消失。

## ⚠️ X 12.38.1 已知崩溃（2026-11-01）

`7.2` 这个构建对应 X 12.37，**在 X 12.38.1 上启动即崩**。根因不是签名/版本号：

- X 12.38.1 删除了 `T1TabView.titleLabel` 与 `_titleLabel` ivar（换成 `title` / `_title`）；
- 插件 `bh_applyCurrentThemeToIcon` 在启动 Tab Bar 阶段用 KVC
  `valueForKey:@"titleLabel"` 读取，KVC 对缺失 key 抛 `NSUnknownKeyException`；
- 该调用在 `_t1_updateImageViewAnimated:` 的 hook 里无条件触发，所以与用户设置无关。

完整证据链、复现命令与修复方案见 **`docs/RE-X1238-CRASH.md`**。
修复请换用 NeoFreeBird **7.3.0**，并且用 `plugins/x-twitter-nfb` 里的
**7.3.0-2**（dylib 取自 `X_Twitter_12.39_NFB730_秋名山.ipa`，已把 `T1TabView`
改成 `applyTintColor:`，不再调用 12.38+ 已删除的 `_t1_updateTitleLabel`）。
不要直接用 12.38.1 IPA 里的 `bb8623d` 开发构建，也不要用官方 7.3.0 deb 的旧
`T1TabView` 实现。
