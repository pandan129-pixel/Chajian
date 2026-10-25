# Apelin 规则 → 我们所有插件的工程规约

> 交接日期：2026-10-25
> 适用：今后任何 iOS 插件（tweak / root helper / 常驻 daemon / 偏好包 / SMB 类工具）
> 设备基线：`.20` = 14 Pro / iOS 16.3.1 / Dopamine 3.0.12-28（roothide 3.x）；
> 　　　　　`.28` = 15 Pro / iOS 17.0 / Relaxin
> 先读顺序：本文 → `ref/apelin-notes.md`（Apelin 本体阅读笔记）→ `tools/machocheck/README.md`（已落地的构建闸门）

---

## 0. 结论先行

Apelin 是一个"在设备上写/编/装插件"的 IDE，它本身对我们没什么用；
真正有价值的是它把**插件在真机上必然踩到的规则**写成了强制项或技能文档，
而且这些规则大多是我们过去靠"崩一次改一次"学到的。

- 约 **60%** 的仓库内容与我们无关：IDE 自身、Swift/NIO 依赖、vphone、agent、它的守护进程 entitlements。
- 约 **40%** 是硬规则，且可直接迁移：构建/签名顺序、arm64e 指针签名、注入共存、路径拼写、沙箱边界、特权隔离、日志与验证。
- 下面 **R1–R18** 是"照做能省一次真机调试"的条目，**X1–X8** 是"别照抄"的条目。

---

## 1. 规则清单

### A. 构建与签名

| # | 规则 | 依据 | 我们怎么用 |
|---|---|---|---|
| **R1** | **签名是最后一步**；签完再动文件，签名即失效 | `ApelinCodeSign/CodeSigner.swift:31-32` | deb 打包脚本里把 `sign` 放在 `strip` 之后、`dpkg-deb` 之前，中间不插任何修改 |
| **R2** | **dSYM 在 strip 之前**，且保留 `.o`；每个 build 存 dSYM | `Documents/Plan/Milestone-1.md:355-361` | 崩溃先 `dwarfdump --uuid` 匹配镜像 UUID，再 `atos`；不要靠猜 |
| **R3** | **arm64e 禁止 `-undefined dynamic_lookup`**；留给加载期的符号用 `-Wl,-U,_symbol` | `AGENTS.md:2231-2241` | 打包前跑 `tools/machocheck/machocheck --expect-arch arm64,arm64e`；它按 Apelin 的规则判"丢指针签名" |
| **R4** | **架构由 bootstrap 决定**：roothide `arm64e`、rootless `arm64+arm64e`；deb 的 `Architecture` 与 slice 列表无关 | `Extensions/Development/.../manifest.json:18-21`、`PackageLayout.swift:57-62` | 我们的 jbb 实测**必须双架构**（单 arm64e 注入不了微信），所以 roothide 也要 `arm64+arm64e`，别用模板默认值 |
| **R5** | **`-fvisibility=hidden` 是默认**，只导出加载器要的符号；新增方法/类加自己的前缀 | `BuildPipeline.swift:262-288`、`TweakDevelopment.swift` | 新插件第一行 Makefile/项目配置就带它；review 时搜 `visibility("default")` |
| **R6** | 编译基线与可重复构建：`-Werror=unguarded-availability-new`、`-ffile-prefix-map`、显式 deployment target | `BuildPipeline.swift:266-283` | 我们的 jbb 是 iOS 15 起，而 Apelin 默认 16.0 — **别继承它的默认值**；`-ffile-prefix-map` 顺手防止 deb 里泄露本机路径 |

### B. 注入与共存（同进程还有别的 tweak）

| # | 规则 | 依据 | 我们怎么用 |
|---|---|---|---|
| **R7** | 用 `MSHookMessageEx` / `MSHookFunction` 并**调用原函数**；**不要** `method_exchangeImplementations` / `method_setImplementation`（会顶掉别人的 hook） | `TweakDevelopment.swift` | 我们 jbb 已是这种写法；新插件照旧。hook 必须可链式 |
| **R8** | 所有 hook 函数、保存的原 IMP、全局量都 `static`；给系统类加的方法、新建的类都加插件前缀；**不要在 category 里覆盖系统方法** | 同上 | "两个 tweak 用同一个名字，会有一个静默失效" — 这条我们踩过 |
| **R9** | 关联对象 key 用 `static` 变量地址，不用字符串 | 同上 | `objc_getAssociatedObject(obj, &kKey)` |
| **R10** | filter 精确到真正需要的进程；**空 filter 是错误**；文件名是 `Foo.plist`（不是 `Foo.dylib.plist`）紧邻 `Foo.dylib` | `Packager.swift:206-241` | `machocheck --check-filter` 已实现这条检查 |

