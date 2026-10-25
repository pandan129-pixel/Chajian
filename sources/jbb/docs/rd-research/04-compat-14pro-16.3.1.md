# iPhone 14 Pro / iOS 16.3.1 能否安装 roothide Dopamine 3.x —— 源码级兼容性核查

- 设备：iPhone 14 Pro（iPhone15,2，A16 / t8120，arm64e）
- 系统：iOS 16.3.1（Build **20D67**）
- 现状：已越狱，RootHide（roothide 的 Dopamine 2.x，bootstrap 走 roothide Procursus）
- 核查对象：`roothide/Dopamine-roothide`，本地源码 `/Users/dan/Desktop/iphone/rd-3x`，commit `24ea745`（root commit，导出树）
- 上游基线：`opa334/Dopamine` 3.x 分支 `13b26789`（= 3.0.12）；roothide 基线 basebin `.version = 3.0.12`、`.version-roothide = 28`
- 官方 3.x release：tag **`28`**，release 名 **`3.x`**，发布于 **2026-10-24T20:45:36Z**（commit `e180427d`，与本地关键文件逐字节一致）
- 核查时间：2026-10-24

---

## 0. 结论（先看这段）

**能装，但属于“有条件能装 + 现在还没有成品包”。**

| 问题 | 结论 |
|---|---|
| A16 + iOS 16.3.1 是否在支持范围 | **在**。走 **PPL 路线**（不是 SPTM/TXM），支持串为 `iOS 15.0 - 17.3.1 (PPL)` |
| 该版本实际会用哪套链 | 内核 **physpuppet**（priority 1000）+ PPL **dmaFail**（priority 1000）；Titan / landa 等为备选 |
| 现在能不能直接下载安装 | **不能“下载即装”**：`3.x` release **没有任何 ipa/tipa 资产**，只有源码。必须自编译（或等官方补包） |
| 已有 RootHide 能否原地升级 | **可以**。TrollStore 覆盖安装同 bundle id 的新 app → 全重启 → 重新越狱；代码上只替换 `/basebin`，bootstrap 与已装 tweak 保留 |
| 会不会抹掉现有越狱/tweak | 正常升级路径**不会**；但点 “Remove Jailbreak” 或抹机/升级会全部丢失（不可降级） |
| 需要 blobs / 降级吗 | **不需要**，也不要做。留在 16.3.1 即可；16.3.1 早已停签，升级后无法回头 |
| 主要风险 | 3.x 是全新 basebin；首次 jbupdate 会**强制整机重启一次**；semi-untethered 重启即失效；银行/检测类 app 兼容性问题照旧 |

一句话：**你的机器在官方支持矩阵内，技术上能装；当前真正的门槛是“没有现成 tipa，需要自己 build”，其次是“新 basebin 首次升级要整机重启 + 做好备份”。**

---

## 1. 版本分支判定：A16 / 16.3.1 走 PPL，不是 SPTM

关键代码 `Application/Dopamine/Jailbreak/DOEnvironmentManager.m`：

- `isArm64e`（218–224 行）：读 `hw.cpusubtype`，`& ~CPU_SUBTYPE_MASK == CPU_SUBTYPE_ARM64E`。A16 上 app 进程即 arm64e → **YES**。
- `isSPTM`（226–244 行）：整个函数包在 `if (@available(iOS 17.0, *))` 内，且要求 IODeviceTree `chosen/memory-map` 同时含 `SPTM` 与 `TXM`。**16.3.1 < 17.0 → 直接返回 false**。
- `versionSupportString`（246–266 行）：

```objc
if ([self isArm64e]) {
    if (cpuFamily == CPUFAMILY_ARM_VORTEX_TEMPEST || cpuFamily == CPUFAMILY_ARM_LIGHTNING_THUNDER) {
        return @"iOS 15.0 - 18.7.1, 26.0 - 26.0.1 (A12/A13, PPL)";
    }
    else if (![self isSPTM]) {
        return @"iOS 15.0 - 17.3.1 (PPL)";      // ← A14/A15/A16/A17 在 17.3.1 及以下走这里
    }
    else {
        return @"iOS 17.0 - 17.3.1 (SPTM)";
    }
}
```