### C. 路径与沙箱

| # | 规则 | 依据 | 我们怎么用 |
|---|---|---|---|
| **R11** | **三个世界三种拼法**：自己编译的代码用"真实路径 + jbroot 前缀"；bootstrap 的 shell 看到的 `/` 是 jbroot、系统在 `/rootfs`（**shell 打印的路径不能喂给编译器**）；plist/维护脚本用 `@PREFIX@` / `@ROOTFS@`；**永不硬编码 jbroot 或 `/var/jb`** | `BootstrapPaths.swift`、`AGENTS.md:2477-2482` | 新插件只要读写 bootstrap 或系统文件，就先确定它属于哪个世界；现成 helper：Apelin 的 bootstrap-paths 技能内置 `ApelinBootstrap.h`（在 `Skills/BuiltIn/BootstrapPaths.swift` 里），`ApelinBootstrapPath()` 就是它 |
| **R12** | **注入的 dylib 继承宿主 App 的沙箱**：能写的基本只有 bootstrap 的 `/var`；读别的 App 容器/钥匙串/data vault 需要宿主本来没有的 entitlement → EPERM，root 也救不了 | `TweakRuntime.swift` | SMB 插件的临时缓存放 bootstrap `/var/mobile/Library/Caches/<pkg>`；需要特权/共享写 → 自带 daemon |
| **R13** | **权限是按进程的**：root + `no-sandbox` 不等于能读 data vault；要 `com.apple.private.security.storage.<Class>` 签在**那个**二进制上 | `Packaging/Apelind.entitlements` 注释 | 以后写 root helper，entitlement 签在 helper 自己身上，别指望父进程 |
| **R14** | **特权进程必须 `DISABLE_TWEAKS=1`**（launchd plist、spawn 环境都设） | `Packaging/wiki.qaq.apelind.plist:43`、`SessionLink.swift:82` | 我们装了 jbb/ElleKit：root helper 不设这个，会被注入，行为不可预期 |

### D. 诊断与交付

| # | 规则 | 依据 | 我们怎么用 |
|---|---|---|---|
| **R15** | `os_log` 的 subsystem = package id；要读的字符串标 `%{public}`；**iOS 实时日志没有历史** → 先开流再触发；marker 里带 build id | `TweakRuntime.swift`、`DiagnosticsService+ConfirmLoaded.swift:128-165` | 每个 build 打一行 `XxxLoaded <buildID> in <progname>`；respring 后回读确认"这个 build 真的进了目标进程" |
| **R16** | **不要读别的进程的 image list**（iOS 27 上把内核打 panic 三次，两种读法都删了）；加载证据只认 marker | `DiagnosticsService+ConfirmLoaded.swift:104-111` | 不做 `_dyld_image_count` 跨进程验证；hook 是否真的执行要另打日志 |
| **R17** | **打包即校验**：回读签名里的 entitlements、扫构建路径、双布局差异、维护脚本 `sh -n`、launchd 路径前缀；`uicache -i` 验证安装，注意 LaunchServices 缓存旧 Info.plist | `Scripts/package-deb.sh`、`AGENTS.md:2128-2136` | 这正好可以扩成我们的 `pack.sh`：machocheck + 路径扫描 + `dpkg-deb` |
| **R18** | **长任务模型**：任务 ID + 连续 seq + 事件落盘 + `attach(afterSeq)` 重放 + 有限恢复（最多 2 次）；App 死/respring 不丢 | `Packages/ApelinKit/Sources/ApelinProtocol/Tasks.swift`、`Apelind/Session/TaskRegistry.swift` | SMB 大文件传输、后台同步、需要跨 respring 的操作，直接照这个形状设计 |

---

## 2. 按插件类型套用

| 规则 | 普通 tweak | 需要 root helper | 常驻 daemon | 偏好包 | SMB 类 |
|---|---|---|---|---|---|
| R1/R2/R3 签名与 dSYM | 必做 | 必做 | 必做 | 必做 | 必做 |
| R4 双架构 | 必做（roothide 也双） | 必做 | 必做 | 视情况 | 必做 |
| R5/R8/R9 共存 | 必做 | — | — | — | 必做 |
| R7 hook 链 | 必做 | — | — | — | 必做 |
| R10 filter | 必做 | — | — | — | 必做 |
| R11 路径拼写 | 必做（只要碰文件） | 必做 | 必做 | 必做 | 必做 |
| R12 沙箱边界 | 必做 | 反着用（helper 不继承 App 沙箱） | 必做 | — | 必做 |
| R13 按进程授权 | — | **必做** | **必做** | — | helper 必做 |
| R14 DISABLE_TWEAKS | — | **必做** | **必做** | — | helper 必做 |
| R15/R16 日志与验证 | 必做 | 必做 | 必做 | 可选 | 必做 |
| R18 长任务 | — | — | 视情况 | — | **必做** |