A16 的 `hw.cpufamily = CPUFAMILY_ARM_EVEREST_SAWTOOTH`（`BaseBin/libjailbreak/src/machine_info.h:46-49`，`DOExploit.m:104-106` 映射为 `"A16"`），不属于前两个 A12/A13 家族；16.3.1 又 `isSPTM == false`。

→ **命中的是 `iOS 15.0 - 17.3.1 (PPL)`，主界面副标题就会显示这串**（`UI/DOMainViewController.m:78`）。

旁证：

- `isPACBypassRequired`（784–792 行）：`@available(iOS 15.2, *)` 起返回 NO → 16.3.1 **不需要 PAC bypass**。
- `isPPLBypassRequired`（794–797 行）：`return [self isArm64e];` → A16 **必须**有 PPL bypass，否则 `isSupported` 为假、按钮变 “Unsupported”（`DOJailbreaker.m:176-215`）。

---

## 2. Exploit 矩阵：16.3.1 / A16 / 20D67 上真正可用的组合

匹配逻辑在 `Application/Dopamine/Jailbreak/DOExploit.m:67-187`：

1. `DPSupportedRanges` 做版本区间判断（`NSString` + `NSNumericSearch`，120–130 行）；
2. `DPSupportedDevices` 可选，匹配机型（`iPhone15,2`）或 CPU 名（`A16`）（132–145 行）；
3. **注意语义**：`_supported ? DPSupportExclude : DPSupportInclude`（147 行）——**`Include` 只在区间/机型不匹配时才用来“补充放行”**，`Exclude` 只在已匹配时用来“排除”。所以 16.3.1 上那些 `23B…`/`21E…` 的 Include 构建号不参与判断。
4. 优先级：`DOExploitManager.m:37-46`，**数值越大越优先**；设置页列表也按优先级降序（`UI/Settings/DOSettingsController.m:166-171`）。

### 2.1 内核 exploit（EXPLOIT_TYPE_KERNEL）

| Exploit / flavor | 优先级 | 支持区间 | 设备条件 | 16.3.1 A16 | 说明 |
|---|---|---|---|---|---|
| **physpuppet**（kfd） | **1000** | 16.0 – **16.3.1** | 无 | ✅ **默认首选** | `Exploits/kfd/Info.plist:31-51`（区间 48–51 行）；16.3.1 恰好是上界 |
| **landa**（kfd） | 900 | 16.0 – 16.6.1（另有 15.0–15.8.6） | 无 | ✅ 备选 | `kfd/Info.plist:7-27` |
| ClearSword | 895 | 15.0 – 18.7.1 | 无（需 `contiguousMapping` 能力） | ✅ 备选 | `ClearSword/Info.plist:9-28`；`DPExploitRequirements` = contiguousMapping |
| DarkSword | 890 | 15.0 – 18.7.1 | 无 | ⚠️ 在列表但不可靠 | `DarkSword/Info.plist:9-28`；上游明确 “DarkSword race fails on early iOS 16 (16.0–16.3.1)” |
| smith（kfd） | 600 | 16.0 – 16.5 | 无 | ✅ 备选 | `kfd/Info.plist:55-...` |
| multicast_bytecopy | 950 | 15.0 – 15.1.1 | — | ❌ | 版本不符 |
| weightBufs | 800 | 15.2 – 15.5 | 排除 arm64 | ❌ | 版本不符 |
| palera1n | 0 | 15.0 – 18.999 | 过滤条件写在 `DPSupportInclude` 的 `arm64` 里 | ⚠️ 名义上“可用”但永不被选 | `palera1n/Info.plist`：由于区间已覆盖 16.3.1，`Include` 不参与判断（见上文第 3 点语义），所以 arm64 过滤实际不生效；好在优先级 0，不会被选中 |

> `kfd.m:120-137` 只按 flavor 字符串分派 `puaf_physpuppet / puaf_smith / puaf_landa`，没有再按版本/芯片二次拦截；实际门禁完全由 Info.plist 决定。

### 2.2 PPL bypass（EXPLOIT_TYPE_PPL，A16 必需）