---

## 3. 新插件：开工 → 出货 检查单

```sh
# 0) 目录约定：src/ + packaging/ + tools/（不改既有布局）
# 1) 构建基线
#    -arch arm64 -arch arm64e  -mios-version-min=<真实下限>  -fvisibility=hidden
#    -Wall -Wextra -Werror=unguarded-availability-new  -ffile-prefix-map=$PWD=.
#    禁止 -undefined dynamic_lookup；留符号用 -Wl,-U,_symbol

# 2) 架构与签名闸门（必须 0 退出）
tools/machocheck/machocheck --expect-arch arm64,arm64e <built.dylib>

# 3) filter 命名与内容
tools/machocheck/machocheck --allow-unsigned --check-filter <built.dylib>

# 4) helper 的 entitlement（每个都要签在 helper 上）
tools/machocheck/machocheck --require-entitlement platform-application \
    --require-entitlement com.apple.private.security.no-sandbox <helper>

# 5) dSYM 归档（按 UUID，不按文件名）
dwarfdump --uuid <built.dylib> ; # 与 Builds/<ver>/*.dSYM 对 UUID

# 6) 打包前扫路径/占位符（deb 里不能有本机路径、不能有 {{...}}）
#    参考 Scripts/package-deb.sh 的检查项
#    成品复核：dpkg-deb -x out.deb /tmp/x
#              tools/machocheck/machocheck --expect-arch arm64,arm64e \
#                  --check-filter /tmp/x/Library/MobileSubstrate/DynamicLibraries/Foo.dylib

# 7) 装机后验证
#    - marker 日志：先开流，再 respring/重启目标进程
#    - uicache -i <bundleid> 确认注册；CFBundleVersion 是否更新
#    - 崩溃：按 UUID 找 dSYM 再 atos
```

**代码 review 四条**（来自 R7–R9，逐条搜）：
1. 有没有 `method_exchangeImplementations` / `method_setImplementation`？
2. hook 函数、原 IMP、全局量是不是都 `static`？新增方法/类有没有前缀？
3. 关联对象 key 是 `static` 地址还是字符串？
4. 有没有把 bootstrap shell 打印的路径传给编译器 / 硬编码 jbroot？

**运行期 review 三条**（R12/R15/R18）：
1. 写文件的位置在不在 bootstrap `/var` 内？特权写是否走 helper？
2. 日志 subsystem 是不是 package id，读的字段有没有 `%{public}`？
3. 长操作有没有落盘任务 + 可重连，而不是把状态放内存？

---

## 4. 反面清单：别照抄 Apelin 的地方

| # | 不要照抄 | 原因 |
|---|---|---|
| **X1** | 它的"验证通过"结论 | 作者实测只有 iOS 17.3.1 roothide / A12Z 26 / vphone 26–27；**iOS 16 物理机、rootless 真机都没端到端跑过**；真实注入下的 arm64e ABI 未验证 |
| **X2** | roothide 只出 `arm64e` | 与我们 jbb 的"必须双架构"冲突（实测单 arm64e 注入不了微信） |
| **X3** | 默认 `deploymentTarget 16.0` | 我们的 jbb 从 iOS 15 起；照抄会悄悄抬高下限 |
| **X4** | 它的 Theos/Logos 处理方式 | 它不支持 Theos，也没有 `%hook`；我们 Mac 上有 `~/theos`，主力仍是 Theos，只在需要设备内循环时才考虑 Apelin |
| **X5** | 它的守护进程 entitlements 组合 | 那套是为它自己的 IDE 服务（读别的 App 容器、UI 自动化、通知）；我们的 helper 应该只拿最小集合 |
| **X6** | Swift 进 tweak | 它的 tweak 模板只有 ObjC；其 Swift 工具链在 iOS 16 上未验证，且 Swift 5.9+ 的 host 下限是 17.3.1 |
| **X7** | 指望注入就能拿到宿主没有的权限（Bonjour/局域网、data vault…） | 注入改不了宿主 Info.plist；`NSBonjourServices`/`NSLocalNetworkUsageDescription` 属于宿主 App，只能改包重签或改用固定 IP |
| **X8** | 读别的进程 image list 做注入验证 | 内核 panic 实证（R16） |

---

## 5. 我们自己新增的结论（不在 Apelin 里）