| Exploit | 优先级 | 支持区间 | 设备条件 | 16.3.1 A16 | 说明 |
|---|---|---|---|---|---|
| **dmaFail** | **1000** | 15.0 – 16.5.1 | 排除：`A15/A16` 且 build `20F75` | ✅ **默认首选** | `dmaFail/Info.plist:9-17`；排除项 20–31 行只针对 16.5/16.5.1 的那个 build，**20D67 不命中**，故仍支持 |
| **Titan** | 999 | **16.1 – 17.3.1** | 显式含 `A14/A15/A16/A17` | ✅ 备选 | `Titan/Info.plist:9-24`（A16 在 15 行，区间 21–24 行） |
| momentarius | 999 | 15.0 – 26.0.1 | 仅 `A12/A13` | ❌ | `momentarius/Info.plist:9-24` |
| badRecovery | 1000 | 15.0 – 15.4.1 | — | ❌ | 且类型是 PAC |

**dmaFail 对 A16 是显式支持的**，不是“顺便兼容”：

```c
// Exploits/dmaFail/dmaFail.c:383-396
switch (cpuFamily) {
    case 0x8765EDEA: // A16
        gGFXBase    = 0x23B700408;
        gDMACommand = 0x1F0023FF;
        gDMAIndex  = 8;
        gDMAMask   = 0x7FFFFFF;
        gIsA15A16  = true;      // A16 需要额外的 0x206150020 备份/恢复
```

`dmaFail.c:340-352` 里 `gIsA15A16` 会多做一次寄存器保存/恢复，这正是 A15/A16（新 GPU）专属流程。

### 2.3 最终判定

`DOEnvironmentManager.m:799-816`：

```
有 Kernel exploit（physpuppet/landa/…）        ✅
且 PAC 不需要（16.3.1 ≥ 15.2）                 ✅ 免检
且 PPL 不需要 或 有 PPL exploit（dmaFail/Titan）✅
→ isSupported = true
```

→ **主界面不会显示 “Unsupported”，Jailbreak 按钮可点**（`DOMainViewController.m:126,164`）。
→ 实际执行顺序：physpuppet → （跳过 PAC）→ dmaFail → 建 physrw（`DOJailbreaker.m:176-232`）。

> ClearSword/DarkSword 虽然也在可用集合里，但优先级低于 physpuppet，**默认不会被选中**；它们的 `contiguousMapping` respring 前置（`DOJailbreaker.m:826-843`）在默认配置下也不会触发。

---

## 3. A16 / 芯片层面的额外门槛核查

| 检查项 | 结果 | 证据 |
|---|---|---|
| 是否存在 A16 全量排除 | **没有**。全仓库 plist 中 A16 只出现两次：dmaFail 的 `20F75` 排除、Titan 的白名单 | `grep -rn "A16" Application/Dopamine/Exploits/*/Info.plist` |
| A16 是否需要 TXM | 否。TXM 只在 `isSPTM` 检查里与 SPTM 成对出现，且仅 iOS 17+ 才执行 | `DOEnvironmentManager.m:226-244` |
| A16 是否需要 SPTM bypass | 否，16.3.1 走 PPL | 同上 + 第 1 节 |
| 是否需要 PAC bypass | 否（>=15.2） | `DOEnvironmentManager.m:784-792` |
| 是否有 “只有 A12/A13 才支持 16.7+/18.x” 的影响 | 无。那是 18.x/26.x 分支，与本机无关 | `Dopamine.md:5` |
| A16 是否有 jitbox/offset 特殊处理 | 有，属于适配而非限制：`BaseBin/libjailbreak/src/info.c:52-58`（hasJitbox 含 A16），并按 CPU family / darwin 版本调整 task-jitbox 偏移 | `info.c:52-58` |
| 硬件型号白名单 | 无 iPhone15,2 级别的封锁；只有 `DPSupportedDevices` 里按 CPU 家族/机型名匹配 | `DOExploit.m:132-145` |

补充：上游 3.0 release notes 明确写了 “**Add Titan PPL/SPTM bypass … introduces support for all devices running 16.5.1 - 17.3.1**”，也就是 3.x 的 PPL 覆盖面本来就把 16.x 全段算进去了；16.0–16.5.1 这一段继续由 dmaFail 承担（本机正落在这一段）。

---

## 4. 安装方式：三条路，门槛与代价不同

### 4.1 现状：3.x 还没有成品包

GitHub API 实查：

- release：`tag_name = "28"`，`name = "3.x"`，`published_at = 2026-10-24T20:45:36Z`
- **`assets = []`**（没有 `Dopamine.ipa` / `Dopamine.tipa`）
- body 只有一句“现已开源” + X 链接

对比上一个 2.x：`tag 27`（2.4.9.27）带 `Dopamine.ipa` 与 `Dopamine.tipa`（各 ~54.8 MB）。

构建产物由 workflow 生成：`.github/workflows/main.yml` 最后两步分别上传 `roothide-Dopamine-<ver>.ipa` 和 `.tipa`，**产物是 GitHub Actions artifact（zip），不是 release 资产**。BUILD.md 给的官方路径就是：fork → Actions → “build ipa/tipa file” → Run workflow → 下载 artifact → 在设备上解压得到 `.tipa`。

> 所以“今天能不能装”的第一道门槛不是系统版本，而是**你得先有包**。

### 4.2 三种安装方式对比

| 方式 | 可行性 | 有效期 | 前置条件 | 备注 |
|---|---|---|---|---|
| **TrollStore（.tipa）** | ✅ 最推荐 | 永久（配合 Persistence Helper） | 设备已有 TrollStore；16.3.1 完全支持 | 保留 `platform-application`、`no-sandbox` 等 entitlements（`Application/Dopamine/Dopamine.entitlements`），行为最接近官方 |
| **自签 .ipa（AltStore / Sideloadly / PlumeImpactor）** | ⚠️ 官方 Dopamine 支持，roothide 分支有争议 | 免费账号 **7 天**重签 | 电脑 + Apple ID；iOS 16+ 还要开 Developer Mode | roothide 仓库 issue #20 中维护者曾回 “it can be only installed via trollstore”；但 2.x 一直同时发 `.ipa`，官方站也有 “Guide (No TrollStore)”。**能用 TrollStore 就别自签** |
| **已有 RootHide 原地升级** | ✅ 推荐路径 | 同 TrollStore | 现有 roothide Dopamine 2.x + TrollStore | 见 §4.3；不抹 bootstrap/tweak |

`.ipa`/`.tipa` 的差别只是打包名：`Application/Makefile:3-16` 里先 `ldid -S Dopamine.entitlements` 做 ad-hoc 签名，再 `zip`，然后 `cp Dopamine.ipa Dopamine.tipa`。

### 4.3 从现有 RootHide（2.x）升级到 3.x 会发生什么

代码路径（`Application/Dopamine/Jailbreak/DOBootstrapper.m`）：

1. 扫描 `/var/containers/Bundle/Application/.jbroot-*`；发现带 `.installed_dopamine` 的 jbroot → **保留**（1196–1200 行）。
2. `find_jbroot()` 命中 → 走 “device is strapped” 分支 → `ReRandomizeBootstrap`（**只重命名/迁移 jbroot 目录，不动包内容**，1231–1240 行）。
3. 随后 **只删除并替换 `/basebin`**，解压 app 内置的 `basebin.tar`（1319–1336 行），再修 LaunchDaemon plist。
4. bootstrap 大版本没变：`getCFMajorVersion()` 在 iOS 16 上固定返回 **1900**（1036–1043 行），与 2.4.9.27（rd27 同函数，920–926 行）**完全一致** → 不会重装 bootstrap、不会清空 Sileo 包。

结论：

- **已装 tweak / Sileo 包 / 源配置保留**（它们都在 jbroot 的 `/var`、`/usr` 下，只有 `/basebin` 被替换）。
- `.installed_dopamine` 标记会从 `2`（2.x 的 `DOPAMINE_INSTALL_VERSION`，rd27:857）更新为 `3`（3.x，985 行），这是预期行为。
- jbroot 目录名会重新随机化，个别硬编码 `.jbroot-XXXX` 路径的第三方脚本需要重新指向。
- **首次 jbupdate（2.x→3.x）会强制整机重启一次**（上游 3.0 release notes: “A jbupdate from an earlier versions will trigger a full reboot by design”）。
- 如果当前越狱仍处于激活状态，直接点 Jailbreak 会被拦：`otherJailbreakActived(true)` → “Your device currently has another jailbreak activated, please reboot device.”（`DOJailbreaker.m:320`，实现 `BaseBin/libroothider/src/common.m:502-570`）。**必须先整机重启再越狱。**