| 结论 | 证据 |
|---|---|
| `.buildtools/ldid` 是 codesign shim，**对 dylib 签名会静默丢掉 entitlements**（只留 8 字节空 DER blob）；对可执行文件才生效 | 2026-10-25 实测：`codesign --entitlements` 签 dylib 后 `machocheck` 读不到任何 entitlement。→ 需要 `platform-application`/`no-sandbox` 的 dylib/helper 不能用这个 shim 签 |
| roothide 下 tweak **必须 arm64+arm64e** | jbb 6.9 两台实测（单 arm64e 注入不了微信） |
| SMB 的真挂载只能是 "root helper + 前端插件"，纯 dylib 不行 | NetFS/mount_smbfs 需要 root；App 沙箱内无法 mount |
| `smb://…` 不是 POSIX 路径；mDNS 解析用 NSNetService/dns_sd，但 Bonjour 权限属于宿主 App | R12 + iOS 14+ 的 `NSBonjourServices` / `NSLocalNetworkUsageDescription` 规则 |

---

## 6. 现成资产

| 资产 | 位置 | 说明 |
|---|---|---|
| 构建闸门 | `tools/machocheck/` | 850 行 Swift，0 依赖；pointer-auth / 签名 / entitlements(XML+DER) / 架构 / filter；15 个测试 |
| Apelin 阅读笔记 | `ref/apelin-notes.md` | 构建链路、坑、运行期架构、可复用代码索引 |
| pointer-auth 正负样本 | `tools/machocheck/tests/fixtures/pointer-auth/` | Apelin 的 threaded / plain binds 两个真实产物（MIT，见 NOTICE） |
| Apelin 源码 | 上游 GitHub（本地只读副本在临时目录，不入库） | 规则原文：`AGENTS.md`、`Packages/ApelinAgent/Sources/ApelinAgent/Skills/BuiltIn/*.swift` |

---

## 7. 未决 / 下一步

1. **把 machocheck 接进 deb 打包**：`jb-bypass/packaging` 产出前跑一次，失败不出包；顺手补上"路径/占位符扫描 + 维护脚本 `sh -n`"。
2. **做 `apelin-sign`**：抽 `Packages/ApelinFormats/Sources/ApelinCodeSign/`（纯 Swift，写 XML+DER 两个 slot），替掉会丢 entitlements 的 `.buildtools/ldid`；签完用 machocheck 交叉验证。
3. **SMB 插件最小验证**：先写 CLI（mDNS 解析 → SMB2 列举 `/SSD/` → 读写），跑通后再决定前端形态；若要做挂载，按 R13/R14/R18 设计 root helper。

---

## 8. 附录：速查

### 8.1 roothide / rootless 对照

| 项 | roothide | rootless |
|---|---|---|
| deb 架构 | `iphoneos-arm64e` | `iphoneos-arm64` |
| 安装前缀 | 空（每次越狱随机 jbroot） | `/var/jb` |
| substrate 链接 | `@loader_path/.jbroot/usr/lib/libsubstrate.dylib` | `@rpath/CydiaSubstrate.framework/CydiaSubstrate` |
| plist 里 bootstrap 路径 | `@PREFIX@`（= 空） | `@PREFIX@/…`（= `/var/jb/…`） |
| plist 里系统路径 | `@ROOTFS@/…`（= `/rootfs/…`） | `@ROOTFS@/…`（= `/…`） |
| 维护脚本看到的 `/` | jbroot | 真实根 |
| 卸载后残留 | 目录 + `.jbroot` 链接可能留着，判断"已删"要看有没有普通文件 | 正常 |

### 8.2 规则出处（便于复核）

```
AGENTS.md                                  设计决策与踩坑（arm64e、路径、launchctl、uicache…）
Documents/Research/Device-Validation.md    实测记录与未验证清单
Documents/Plan/Milestone-1.md              构建顺序、路径规则
Packages/ApelinKit/Sources/ApelinBuild/    编译/链接/步骤强制、打包
Packages/ApelinFormats/Sources/ApelinMachO Apelin 的指针签名判据
Packages/ApelinFormats/Sources/ApelinCodeSign  ldid 等价签名（XML+DER）
Packages/ApelinAgent/.../Skills/BuiltIn/   tweak-development / tweak-runtime /
                                           bootstrap-paths / packaging-and-install
Apelind/**、Workers/**                     认证、特权隔离、任务模型、日志与崩溃
```

### 8.3 一条判断准则

> **凡是"只在真机上才暴露、且暴露时没有错误码"的东西，都值得写成闸门或检查单；Apelin 的价值就在于它把这类东西写死了。**

我们照这个准则继续加闸门，而不是照抄它的 IDE。