### 4.4 最低 iOS 版本 / blobs / 降级

- App 部署目标 `IPHONEOS_DEPLOYMENT_TARGET = 15.0`（`Application/Dopamine.xcodeproj/project.pbxproj:2464` 等），bootstrap 也对 iOS 15 有分支（`getCFMajorVersion` 的 CF 版本回退）。**16.3.1 远高于最低要求。**
- **不需要 blobs**：你只是换越狱工具，不换系统。
- **不要升级/抹机**：16.3.1 早已停止签名，升级到 16.7/17.x/18.x 后既回不来，也会掉出 A16 的 17.3.1 上限（`versionSupportString` 的 PPL 分支最高 17.3.1）。没有 blobs 的情况下抹机 = 永久失去 16.3.1。

---

## 5. GitHub Issues 调查（roothide/Dopamine-roothide，state=all，共 147 条）

方法：`/issues?state=all&per_page=100` 分页 3 页 + 关键词（16.3 / 14 Pro / 14pm / A16 / install / JBError）。**截至核查时没有任何 3.x 装机反馈**（release 只有几小时），以下均为 2.x 时代的同机型/同系统证据，用来判断“这台机器本身能不能跑”。

| Issue | 状态 | 与本任务的关系 |
|---|---|---|
| [#96](https://github.com/roothide/Dopamine-roothide/issues/96) Freeze when opening the mail then rebooting. **Device: ip 14 pro ios 16.3.1** | closed | 同机型同系统实跑过 2.x；roothider 回复 “fixed in a3c31b2”（2.x 修复）。说明 14 Pro/16.3.1 是活跃支持组合 |
| [#70](https://github.com/roothide/Dopamine-roothide/issues/70) 16.3.1 更新 2.4.5 会卡死 | open | 16.3.1 上 2.4.5 的回归：黑名单模式易卡死，用户回退 2.2.2；**升级前建议先确认当前 2.x 版本稳定** |
| [#29](https://github.com/roothide/Dopamine-roothide/issues/29) 14pm 16.4.1 | closed | 14 Pro Max / 16.4.1：首次越狱很快，重启后再越狱成功率低、卡在初始化环境。对应 semi-untethered 的“重越失败要重试”特性 |
| [#116](https://github.com/roothide/Dopamine-roothide/issues/116) Revolut Business 检测 RootHide | open | 明确写 “iOS 16.3.1, iPhone 14 Pro Max, RootHide Dopamine 2.4.5.21” → 同机型同系统在跑 2.4.5 |
| [#143](https://github.com/roothide/Dopamine-roothide/issues/143) Sacombank | open | “14 ProMax A16 / iOS 16.3 / Dopamine 2.4.9.25” → A16 + 16.3.x 在 2.4.9 上可运行 |
| [#119](https://github.com/roothide/Dopamine-roothide/issues/119) / [#118](https://github.com/roothide/Dopamine-roothide/issues/118) DarkSword 支持范围 | open/closed | 引用上游 2.5b1：**“DarkSword race fails on early iOS 16 (16.0–16.3.1)”**。对本机无影响（默认 physpuppet），但**不要手动把内核 exploit 切成 DarkSword** |
| [#146](https://github.com/roothide/Dopamine-roothide/issues/146) / [#147](https://github.com/roothide/Dopamine-roothide/issues/147) 求 Dopamine 3 / iOS 18 支持 | open | 社区长期在催 3.x 集成；2026-10-24 的 3.x 开源就是对这类请求的回应 |
| [#20](https://github.com/roothide/Dopamine-roothide/issues/20) Sideloadly 安装失败 | open | 自签报 `Guru Meditation … FieldError`；维护者回 “it can be only installed via trollstore” → **自签有坑，优先 TrollStore** |
| [#28](https://github.com/roothide/Dopamine-roothide/issues/28) workflow 构建的包 TrollStore 装不上 | open | 官方答复：artifact 下载下来是 **zip**，要解压出 `.tipa`；另需较新 TrollStore |
| [#25](https://github.com/roothide/Dopamine-roothide/issues/25) Jailbreak failed | open | 用 apt/sudo 装包可能破坏 roothide 符号链接（`.jbroot-xxxx/bin/.jbroot -> "."`），升级前别乱动 apt |
| [#155](https://github.com/roothide/Dopamine-roothide/issues/155) 越狱后触摸失效 | open | 换过屏的机器（非原装屏）常见；原厂屏不受影响 |
| [#153](https://github.com/roothide/Dopamine-roothide/issues/153) iPad 5 卡在 Exploiting kernel | open | 老设备/老版本卡 exploit；A16 不在其列 |
| [#100](https://github.com/roothide/Dopamine-roothide/issues/100) “Remove Jailbreak” 会不会连 rootless 一起删 | open | 提示：Remove Jailbreak 是破坏性操作，升级时**不要点** |

**Issue 侧的净结论**：没有 “A16/16.3.1 不支持” 的报告；同机型同系统在 2.4.5/2.4.9 上大量实跑。已知痛点集中在“重越成功率 / 检测绕过 / 换屏 / 自签安装”，与 3.x 的版本支持无关。

---

## 6. 与原版 Dopamine 3.x 的差异

| 维度 | 原版 `opa334/Dopamine` 3.x | roothide 分支 | 是否影响 16.3.1/A16 |
|---|---|---|---|
| 支持矩阵（文案） | 官网：`iOS 15.0 - 17.3.1 (A14 - A17 / M1 - M2)`；`15.0 - 18.7.1 / 26.0 - 26.0.1 (A8 - A13)` | 无独立矩阵声明，沿用同源代码 | 无差异 |
| `versionSupportString` | 同（本地 246–266 行） | 同 | 无 |
| Exploit 清单 / 区间 / 优先级 | 基线 3.0.12 | **逐字节相同**：dmaFail、kfd、Titan、ClearSword、momentarius 的 `Info.plist` md5 与上游 `3.x` 完全一致 | 无 |
| basebin | 3.0.12 | 3.0.12 + roothide 28 | 隐藏/引导层差异 |
| 越狱根 | `/var/jb`（rootless） | 随机化 `.jbroot-XXXX`（roothide） | 影响路径写法，不影响兼容性 |
| 隐藏能力 | 无 | RootHide（对 app 隐藏越狱痕迹） | 本机现有环境的核心价值 |
| 包管理源 | Procursus | roothide Procursus（`DOBootstrapper.m:1014-1032`） | 已有源可继续用 |
| 安装/更新 | ipa/tipa + 官方 guide | 同 + `jbctl update tipa`（依赖 TrollStore，`BaseBin/jbctl/src/main.m:184-210`） | 升级方式略不同 |

> 也就是说：**3.x 对 16.3.1/A16 的支持判定完全来自上游 3.0.12，roothide 只改了“怎么藏、装在哪、怎么更新”，没有动 exploit 门禁。**

---

## 7. 风险清单

1. **semi-untethered 本质**：每次重启都回到未越狱状态，需要重新打开 Dopamine 点 Jailbreak；A16 + 16.3.1 的 physpuppet/dmaFail 组合并非 100% 一次成功，失败就重启重试（参考 #29）。
2. **首次 jbupdate 整机重启**：2.x→3.x 的环境更新按设计会 full reboot；别误以为“崩了”。若在越狱激活状态直接点 Jailbreak，会报 “another jailbreak activated”，同样需要先重启。
3. **3.x 早期版本踩过的坑**：上游 3.0–3.0.6 存在 jbupdate 期间 OOB 写导致 `/var/jb/basebin/gen/dyld.old` 损坏（3.0.7 修复）。本分支基线是 **3.0.12**，已包含修复；但这也说明 **“用最新 3.0.x，不要用早期 3.0”**。
4. **数据与回滚**：升级前做 Finder/iTunes **加密备份**；导出 `dpkg -l`、Sileo 源、tweak 配置；保留 **2.4.9.27 的 tipa**，出问题可 TrollStore 覆盖装回 2.x 再重新越狱（bootstrap 不动，理论可回退；但跨 basebin 降级非官方保证）。
5. **不要 Remove Jailbreak / 不要升级系统**：前者删 jbroot+bootstrap（tweak 全没），后者永久失去 16.3.1（无 blobs、已停签）。
6. **共存/冲突**：
   - 若你装的是 roothide 的独立 **Bootstrap** app（不是 Dopamine 内置 bootstrap），3.x 会直接拒绝并提示先 uninject + 卸载（`DOBootstrapper.m:1192`）。
   - 旧 rootless Dopamine / palera1n / 旧 Dopamine 残留会被 `otherJailbreakActived()` 识别并拦截（`common.m:502-570`）。
   - RootHide 的隐藏状态与 3.x 新 basebin 混用未经验证；升级后先确认 `roothide Manager` 正常，再逐个恢复 app 黑/白名单。
7. **检测类 app**：银行/支付/企业 app 的越狱检测是长期问题（#116、#132、#143 等），3.x 不保证改善。
8. **硬件**：换过非原装屏的机器可能出现触摸失效（#155），与越狱版本无关。

---

## 8. 可执行方案（建议顺序）

**推荐：TrollStore 原地升级（保留 tweak）**

1. 备份：Finder 加密备份 + 记录 `dpkg -l` / Sileo 源 / tweak 配置；把 `2.4.9.27` 的 tipa 留在设备上。
2. 拿到 3.x 包（二选一）：
   - 等官方在 release `28`/后续 tag 补上 `Dopamine.tipa`；或
   - fork `roothide/Dopamine-roothide` → Actions → `build ipa/tipa file` → Run workflow → 下载 artifact zip → 在设备上解压出 `.tipa`。
3. TrollStore 安装该 `.tipa`（bundle id 仍是 `com.opa334.Dopamine-roothide`，属于覆盖更新，不清 app 数据）。
4. **整机重启**（不是 respring/userspace reboot），让旧 basebin 失效。
5. 打开新版 Dopamine → Jailbreak。首次环境更新会再触发一次整机重启（设计如此）；重启后再次打开 → Jailbreak。
6. 校验：`/basebin/.version` 应为 `3.0.12`，`/basebin/.version-roothide` 应为 `28`；Sileo 能打开、源与已装包仍在；`roothide Manager` 正常。
7. 若失败：保留日志（`/var/mobile/Library/Logs/CrashReporter`），必要时 TrollStore 回装 2.4.9.27 → 重启 → 重新越狱。

**不推荐**：先 Remove Jailbreak 再全新安装（会删 bootstrap 和全部 tweak），除非你本来就打算重来。

**明确不要做**：升级 iOS、抹机、在越狱激活状态下强行点 Jailbreak、把内核 exploit 手动切成 DarkSword。

---

## 9. 证据索引

源码（本地 `/Users/dan/Desktop/iphone/rd-3x`，commit `24ea745`）：

- `Application/Dopamine/Jailbreak/DOEnvironmentManager.m:218-224` — isArm64e
- `Application/Dopamine/Jailbreak/DOEnvironmentManager.m:226-244` — isSPTM（iOS 17+ 且需 SPTM+TXM）
- `Application/Dopamine/Jailbreak/DOEnvironmentManager.m:246-266` — versionSupportString（A16/16.3.1 → `iOS 15.0 - 17.3.1 (PPL)`）
- `Application/Dopamine/Jailbreak/DOEnvironmentManager.m:784-797` — PAC/PPL 需求判定
- `Application/Dopamine/Jailbreak/DOEnvironmentManager.m:799-816` — isSupported 组合逻辑
- `Application/Dopamine/Jailbreak/DOEnvironmentManager.m:292-301,331-338` — roothide 越狱状态/版本读取
- `Application/Dopamine/Jailbreak/DOExploit.m:67-187` — exploit 匹配（区间/机型/include-exclude）
- `Application/Dopamine/Jailbreak/DOExploit.m:104-106` — A16 → `CPUFAMILY_ARM_EVEREST_SAWTOOTH`
- `Application/Dopamine/Jailbreak/DOExploitManager.m:37-46` — 优先级选择
- `Application/Dopamine/Exploits/kfd/Info.plist:7-27,31-51,55-...` — landa / physpuppet / smith
- `Application/Dopamine/Exploits/dmaFail/Info.plist:9-17,20-31` — PPL 1000，15.0–16.5.1，20F75+A15/A16 排除
- `Application/Dopamine/Exploits/dmaFail/dmaFail.c:383-396` — A16 专属 GPU 参数
- `Application/Dopamine/Exploits/Titan/Info.plist:9-24` — PPL 999，16.1–17.3.1，含 A16
- `Application/Dopamine/Exploits/ClearSword/Info.plist:9-28`、`DarkSword/Info.plist:9-28` — 895/890，15.0–18.7.1
- `Application/Dopamine/Jailbreak/DOJailbreaker.m:176-232` — 实际执行链（Kernel → PAC → PPL）
- `Application/Dopamine/Jailbreak/DOJailbreaker.m:320` — 旧越狱激活时拦截
- `Application/Dopamine/Jailbreak/DOBootstrapper.m:985` — `DOPAMINE_INSTALL_VERSION 3`（2.x 为 2）
- `Application/Dopamine/Jailbreak/DOBootstrapper.m:1036-1043` — `getCFMajorVersion()` = 1900（iOS 16）
- `Application/Dopamine/Jailbreak/DOBootstrapper.m:1196-1200,1217-1243` — 保留已有 jbroot / ReRandomize
- `Application/Dopamine/Jailbreak/DOBootstrapper.m:1319-1336` — 仅替换 `/basebin`
- `Application/Dopamine/Jailbreak/DOBootstrapper.m:1192` — 独立 roothide Bootstrap 冲突提示
- `Application/Dopamine/UI/DOMainViewController.m:126,164,198-199` — isSupported 控制按钮
- `Application/Dopamine/UI/Settings/DOSettingsController.m:166-236` — exploit 选择器（按优先级）
- `Application/Dopamine/UI/Update/DOUpdateViewController.m:133-142` — roothide 分支的更新入口（Reboot / releases 页）
- `Application/Dopamine/Dopamine.entitlements`、`Application/Makefile:3-16` — entitlements 与 ipa/tipa 打包
- `BaseBin/jbctl/src/main.m:184-210` — `jbctl update tipa` 依赖 TrollStore
- `BaseBin/libroothider/src/common.m:502-570` — otherJailbreakActived
- `Application/Dopamine.xcodeproj/project.pbxproj:2464` — 部署目标 15.0
- `Dopamine.md:5` — 支持矩阵文案

网络证据：

- Release `3.x`（tag 28，无资产）：https://github.com/roothide/Dopamine-roothide/releases/tag/28
- Release `2.4.9.27`（有 ipa/tipa）：https://github.com/roothide/Dopamine-roothide/releases/tag/27
- 官方 Dopamine 支持矩阵：https://ellekit.space/dopamine/ （`iOS 15.0 - 17.3.1 (A14 - A17 / M1 - M2)`）
- 官方安装指南（自签/7 天）：https://ios.cfw.guide/installing-dopamine/
- 官方安装指南（TrollStore）：https://ios.cfw.guide/installing-dopamine-trollstore/
- 上游 3.0 release notes（Titan 覆盖 16.5.1–17.3.1；jbupdate 会整机重启）：https://github.com/opa334/Dopamine/releases/tag/3.0
- Issues：#96、#70、#29、#116、#143、#119、#146、#147、#20、#28、#25、#155、#100（链接见 §5）

---

### 附：本次核查的局限

- 未在真机上实际执行 3.x 越狱（3.x 无成品包，且本环境无法连接设备）；结论基于源码逻辑推演 + 同机型 issue 的间接验证。
- GitHub issue 检索为 2026-10-24 快照，3.x 上线仅数小时，**尚无 16.3.1/A16 的 3.x 实机反馈**；建议装机后关注是否出现新的 16.x 回归 issue。
- 本地 commit `24ea745` 与 tag `28` 的 commit `e180427d` 是同一改动的两个提交（父提交不同）；已逐字节比对 `DOEnvironmentManager.m`、`DOExploit.m`、`DOExploitManager.m`、`kfd/Info.plist`、`.github/workflows/main.yml`，内容一致。
