# 05 — roothide 3.x vs relaxin 现状：防检测 / 隐藏能力逐项对比

> 日期：2026-10-24
> roothide 基线：`/Users/dan/Desktop/iphone/rd-3x`，commit `24ea745`（"add roothide support for Dopamine 3"），只读分析。
> relaxin 基线：`/Users/dan/Desktop/iphone/relaxin-src`（15 个文件：4 个 engine + 11 个 vendor 子集）。
> jb-bypass 基线：`HANDOVER.md`、`docs/S2-detection-matrix.md`、`reports/S10`、`S13`、`S14`。
> 方法：纯静态源码对照；**未修改任何源码、未连接设备**。
>
> **证据边界（重要）**：`relaxin-src` 是裁剪快照，不含 launchdhook 的 `main.m`/`spawn_hook.c`/`jbserver/*`、`xpc_hook.m`、`unsandbox.m`、`blacklist.m`、`jbctl`。因此下文“relaxin 未见实现”一律指**本仓库内不可见**，不等于完整工程一定没有。凡涉及“缺失”的结论都标注了判断依据；需要真机/完整仓库确认的点集中在 §11。

---

## 0. 结论速览

### 0.1 十条关键判断

1. **两边默认都不用 patched dyld。** roothide 3.x 的 `dyldPatchEnabled` 默认值是 `NO`（`Application/Dopamine/Jailbreak/DOJailbreaker.m:635`，设置项默认值同 `Application/Dopamine/UI/Settings/DOSettingsController.m:265-276`）；relaxin 则明确写死“stock dyld / patched-dyld disabled”（`engine/RLXSystemHookActivationTask.m:44-46,83`）。所以**差异不在“是否 patch dyld”，而在环境/命名/黑名单/进程隐藏/信任链**。
2. **两边默认都靠 `CS_GET_TASK_ALLOW` + `DYLD_INSERT_LIBRARIES` 注入。** `proc_patch_csflags()` 给每个子进程置位（rd-3x `BaseBin/libroothider/src/common.m:25-37,218-225`；relaxin 同文件 `:28-49,185-196`）。这带来同一个最大破绽：`csops(CS_OPS_STATUS)` 能看到 release App 竟然有 get-task-allow。jbb v5/v6 目前**没有** hook `csops`（`src/jbb_v5.c`、`src/jbb_v6.c` 全文 grep 无 `csops`）。
3. **relaxin 的“激活”步骤是从 roothide 3.x 的 first-load 引导块整段复刻的**：`DOJailbreaker.m:736-766` ↔ `RLXSystemHookActivationTask.m:59-79`，连 `killall -9 iconservicesagent` 都一样。差别是 roothide 在 userspace reboot 后的 normal load 会把注入路径收敛为 `HOOK_DYLIB_PATH=/usr/lib/systemhook-<jbrand>.dylib`（`launchdhook/src/roothider.m:104-118`），relaxin 树内只有改名、没有 launchd 侧环境收敛。
4. **relaxin 的 dyldhook 只有 1/7**：只有 `expandAtLoaderPath` 的 `@loader_path/.jbroot` 改写（`dyldhook/src/roothider.c:12-55`），缺 `main.c`（jbinfo checkin）、`reimpl.c`、`lv_bypass.c`、`generated/*/task.c`、`fakelib_redirect`。更关键的是 relaxin 不做 dyldhook checkin，`jbinfo_get_jbroot()` 永远为 NULL，这段 hook 实际是**死代码**（`dyldhook/src/roothider.c:47-51` 的 `if (jbroot)` 永不成立）。
5. **roothide 3.x 自己也不隐藏 dyld 镜像。** 全仓库没有 `_dyld_get_image_name` / `all_image_infos` 的过滤实现，反而在自己的检测函数里枚举镜像（`libroothider/src/common.m:560-565`）。这与 jb-bypass S10 实测“Settings 里能看到 12 条越狱镜像”一致。dyld 层隐藏目前**只有 jbb 提供**。
6. **roothide 3.x 删掉了 2.x 的“Hide Jailbreak”全局开关。** `DOEnvironmentManager.m:626-703` 整段（`isJailbreakHidden` / `setJailbreakHidden` / fakelib 卸载 / preboot 解保护）被 `/* */` 注释，`DOSettingsController.m:323-345,728-735` 同样注释。结果是 `/var/jb -> <jbroot>` 常驻（`DOBootstrapper.m:249-265`）。fakelib 的主路径也不再挂载：`DOJailbreaker.m:445-488,728-734` 的 `createFakeLib` 调用与实现均被注释，`jbctl` 的 `fakelib_set_mounted` 也在注释块内（`jbctl/src/internal.m:6-95`）；只有 Standalone CLI 的 `activate_basebin` 还调用 `setFakelibMounted:`（`BaseBin/dopamine/src/main.m:132`），而该方法实现同样在注释里（`DOEnvironmentManager.m:626-703`），该路径是否可达需完整工程确认。**3.x 的文件痕迹比 2.x 更重**，只能靠 per-app 黑名单或 tweak 兜底。
7. **roothide 的黑名单 = 完全不注入**（`launchdhook/src/roothider.m:429-486` + `libroothider/src/blacklist.m:53-94`）。这是对付“注入即检测”类 App 唯一干净的手段；代价是 jbb 也不会加载（jbb 依赖注入）。jb-bypass 的 `stealth` 模式就是这条路。
8. **relaxin 缺 roothidehooks 的主体实现。** 只剩 dispatcher（`roothidehooks/main.m:16-31`）和一个 `__CFCopyHomeDirURLForUser`（`pathhook.m:6-37`）；`lsd.x` / `cfprefsd.x` / `springboard.x` / `runningboardd.x` 全部不在树内。且 dispatcher 调 `runningboarddInit()`，roothide 3.x 导出的是 `rbdInit()`（`roothidehooks/src/runningboardd.x:74`）——**符号名不匹配**。
9. **日志策略相反。** roothide 3.x 默认把日志编译掉（`libroothider/src/log.h:1` `// #define ENABLE_LOGS`）；relaxin 的 systemhook 强制 `-DSYSTEMHOOK_LOG_BACKEND_SYSLOG=1`（`systemhook/Makefile:5`）。按宏名与条件编译结构推断，这会把 systemhook 日志改走 syslog 后端（`log.h` 本身不在快照内，需完整仓库确认），至少与 roothide 的“默认静默”方向相反。
10. **trustcache 各有优劣。** roothide 用固定 UUID `"BASEBIN"`（`libjailbreak/src/trustcache.h:11`，`libroothider/src/common.m:491`）；relaxin 走 `jb_trustcache_append_entries`，UUID 由 `uuid_generate` 随机（`trustcache.c:13-17,134-152`）——更难按 UUID 指纹识别；但 relaxin 的 `trustcache.c` 缺 iOS 17+ TXM 分支（对比 rd-3x `libjailbreak/src/trustcache.c:29-34`）。

### 0.2 能力矩阵

| 维度 | roothide 3.x | relaxin（本仓库） | 谁更强 |
|---|---|---|---|
| 随机 jbroot / 命名 / 轮换 | ✅ `.jbroot-%016llX`，含校验位与 ReRandomize | ❌ 仅把 tar 解到调用方给的 root | roothide |
| jbroot 传递 | ✅ dyld `__jbinfo` + mach checkin + sandbox extension | ⚠️ 依赖外部 libjailbreak；树内只见 `gSystemInfo.rootPath` | roothide |
| 路径 hook（syscall 层） | ❌ 不做（结构隐藏 + libroot shim + 黑名单） | ❌ 不做（同） | 平（都靠 jbb） |
| 路径 hook（ObjC/服务层） | ✅ cfprefsd/lsd/springboard/runningboardd | ❌ 只剩 `__CFCopyHomeDirURLForUser` | roothide |
| dyld 层（装载/重定向） | ✅ 完整 dyldhook + dyld patch 生成链（默认不启用） | ⚠️ 只有 `expandAtLoaderPath` 半截且失效 | roothide |
| dyld 镜像隐藏 | ❌ | ❌ | 都靠 jbb |
| 注入环境清理 | ✅ ctor 里 unset `DYLD_IN_CACHE`/`DYLD_SHARED_REGION`/`DYLD_INSERT_LIBRARIES` | ⚠️ 只 unset `DYLD_IN_CACHE`（`DYLD_INSERT_LIBRARIES` 在 systemhook ctor 里 unset），无 `DYLD_SHARED_REGION` | roothide |
| per-app 黑名单（不注入） | ✅ RootHideConfig `appconfig` + 全链路 | ❌ 树内无实现（只有调用点） | roothide |
| launchd job/pid/端口隐藏 | ✅ XPC hook + mach alt port | ❌ | roothide |
| crash log / 日志痕迹 | ⚠️ 日志关闭；但 jb daemon 崩溃会写完整镜像列表 | ⚠️ 无 crashreporter；日志走 syslog 后端（按 Makefile 宏推断） | roothide 略好 |
| trustcache 指纹 | ⚠️ 固定 UUID `BASEBIN` | ✅ 随机 UUID | relaxin |
| iOS 17+ TXM | ✅ | ❌ | roothide |

---

## 1. jbroot 随机根：生成 / 命名 / 传递 / 轮换

### 1.1 roothide 3.x 实现

| 环节 | 位置 | 要点 |
|---|---|---|
| 生成 | `Application/Dopamine/Jailbreak/DOBootstrapper.m:944-949` | `jbrand_new()`：两个 `arc4random()` 拼 64 位，最后一个字节是前 7 字节 XOR 校验（`:958-962`） |
| 命名 | `DOBootstrapper.m:879-899` | 目录名固定 16 位十六进制：`.jbroot-%016llX`；`is_jbroot_name()` 同时校验长度、前缀、hex、校验位 |
| 查找 | `DOBootstrapper.m:920-942` | 遍历 `/var/containers/Bundle/Application/` 找合法名；缓存 |
| 主根 | `DOBootstrapper.m:1081-1082` | `mkdir <...>/.jbroot-XXXX 0755` + `chown 0:0` |
| 可写副根 | `DOBootstrapper.m:1109-1124` | `/var/mobile/Containers/Shared/AppGroup/.jbroot-XXXX`；`/var`、`/tmp` 搬过去，主根里留 symlink，并互相建 `.jbroot` 链接 |
| 轮换 | `DOBootstrapper.m:1141-1175` | `ReRandomizeBootstrap`：新 jbrand → rename 两个根 → 重建 `/private/var` 与 `.jbroot` 链接 → 刷新缓存 |
| 传递（内核→进程） | `BaseBin/dyldhook/src/main.c:51-76` | checkin 结果写进 dyld 的 `__DATA,__jbinfo`（`:14-15`），systemhook 再读（`BaseBin/systemhook/src/main.c:346-372`） |
| 传递（库层） | `BaseBin/libjailbreak/src/jbroot.h:10-39`；`Packages/libroot/src/paths.c:8-11` | 编译期 `jbroot()`/`JBROOT_PATH()` 前缀；第三方越狱 App 用 `libroot_get_jbroot_prefix()` 自动拿到随机根 |
| 沙盒授权 | `BaseBin/libroothider/src/common.m:431-455`；`launchdhook/src/jbserver/jbdomain_systemwide.c:246-256` | 只对 checkin 的进程签发 jbroot 的 read / executable / read-write extension |

### 1.2 relaxin 现状

- `engine/RLXBaseBinInstaller.m:37-76` 只做五件事：`root/basebin` 存在则删（`:40-55`）→ `libarchive_unarchive(basebin.tar, root)`（`:57-65`）→ 改 plist（`:67`）→ 删 `basebin.tc`（`:69-70`）→ 写 `.AppIdentifier`（`:72-74`）。
- `:78-110` 的 plist 补丁只把 `ProgramArguments` 里的 `@JBROOT@` 换成传入的 `root`，**没有任何 jbrand 生成、命名、校验、副根、轮换逻辑**。
- `engine/RLXBaseBinTrustTask.m:73-80` 只**要求** `gSystemInfo.jailbreakInfo.rootPath` 与 `jbrand` 非空，生成方不在本仓库。
- `Vendor/.../common.m:343-391` 有 `ensure_jbroot_symlink()`，但**没有任何调用点**（对比 roothide `libroothider/src/signatures.m:215` 在每次库加载时调用）。

### 1.3 差距

1. **没有“随机”这一步。** 若上游给的是 `/var/jb`，relaxin 的全部路径退化为固定 `/var/jb`，`stat("/var/jb")` 即命中（jb-bypass `HANDOVER.md:16,45` 已记录该设备上 `/var/jb -> /`）。
2. **没有 jbrand 校验位**，也没有 `ReRandomize`，换 App（TrollStore）后无法低成本换根。
3. **没有副可写根**，所有可写数据落在主根，一旦主根在 `Bundle/Application` 下被容器清理影响，数据与越狱根同生共死。
4. **`.jbroot` 链接缺调用点**，roothide 生态的 `@loader_path/.jbroot/...` 二进制会解析失败（jb-bypass `S10 §11.1` 坑 5 正是这个）。
5. **沙盒扩展生成函数同形**（`common.m:393-431`），但 relaxin 树内没有 checkin 端，谁能拿到 jbroot 读权限不可证。

### 1.4 可移植建议

- 在 `RLXBaseBinInstaller.m` 安装前生成 jbrand（照抄 `DOBootstrapper.m:944-962`），把 `root` 改成 `.../.jbroot-%016llX` 并建立副根与互链（`:1081-1124`）；`@JBROOT@` 替换继续复用 `:78-110`。
- 把 `jbrand` 写进 `gSystemInfo.jailbreakInfo.jbrand`，并在 `RLXBaseBinTrustTask.m:73` 的现有校验上再加 `check_jbrand_value()`。
- 在 trust / dlopen 路径插入 `ensure_jbroot_symlink()`（照 `signatures.m:215`），不要靠静态 tar 里预置链接。

---

## 2. 路径 hook 覆盖面

### 2.1 先纠正一个前提

roothide 3.x **没有** syscall 级路径 hook。全仓库的路径隐藏由四层拼成：

1. 结构层：越狱文件根本不在 `/usr/lib/...`、`/Applications/...` 这些 stock 路径，而在随机 jbroot 下（`DOBootstrapper.m:1081-1124`）。
2. 编译/链接层：`jbroot()` shim（`jbroot.h:10-39`、`Packages/libroot/src/paths.c:8-11`）。
3. 运行时进程级：`redirect_paths()` / `redirect_env_paths()`（`BaseBin/systemhook/src/roothider_main.c:76-173`）。
4. 特定守护进程的 ObjC 重定向：`roothidehooks/src/cfprefsd.x:60-96`（偏好）、`lsd.x`（LaunchServices/UTType）、`springboard.x:48-57`（快照路径）。

唯一的“pathhook”文件只有 `__CFCopyHomeDirURLForUser`（`roothidehooks/src/pathhook.x:11-43`）。

### 2.2 函数级清单

| 函数 | roothide 3.x | relaxin（树内） | jbb v5 |
|---|---|---|---|
| `stat` / `stat64` | ❌ | ❌ | ✅ `jbb_v5.c:524` |
| `lstat` / `lstat64` | ❌ | ❌ | ✅ `:523` |
| `fstatat` / `fstatat64` | ❌ | ❌ | ✅ `:529` |
| `access` / `faccessat` | ❌ | ❌ | ✅ `:525-526` |
| `open` / `openat` | ❌ | ❌ | ✅ `:527-528` |
| `opendir` | ❌ | ❌ | ✅ `:533` |
| `readdir` | ❌ | ❌ | ✅ `:534` |
| `getattrlist` | ❌ | ❌ | ✅ `:535` |
| `getattrlistbulk` | ❌ | ❌ | ❌ |
| `realpath` | ❌ | ❌ | ✅ `:532` |
| `readlink` / `readlinkat` | ❌ | ❌ | ✅ `:530-531` |
| `statfs` | ❌ | ❌ | ❌ |
| `__getdirentries` / `getdirentries64` | ❌ | ❌ | ❌ |
| `fopen` | ❌ | ❌ | ✅ `:536` |
| `__CFCopyHomeDirURLForUser` | ✅ `pathhook.x:32-43` | ✅ `pathhook.m:27-37`（逐行同源） | ❌ |

> jbb 行号以 `jb-bypass/src/jbb_v5.c:520-536` 的安装段为准。

**缺哪些？**
- **roothide 与 relaxin 都缺全部 syscall 层**，这不是 relaxin 相对 roothide 的差距，而是“两家都把 syscall 层外包给 tweak”。
- **relaxin 相对 roothide 额外缺的是“结构层”和“服务层”**：没有随机根（§1）、没有 `lsd/cfprefsd/springboard/runningboardd`（§7）。
- **jbb 仍缺 3 个**：`statfs`、`getattrlistbulk`、`__getdirentries/getdirentries64`。前两个直接对应：
  - `/usr/lib` 是否被 bind mount（roothide 自己的 `otherJailbreakActived()` 就用 `statfs("/usr/lib").f_mntonname` 判断，`common.m:525-530`）；
  - `getattrlistbulk` 是 Filza/检测 SDK 常用的“批量列目录”路径，`readdir` hook 拦不到。

### 2.3 差距与移植建议

- relaxin 在本仓库内**没有**任何 syscall 层路径 hook，也没有 roothide 的结构层，所以它比 roothide 更依赖 jbb。若目标 App 不在 jbb filter 内（或走 stealth/黑名单），relaxin 的路径隐藏等于 0。
- 建议：**不要在 relaxin 里重写 syscall hook**（会与 jbb、ellekit 叠加），而是先把 §1 的随机根做出来，再补 jbb 的 3 个缺口（`statfs` / `getattrlistbulk` / `direntries`），并把 `/usr/lib/systemhook-` 与 `.jbroot-` 纳入 token（jbb 已有，`jbb_v5.c:117-162`）。
- roothide 侧可借鉴的具体实现只有偏好重定向（`cfprefsd.x:60-96`）和 UTI 隐藏（`lsd.x:409-707`），这两块 relaxin 完全没有。

---

## 3. dyld 层隐藏：dyldhook / fakelib_redirect / roothider.c

### 3.1 组件对照

| 组件 | 作用 | roothide 3.x | relaxin |
|---|---|---|---|
| `dyldhook/src/roothider.c` | `@loader_path/.jbroot` → 实际 jbroot | ✅ `:12-39` | ✅ `:12-55`（同源，含 iOS15 spinlock env） |
| `dyldhook/src/main.c` | 在 dyld 启动前 checkin，把 jbroot/UUID/extension 写进 `__jbinfo` | ✅ `:14-15,51-76,202-218` | ❌ 不在树内 |
| `dyldhook/src/reimpl.c` | dyld 内自包含的 `mach_msg`/`sandbox_extension_consume` | ✅ | ❌ |
| `dyldhook/src/lv_bypass.c` | `fcntl(F_ADDSIGS/F_ADDFILESIGS)` 库校验绕过 | ✅ `:165-296`（roothide 把 `F_ADDSIGS` 分支直接 `break`，`:179-181`） | ❌ |
| `dyldhook/src/fakelib_redirect.c` | `/usr/lib/*` dlopen 重定向到 `.fakelib` | ⚠️ 整文件 `#if 0`（`:1,57-58`） | ❌ |
| `dyldhook/src/generated/*/task.c` | 按 iOS 版本 patch dyld 内部 | ✅ | ❌ |
| `libjailbreak/src/basebin_gen.m` | 生成 patched dyld：AMFI 返回 `0xff`、UUID 加 `DOPA` 前缀、MachOMerger 合并、重签 | ✅ `:38-88,90-97,99-170` | ❌ 明确禁用 |
| `dyld` 实际启用 | 是否使用 patched dyld | ❌ 默认不启用（`DOJailbreaker.m:635`），且 fakelib 挂载已注释（`:445-488`） | ❌ 明确禁用（`RLXSystemHookActivationTask.m:44-46`） |

### 3.2 关键结论

1. **relaxin 的 `roothider.c` 是死代码。** 该函数依赖 `jbinfo_get_jbroot()`（`:47`），而 `jbinfo` 只由 `dyldhook/src/main.c:51-76` 填写；relaxin 没 vendor `main.c`，systemhook 也不走 dyldhook checkin（`systemhook/src/main.c:791-809` 走 `perform_process_checkin()`），所以 `jbinfo->state` 永远不是 `CHECKED_IN`，返回 NULL。
2. **roothide 的 dyld 层价值主要在“能装载”而不是“能隐藏”。** `expandAtLoaderPath` 只是让 jbroot 里的 `@loader_path` 依赖可解析；`lv_bypass` 是让 ad-hoc 库能映射；`basebin_gen` 是让 stock dyld 接受 `DYLD_*`。**没有任何一处过滤 `_dyld_get_image_name` / `all_image_infos`。**
3. **patched dyld 本身是强指纹。** UUID 前缀 `DOPA<version>`（`basebin_gen.m:64-84,151`），且 systemhook 自己就用 `string_has_prefix(dyldUUID,"DOPA")` 来判定（`systemhook/src/main.c:352-355`）。任何 App 都能用 `_dyld_get_image_uuid(dyldHeader)` 做同一件事。**relaxin 禁用 patched dyld 在这一点上是更安全的选择。**
4. `fakelib_redirect` 在 3.x 已被 `#if 0`，说明这条“把 /usr/lib 重定向到 jbroot 副本”的路线在 3.x 被放弃；但 `basebin_gen` 仍会复制整个 `/usr/lib` 到 `<jbroot>/basebin/.fakelib`（`basebin_gen.m:131-143`），**留下一个约 100MB 的 stock 库副本 + `systemhook.dylib` symlink**，且 `DOJailbreaker.m:745` 仍为它上传 `DYLD_TRUSTCACHE_UUID`。这是 roothide 3.x 的一个纯负担痕迹。

### 3.3 可移植建议

- 如果 relaxin 坚持 stock dyld：**删掉/不要编译 `dyldhook/src/roothider.c`**（死代码只会误导），并把“隐藏 dyld 镜像”明确划给 jbb。
- 如果将来要启用 patched dyld：不要复用 `DOPA` 前缀，改成随机 UUID（`basebin_gen.m:64-84` 的写 UUID 位置），并把 systemhook 的识别改为“`__DATA,__jbinfo` section 存在 + state 合法”（`systemhook/src/main.c:357-363`）而不是 UUID 前缀。
- `.fakelib` 若不需要挂载，就不要 `basebin_generate` 复制整份 `/usr/lib`；至少不要把 `.fakelib` 打进 tar。

---

## 4. 注入链暴露面：env + stock dyld + 无 dyldhook

### 4.1 relaxin 的实际写法

`engine/RLXSystemHookActivationTask.m`：

```
43  const char *systemHookPath = JBROOT_PATH("/basebin/systemhook.dylib");
62  exec_set_patch(true);
67  setenv("DYLD_IN_CACHE", "0", 1);
68  setenv("DISABLE_TWEAKS", "1", 1);
69  setenv("DYLD_INSERT_LIBRARIES", systemHookPath, 1);
74  exec_cmd_trusted(JBROOT_PATH("/usr/bin/killall"), "-9", "iconservicesagent", NULL);
```

### 4.2 这段代码的来源与偏差

它和 roothide 3.x 的 first-load 引导块**逐行同构**：

```
rd-3x/Application/Dopamine/Jailbreak/DOJailbreaker.m
739  basebin_generate(false);
745  ensure_dyld_trustcache(JBROOT_PATH("/basebin/.fakelib/dyld"));
751  exec_set_patch(true);
755  setenv("DYLD_IN_CACHE", "0", 1);
756  setenv("DYLD_SHARED_REGION", "use", 1);
758  setenv("DISABLE_TWEAKS", "1", 1);
760  setenv("DYLD_INSERT_LIBRARIES", JBROOT_PATH("/basebin/systemhook.dylib"), 1);
766  exec_cmd_trusted(... "killall", "-9", "iconservicesagent", ...);
```

偏差有 4 点，且都影响检测面：

| # | 差异 | 影响 |
|---|---|---|
| 1 | relaxin 少了 `DYLD_SHARED_REGION=use`（iOS 18.4+ 才需要，16.3.1 无影响） | 无（当前设备） |
| 2 | relaxin 没有前面的 `basebin_generate` + `ensure_dyld_trustcache` | 它本来就不用 patched dyld，逻辑自洽；代价是 dyldhook 的 `__jbinfo` 链路完全没建立，`@loader_path/.jbroot` 改写随之失效（§3.2） |
| 3 | relaxin 把这段放在“激活任务”里并**常驻不 unset**；roothide 放在 bootstrap 流程里，随后由 userspace reboot 结束该进程生命周期 | relaxin 的 engine App 自身环境永久带 `DYLD_INSERT_LIBRARIES=<jbroot>/...`、`DISABLE_TWEAKS=1`、`DYLD_IN_CACHE=0` |
| 4 | relaxin 的 `systemHookPath` 在 `!firstLoad` 时已被改名成 `systemhook-<jbrand>.dylib`（`launchdhook/src/roothider.m:117-125`） | env 指向**可能已不存在的文件**；真正给目标 App 注入的是 launchd 侧 spawn hook 插入的 `HOOK_DYLIB_PATH`（`roothider.m:129-130`） |

补一个上下文：first-load 阶段 `HOOK_DYLIB_PATH` 还是空串（`launchdhook/src/roothider.m:100`），spawn hook 的 `access(HOOK_DYLIB_PATH, F_OK)` 会失败、从而**不注入**（`systemhook/src/common/common.c:235-239`）。所以这段 env 的真实用途是让 **App 自己 spawn 的子进程**（dpkg/uicache/launchctl）拿到 systemhook；userspace reboot 后 `HOOK_DYLIB_PATH` 变成 `/usr/lib/systemhook-<jbrand>.dylib`，注入改由 spawn hook 统一负责。relaxin 把这个“临时窗口”搬到了一个可能长期存活的 engine 任务里，但任务本身只 spawn 了 `killall`，因此收益与风险不匹配。

### 4.3 检测面清单（relaxin 视角）

| 检测向量 | relaxin 暴露 | roothide 3.x 处置 | 证据 |
|---|---|---|---|
| `getenv("DYLD_INSERT_LIBRARIES")` | 激活任务所在进程 = 命中 `<jbroot>/basebin/systemhook.dylib`；目标 App 内由 systemhook ctor unset | 同样 unset，但值改成 `/usr/lib/systemhook-<jbrand>.dylib`，不含 jbroot | rd `systemhook/src/main.c:396-403`；relaxin `systemhook/src/main.c:813-820` |
| `getenv("DISABLE_TWEAKS")` | 激活任务进程常驻 `1` | 仅在 bootstrap 期间存在，之后进程结束 | rd `DOJailbreaker.m:758`；relaxin `:68` |
| `getenv("DYLD_IN_CACHE")` | 激活任务进程常驻 `0`（但目标 App 内被 ctor unset） | 同（ctor unset） | rd `roothider_main.c:582-592`；relaxin `:491-498` |
| `KERN_PROCARGS2`（自读） | **原始 exec 环境块仍在栈上**，`unsetenv` 不会擦掉；能看到完整 `<jbroot>/...` 路径 | 同样会看到，但只是 `/usr/lib/systemhook-<16hex>.dylib` | 两家都没有处理；jbb 也没有（`jbb_v5.c` 无 PROCARGS 相关） |
| `csops(CS_OPS_STATUS) & CS_GET_TASK_ALLOW` | 所有被注入进程为真 | 同样为真（默认 dyld patch 关闭时） | `common.m:25-37` + `:218-225` |
| patched dyld UUID `DOPA*` | 无（未启用） | 启用时存在 | rd `basebin_gen.m:64-84`；`systemhook/src/main.c:352-355` |
| 子进程继承 | 激活任务的子进程（`killall`）继承全部 env | spawn hook 对每个子进程重建 env，黑名单/safe mode 时反向删除 | rd `systemhook/src/common/common.c:305-358` |
| 异常端口继承 | 树内无 `crashreporter_pause` | spawn 前暂停 crash reporter | rd `launchdhook/src/spawn_hook.c:75-80` |

### 4.4 关于 `killall iconservicesagent` 的实际效果

`exec_cmd_trusted()` 是**从当前进程** `posix_spawn`（`libjailbreak/src/roothider/common.m:671-738`），所以 env 只会传给 `killall` 本身；`iconservicesagent` 是 launchd 的 job，重启时由 launchd 按自己的 env 拉起，**不会**继承这里的 `DYLD_INSERT_LIBRARIES`。roothide 注释也写的是“Unsandbox iconservicesagent so that app icons can work”（`DOJailbreaker.m:765`），不是为了注入。relaxin 的注释“restarting iconservicesagent”把目的写偏了，实际收益只是让 `killall` 这一个子进程带上 env。

### 4.5 可移植建议

- 保留 `exec_set_patch(true)`（stock dyld 模式必须），但把 `setenv` 三行限定在 bootstrap 窗口，或交给 launchdhook 的 spawn hook（`common.c:314-324`）；engine 只负责触发与校验。
- 若必须保留，至少在任务结束时 `unsetenv("DISABLE_TWEAKS")`、`unsetenv("DYLD_INSERT_LIBRARIES")`，并对 `systemHookPath` 先 `access()`（现在只 check 了 `R_OK`，`:48`，没 check 改名后的真实路径）。
- 把注入路径改成 `/usr/lib/systemhook-<jbrand>.dylib`（`launchdhook/src/roothider.m:104-118`），让 env/PROCARGS2 里不出现 jbroot。

---

## 5. 进程守护 / launchd 隐藏

### 5.1 roothide 3.x 的实现面

| 能力 | 位置 | 说明 |
|---|---|---|
| launchd 注入入口 | `launchdhook/src/main.m:106-225` | `redirectLogDir` / `crashreporter_start` / `roothide_launchd_preinit` / 取 rootPath / `initXPCHooks` / `initDaemonHooks` / `initSpawnHooks` / `initIPCHooks` / `initJetsamHook` |
| launchd 侧 roothide 初始化 | `launchdhook/src/roothider.m:58-155` | `exec_set_patch(false→true)`、`hideDeveloperMode()`、`bind` hook、`sysctl` hook、`loadAppStoredIdentifiers`、`initJailbreakd`、`startAlternativeJBServer` |
| 备用 jbserver 端口 | `launchdhook/src/roothider.m:146-155`；`libroothider/src/launchd.m:23-44` | 只发 mach send right；取端口需 `CS_PLATFORM_BINARY` 校验（`jbserver/jbdomain_roothide.c:183-198`） |
| 隐藏 job / pid / coalition | `libroothider/src/xpc_hook.m:271-348` | 对黑名单进程：`subsystem 2 / routine 708` 清 `name`；`6 / 301` 把 `pid` 改成 `INT_MAX`；`3 / 829` 清 `cid`/`name`/`bundle_identifier` |
| 拒绝黑名单进程的 XPC | `launchdhook/src/jbserver/jbdomain_roothide.c:14-23` | `permissionHandler` 直接 `false` |
| 拒绝黑名单进程的 mach 服务查询 | `launchdhook/src/ipc_hook.c:26-38` | 黑名单不放行 `cy:` / `lh:` |
| LaunchDaemon 虚拟注入 | `launchdhook/src/daemon_hook.m:1-84` | 把 `<jbroot>/basebin/LaunchDaemons/*.plist` 塞进 launchd 的 `LaunchDaemons` 字典与 `Paths`，真实 `/System/Library/LaunchDaemons` 不落文件 |
| crash reporter 暂停 | `launchdhook/src/spawn_hook.c:75-80` | 防止子进程继承 exception port（“trips jailbreak detections”） |
| jailbreakd 常驻 | `libroothider/src/jailbreakd.c:98-176` | `posix_spawn(<jbroot>/basebin/jailbreakd, {"jailbreakd"})`，用 mach 端口而非 bootstrap 名 |

### 5.2 relaxin 现状

- 树内只有 `launchdhook/src/roothider.m`（403 行）：
  - `preinit` 把 `jbinfo(dyld_patch_enabled)` 写死 `false`（`:88`），`exec_set_patch(false)`（`:89`）。
  - `postinit` 同样写死 `false`（`:96`），`exec_set_patch(true)`（`:97`），做改名 + `unsandbox("/usr/lib", ...)`（`:117-127`）、`HOOK_DYLIB_PATH`（`:129-130`）、`hideDeveloperMode()`（`:104-106`）、`sysctl`/`bind` hook（`:136-142`）、`loadAppStoredIdentifiers()`（`:150`）、`xpc_*_reply` hook（`:152-155`）、`initJailbreakd(firstLoad)`（`:158`）。
  - **没有** `startAlternativeJBServer`、`jbserver_mach`、`xpc_hook`、`ipc_hook`、`daemon_hook`、`jetsam_hook`、`crashreporter_pause`。
- 黑名单分支还在（`roothider.m:357-395`），但 `isBlacklistedPath()` 的实现不在树内；`RootHideConfig` 只被 `common.m:214` 用于读写 `spinlockFixApplied`，**没有读 `appconfig`**。

### 5.3 差距

1. **没有“对黑名单进程隐藏 job/pid/端口”这一层**。只要检测 App 能调 `launchd`/RunningBoard 的 XPC（`subsystem 2/708`、`6/301`），就能看到 `jailbreakd`、`TweakInject` 进程、以及越狱 App 的 job。roothide 是逐个把返回值改脏（`xpc_hook.m:280-334`）。
2. **没有 mach 备用端口**，jbserver 只能走 bootstrap 命名空间；一旦检测 App 枚举/探测 bootstrap 服务，暴露面更大。
3. **没有 daemon plist 虚拟注入**，relaxin 的 LaunchDaemon plist 是真实文件（`RLXBaseBinInstaller.m:78-110` 改的是磁盘 plist），路径里带 `root` 字符串。
4. **没有 crash reporter 暂停**，子进程可能继承异常端口（roothide 明确说这会触发检测，`spawn_hook.c:75-80`）。
5. **没有 jetsam hook**（`jetsam_hook.c`），大 App 被 jetsam 杀掉会被误判为“越狱环境不稳定”，但不属于隐藏能力。

### 5.4 可移植建议

- P1 优先级按“收益/复杂度”排序：`startAlternativeJBServer` + `jbserver_mach`（中等）→ `ipc_hook`（低）→ `xpc_hook` 的 job/pid 隐藏（高收益、但依赖 `cachedJobInfo`/`register_job`，需要把 `launchdhook/src/jbserver/jbserver_global.c` 的 job 缓存一起搬）→ `daemon_hook`（低，主要影响 daemon 装载方式）。
- `crashreporter_pause` 是低成本高收益项，建议直接照 `spawn_hook.c:75-80` 接进 relaxin 的 spawn 原函数调用前后。

---

## 6. trustcache / codesign 痕迹

### 6.1 两条链

| 步骤 | roothide 3.x | relaxin |
|---|---|---|
| 启动时信任 basebin | `DOJailbreaker.m:367-375` → `randomizeAndLoadBasebinTrustcache()`；`libroothider/src/common.m:457-498` 遍历目录、逐文件 `ensure_randomized_cdhash`、`trustcache_file_build_from_cdhashes`、`trustcache_file_upload_with_uuid(BASEBIN)` | `RLXBaseBinTrustTask.m:96` → `randomizeAndBootstrapBasebinTrustcache()`；`common.m:584-590` → `randomizeAndPublishBasebinTrustcache(basebin, true)`；`:530-582` 遍历目录 + `trustcache_nokcall_bootstrap_append_entries` 或 `jb_trustcache_append_entries` |
| 运行时按需信任 | `launchdhook/src/jbserver/jbdomain_roothide.c:27-55` 递归收集未信任 cdhash；`trustcache_fs.c:94-107` 目录信任；`launchdhook/src/roothider.m:157-160` 按 dyld patch 开关分流 | `common.m:740-769 ensure_dyld_trustcache`：`ensure_randomized_cdhash` → `trustcache_query_cdhash` → `jbclient_trust_file_by_path` / `jb_trustcache_append_cdhashes` |
| 盘上 tc 文件 | `DOBootstrapper.m:1339` 用后删除 `basebin.tc` | `RLXBaseBinInstaller.m:69-70` 安装时直接删 |
| 校验 | 只保证上传成功 | `RLXBaseBinTrustTask.m:109-139` 额外校验 `jbctl` / `opainject` / `launchdhook` 三个 artifact 的 cdhash 能查回 |
| 内核结构 | `jb_trustcache` + `JB_MAGIC`（`libjailbreak/src/trustcache.c:139-168`）；另有固定 UUID `BASEBIN`/`DYLD`（`trustcache.h:11-12`） | 同样 `jb_trustcache` + `JB_MAGIC`（`trustcache.c:107-152`）；没有固定 UUID，走 `uuid_generate`（`:13-17`） |
| 平台兼容 | iOS 17+ TXM 分支（`libjailbreak/src/trustcache.c:29-34`，`ksymbol_txm`） | 无 TXM 分支（`trustcache.c:24-40` 只有 `pmap_image4_trust_caches` / `ppl_trust_cache_rt`） |

### 6.2 关于 `trustcache_fs`：它只是“目录遍历 + 单文件入口”

- roothide 的 `BaseBin/libjailbreak/src/trustcache_fs.c` 本身不含信任策略：`:12-56` 用 `opendir/readdir/lstat` 遍历，`:59-78` 收集未信任 cdhash，`:80-92` 信任单文件，`:94-107` 信任目录。真正决定“信什么”的是调用方：`launchdhook/src/jbserver/jbdomain_roothide.c:27-55`（递归信任可执行文件及其依赖）与 `libroothider/src/signatures.m:215-289`（按 `@rpath`/`@loader_path` 递归依赖）。
- relaxin 快照内**没有等价的目录遍历信任模块**：`trustcache.c` 只有内核链表与 entry 操作（`:107-194,297-376`），`common.m:740-769 ensure_dyld_trustcache` 只处理单文件，`RLXBaseBinTrustTask.m:96` 只处理 basebin 目录。按需信任完全依赖 `jbclient_trust_file_by_path` / `jbclient_trust_executable_recurse`（树内未 vendor 的 jbserver 端）。
- 这就是为什么 P1-8 建议“把 `trustcache_fs` 的目录遍历 + 递归依赖”补进来：不是缺一个函数，而是缺“dlopen 一个不在 basebin 目录里的 jb 库时，谁负责把它的依赖一起信任”的闭环。

### 6.3 痕迹对比

1. **cdhash 随机化的落点相同**：把 `jbrand` 写进 `__TEXT,__text` section 的 `segname` 尾部 8 字节（`libroothider/src/recdhash.m:170-171`，写入 `:216`；relaxin 用的是同一个 libjailbreak 函数）。这意味着**每个 basebin 二进制都内嵌 jbrand**，与 `.jbroot-<jbrand>`、`systemhook-<jbrand>.dylib` 可互相印证。
2. **roothide 多一个固定 UUID 入口**：`BASEBIN_TRUSTCACHE_UUID`（`trustcache.h:11`）可被任何能读内核 trustcache 链的工具按 UUID 识别；relaxin 的随机 UUID 更好。
3. **roothide 多一条 `DYLD` trustcache 项**：`DOJailbreaker.m:745` 为 `<jbroot>/basebin/.fakelib/dyld` 上传 `DYLD_TRUSTCACHE_UUID`（`trustcache.h:12`），即使 patched dyld 没被启用。relaxin 没有这一项。
4. **relaxin 的校验更严**，但只覆盖 3 个文件；roothide 遍历整个 basebin 目录（`common.m:457-478`），覆盖面更全。
5. **relaxin 的 `trustcache.c` 是 roothide 2.x 线**（对比 rd-3x `trustcache.c` 缺少 TXM 分支），在 iOS 17+ 上会失效；当前 16.3.1 不受影响。

### 6.4 可移植建议

- 保留 relaxin “随机 UUID + 不落盘 tc + readback 校验”的三条优点。
- 把校验范围从 3 个 artifact 扩到整个 `basebin/` 目录（照 `common.m:457-478` 的枚举方式），避免“主二进制信任了、依赖没信任”导致的半崩。
- 如果未来要支持 iOS 17+，补 TXM 分支（`libjailbreak/src/trustcache.c:29-34`），否则 trustcache 上传会静默失败。

---

## 7. 崩溃日志 / 日志 / 符号链接 / 目录 / 文件名 / TweakInject

| 痕迹 | roothide 3.x | relaxin（树内） | 差异评价 |
|---|---|---|---|
| **崩溃日志** | `libroothider/src/crashreporter.m:295-301` 把**完整镜像列表**（含 jbroot 路径）写进 `/var/mobile/Library/Logs/CrashReporter/*.ips`（`:161-163`）；launchdhook 版本则整文件 `#if 0`（`launchdhook/src/crashreporter.m:1`） | 无 crashreporter / 无 `.ips` 改写 | 两者都不隐藏；roothide 反而会主动写泄漏文件（仅 jb daemon 崩溃时） |
| **运行日志** | 默认编译掉：`libroothider/src/log.h:1` `// #define ENABLE_LOGS`；`SYSLOG` 宏存在但未使用（`systemhook/src/roothider.h:27`） | systemhook 强制 syslog 后端：`systemhook/Makefile:5 -DSYSTEMHOOK_LOG_BACKEND_SYSLOG=1`（`log.h` 不在快照，按宏名推断） | **relaxin 更可能留日志痕迹** |
| `/var/jb` | 常驻：`DOBootstrapper.m:249-265` 创建，`DOEnvironmentManager.m:626-703` 的隐藏开关被注释 | 安装器不创建；上游是否创建未知 | roothide 明确泄漏；relaxin 取决于 root 选择 |
| `.jbroot` 符号链接 | 自动：`ensure_jbroot_symlink()`（`common.m:365-429`），调用点 `signatures.m:215`；bootstrap 还建副根互链（`DOBootstrapper.m:1123-1124,1166-1168`） | 函数存在（`common.m:343-391`）但**无调用点** | relaxin 的 `@loader_path/.jbroot` 依赖会断 |
| `.jbroot-<16hex>` 目录 | 主根在 `/var/containers/Bundle/Application/`，副根在 AppGroup（`DOBootstrapper.m:1109-1124`） | 无生成逻辑 | roothide 把根藏在容器目录里，路径扫描更难 |
| systemhook 文件名 | `/usr/lib/systemhook-<jbrand>.dylib`（`launchdhook/src/roothider.m:106-117`） | `<jbroot>/basebin/systemhook.dylib`（`RLXSystemHookActivationTask.m:43,69`） | roothide 的名字可被 `/usr/lib` 列目录发现，但不含 jbroot；relaxin 直接暴露 jbroot |
| TweakInject | `<jbroot>/usr/lib/TweakInject/*.dylib`；TweakLoader `<jbroot>/usr/lib/TweakLoader.dylib`（`systemhook/src/main.c:530-540`） | 同路径（`systemhook/src/main.c:907-917`） | 相同；靠 jbb 过滤镜像名 |
| `basebin/present` 标记 | `setBasebinDependency()`：`<jbroot>/basebin/present -> <jbroot>/Library/Frameworks`（`common.m:762-769`），jailbreakd 在 watchdog 里删除（`jbserver/jbdomain_watchdog.c:33`） | 无 | roothide 多一个可枚举的内部符号链接 |
| LaunchDaemon plist | 虚拟注入，不落 `/System/Library/LaunchDaemons`（`daemon_hook.m:1-84`） | 磁盘 plist 带 `@JBROOT@` 替换后的真实 root（`RLXBaseBinInstaller.m:78-110`） | roothide 更干净 |
| `.fakelib` | `basebin_gen.m:131-143` 复制整份 `/usr/lib`；挂载代码已注释（`jbctl/src/internal.m:6-95`、`DOJailbreaker.m:445-488`） | 无 | roothide 留下大体积副本 + patched dyld，是纯负担 |
| launchd 环境 | `DOPAMINE_INITIALIZED=1`、`LAUNCHD_UUID`、`DYLD_INSERT_LIBRARIES=<jbroot>/basebin/launchdhook.dylib`（`launchdhook/src/main.m:211-220`） | 树内未见 | 仅 root/`launchctl procinfo 1` 可见，App 读不到 |

### 7.1 结论

- **“文件名/路径”这一维度 roothide 明显更成熟**：随机根、`/usr/lib/systemhook-<jbrand>`、副根、虚拟 daemon plist。
- **“日志”这一维度 relaxin 更可能留痕**：systemhook 显式选择 syslog 后端；roothide 默认无日志。
- **“崩溃日志”两家都没处理**，但 roothide 的 crashreporter 反而会写完整镜像列表，属于负资产。
- **`/var/jb` 在 roothide 3.x 是真实存在的**（2.x 的隐藏开关被注释），所以“装了 roothide 就不需要路径 hook”是错的；jbb 的 `/var/jb` token 仍然必要。

---

## 8. 与 jb-bypass 现有 tweak（S13 / S14）的重叠与冲突

### 8.1 能力重叠矩阵

| 能力 | roothide 3.x 内建 | jbb v5 | 重叠判断 |
|---|---|---|---|
| 文件路径（C API） | ❌（结构隐藏 + 黑名单） | ✅ 14 个函数 | **不重叠**；jbb 是唯一 syscall 层 |
| 文件路径（ObjC） | ⚠️ 仅 cfprefsd/lsd/springboard 的特例 | ✅ NSFileManager 3 方法 | 部分重叠，保留 |
| `/var/jb` | ❌ 常驻 | ✅ token 第一条 | **必须保留** |
| `/usr/lib/systemhook-*` | ❌ 常驻 | ✅ token `systemhook` | **必须保留** |
| `.jbroot-<id>` 目录 | ✅ 藏在容器目录，但名字可见 | ✅ token `.jbroot-` | 互补 |
| URL scheme | ⚠️ 只对黑名单进程拦 JB scheme（`lsd.x:96-104`） | ✅ 对注入 App 拦 12 个 | 互补：jbb 管注入 App，lsd 管黑名单 App |
| dyld 镜像名 | ❌ | ✅ `_dyld_get_image_name` | **jbb 唯一** |
| `dladdr` | ❌ | ✅ 自实现 | **jbb 唯一** |
| `_dyld_image_count` | ❌ | ✅ v5 快照（v5.0 未启用） | **jbb 唯一** |
| `dyld_all_image_infos` | ❌ | ❌ | 共同缺口 |
| `csops` CS flags | ❌（arm64e 不 hook） | ❌ | **共同缺口（P0）** |
| `KERN_PROCARGS2` | ❌ | ❌（getenv 拦不到） | **共同缺口（P0）** |
| 进程/job 隐藏 | ✅ | ❌ | roothide 唯一（且只对黑名单） |
| 偏好/UTType 隐藏 | ✅ | ❌ | roothide 唯一 |
| Frida 端口/`getenv` | ❌ | ✅ | jbb 唯一 |
| 反调试 `ptrace`/`sysctl` | ⚠️ 仅 debugserver / 非 arm64e | ✅ | jbb 唯一 |

### 8.2 冲突点（必须处理）

1. **TweakInject 放行**：jbb 的 `jb_exempt()` 靠 `/TweakInject/` + `.dylib|.plist`（`jbb_v5.c:173-186`）。roothide 的 TweakLoader 从 `<jbroot>/usr/lib/TweakInject/` 加载，路径同时命中 `.jbroot-` 与 `TweakInject`。**必须保留这条豁免**，否则注入器加载不了排在 jbb 之后的插件（S14 §8.1 已记录）。
2. **jbb 过滤 `systemhook` 会“骗到”roothide 自己的检测函数**：`otherJailbreakActived()` 用 `_dyld_get_image_name` 找 `/usr/lib/systemhook-`（`libroothider/src/common.m:560-565`）。该函数只在 Dopamine/Relaxin App 里调用（`DOMainViewController.m:140`、`DOJailbreaker.m:320`），而 Relaxin App 被 `should_enable_tweaks()` 排除（`systemhook/src/main.c:666-668`），所以**实际不冲突**；但要避免以后把该检测挪进普通 App。
3. **jbb 的 `getenv(DYLD_*)` 与 roothide 的 `roothide_init()` 运行时序**：systemhook 在 tweak 之前执行（`systemhook/src/main.c:782-820`），roothide 已 unset 的变量 jbb 再返回 NULL 是幂等的；无冲突。
4. **`realpath` 返回 NULL**：jbb v5 对 JB 路径返回 NULL（`h_realpath`），而 roothide 的 `ensure_jbroot_symlink()` 依赖 `realpath` 判断目录是否在 jbroot 内（`common.m:372-394`）。该函数只在 systemhook/签名阶段调用，早于 tweak 加载，**时序上安全**；若以后把 `ensure_jbroot_symlink` 挪到 tweak 之后会互斥。
5. **`statfs` 未 hook**：如果以后加，注意别把 `/usr/lib` 的 bind mount 伪装和 roothide 自身 `fakelib_is_mounted()` 的判断搞混（两者都用 `f_mntonname`）。

### 8.3 装 roothide 3.x 后，tweak 该删/该留/该加

**可以删（收益低、风险高）**
- `NSFileManager` 的 `contentsOfDirectoryAtPath:` / `attributesOfItemAtPath:`：只要 `/var/jb` 与 `/usr/lib/systemhook-*` 在 C 层被挡住，这两条主要是冗余；且最容易与 App 自身逻辑打架。
- `kJB` 里的传统越狱路径（Cydia/Sileo/Zebra/Filza/apt/dpkg/ssh/bash）：在 roothide 随机根下这些路径**本来就不存在**，留着只增加误伤（例如某些 App 自己带 `bin/bash` 字符串）。
- `fork`/`vfork`：roothide 的 forkfix 已处理（`forkfix/src/main.c:131-145`），tweak 层再返回 -1 反而容易误伤正常 App；`getppid` 便宜且误伤小，建议保留。

**必须保留**
- `/var/jb`、`/usr/lib/systemhook`、`.jbroot-`、`TweakInject` 四条 token 与对应 C hook。
- `_dyld_get_image_name`、`dladdr`、`canOpenURL`（S13 实测唯一增量）。
- Frida 端口与 `getenv(DYLD_*)`（对未走 roothide 的进程仍有价值）。

**必须新增（roothide 3.x 也没有）**
- `csops` / `csops_audittoken`：清 `CS_GET_TASK_ALLOW` 与 `CS_DEBUGGED`（详见 §9 P0-2）。
- `sysctl(KERN_PROCARGS2)` 自读脱敏（§9 P0-3）。
- `statfs` / `getattrlistbulk` / `__getdirentries`（§2.2）。
- `_dyld_image_count` + `dyld_all_image_infos` 稠密快照（S13 P0 / S14 v5.1 已规划）。

**黑名单语义**
- 对“注入即检测”的 App（携程、建行/农行/工行、Marriott 等），**不要试图用 tweak 解决**，走 roothide `appconfig[bundle]=true` 不注入。这种模式下 jbb 不会加载，属于预期行为（S13 §6、S14 §9.5）。

---

## 9. 按优先级排序的移植 backlog

> 说明：P0 = 不做则“隐藏”不成立或存在单车检测；P1 = 明显提升对抗强度；P2 = 卫生/可维护性。

### P0-1 注入环境收敛：不要在 engine 里常驻 `DYLD_*`

| 项 | 内容 |
|---|---|
| 改哪个文件 | `relaxin-src/engine/RLXSystemHookActivationTask.m:59-79` |
| 参考 | rd-3x `Application/Dopamine/Jailbreak/DOJailbreaker.m:751-766`（同样的 first-load 块，但生命周期短）；rd-3x `BaseBin/systemhook/src/common/common.c:305-358`（per-child env 重建）；rd-3x `BaseBin/systemhook/src/main.c:396-403`（ctor unset） |
| 预期收益 | 去掉 engine 进程常驻的 `DYLD_INSERT_LIBRARIES=<jbroot>/...`、`DISABLE_TWEAKS=1`、`DYLD_IN_CACHE=0`；env/PROCARGS2 不再直接指向 jbroot |
| 风险 | 如果在 launchdhook 接管 spawn 之前就删，first-load 阶段会失去注入；建议用“`HOOK_DYLIB_PATH` 非空且文件存在”作为 gate |

### P0-2 补 `csops` 视图：清 `CS_GET_TASK_ALLOW` / `CS_DEBUGGED`

| 项 | 内容 |
|---|---|
| 改哪个文件 | `jb-bypass/src/jbb_v5.c`（新增 `h_csops`/`h_csops_audittoken` + `jb_hook` 注册，放在 `:552-557` 的 hook 注册段旁） |
| 参考 | rd-3x `BaseBin/systemhook/src/main.c:163-195` 的实现（注意它只在 `#ifndef __arm64e__` 生效，`systemhook/src/main.c:123,197`；我们在 tweak 层对 arm64e 也做，属于“补 roothide 的空白”） |
| 预期收益 | 关掉 stock-dyld 模式最强的单车检测：release App 却有 get-task-allow。relaxin 每个被注入进程都会被 `proc_patch_csflags` 置位（`common.m:28-49,185-196`） |
| 风险 | 某些 App 用 get-task-allow 判断“是否被调试”做正版校验；返回伪造值可能改变其分支。只在 `CS_OPS_STATUS` 上改，不动其他 op |

### P0-3 `KERN_PROCARGS2` 自读脱敏

| 项 | 内容 |
|---|---|
| 改哪个文件 | `jb-bypass/src/jbb_v5.c` 的 `h_sysctl`（`:442-455`） |
| 参考 | roothide 无对应实现（共同缺口）；可参考 relaxin `systemhook/src/roothider_main.c:491-498` 的“只在 `DYLD_INSERT_LIBRARIES` 存在时清理”思路，但要从 sysctl 返回值里删 token |
| 预期收益 | 即使 env 仍被设置，App 自读 `KERN_PROCARGS2` 也拿不到 `DYLD_*`/`DISABLE_TWEAKS`/jbroot。配合 checkin 签发的 jbroot 读扩展，这条泄漏等于“把整座金库的地址交给检测方” |
| 风险 | 需要重写 `oldp` 的变长缓冲（`argc/argv/envp` 三段），写错会让 App 的 sysctl 解析崩；必须保留 `oldlenp` 语义 |

### P0-4 jbroot 随机根落地

| 项 | 内容 |
|---|---|
| 改哪个文件 | `relaxin-src/engine/RLXBaseBinInstaller.m:37-76`（生成 + 命名 + 布局）、`engine/RLXBaseBinTrustTask.m:73-80`（校验） |
| 参考 | rd-3x `Application/Dopamine/Jailbreak/DOBootstrapper.m:879-962`（命名/校验）、`:1081-1124`（主副根 + `.jbroot` 互链）、`:1141-1175`（轮换） |
| 预期收益 | 把“固定 `/var/jb`”变成“`/var/containers/Bundle/Application/.jbroot-<16hex>`”，路径扫描与硬编码检测同时失效；与 trustcache 的 jbrand 写入点自洽（rd-3x `recdhash.m:170-171,216`，relaxin 复用同一 libjailbreak 函数） |
| 风险 | 所有硬编码路径必须走 `JBROOT_PATH`；升级/回滚要 rename 两个根；jbb 的 `.jbroot-` token 已覆盖，但 `launchdhook` 的 plist 生成要同步 |

### P1-5 移植 roothidehooks 主体（lsd / cfprefsd / springboard / runningboardd）

| 项 | 内容 |
|---|---|
| 改哪个文件 | `relaxin-src/Vendor/Dopamine/BaseBin/roothidehooks/`（新增 4 个 `.x`），并修 `main.m:16-31` |
| 参考 | rd-3x `roothidehooks/src/lsd.x:30-43,96-232,409-707`；`cfprefsd.x:11-96,130-156`；`springboard.x:6-31,48-57,63-111`；`runningboardd.x:13-83` |
| 预期收益 | 黑名单进程看不到 JB 的 URL scheme、UTType、偏好、快照、图标；这是 roothide 2.x/3.x 的“服务层隐藏”主体 |
| 风险 | 依赖 Logos；`_LSDReadClient` 的 9 个方法在 16.3.1 上签名可能不同；`runningboardd` 符号名要从 `runningboarddInit` 改成 `rbdInit`（`runningboardd.x:74`） |

### P1-6 黑名单语义落地（不注入 = 最干净的隐藏）

| 项 | 内容 |
|---|---|
| 改哪个文件 | `relaxin-src/Vendor/Dopamine/BaseBin/launchdhook/src/roothider.m:345-395` + 新增 `libjailbreak/roothider/blacklist.m` |
| 参考 | rd-3x `BaseBin/libroothider/src/blacklist.m:53-94`；`launchdhook/src/roothider.m:429-486`；`launchdhook/src/jbserver/jbdomain_roothide.c:100-128`；`libroothider/src/xpc_hook.m:271-348` |
| 预期收益 | 对高危 App 彻底无注入：无 env、无 `CS_GET_TASK_ALLOW`、无 dyld 额外镜像。比任何 hook 都干净 |
| 风险 | 不注入就没有 tweak；需要 per-app 配置 UI；误配会让用户以为“已保护” |

### P1-7 launchd 侧隐藏：alt jbserver + job/pid 隐藏 + crashreporter pause

| 项 | 内容 |
|---|---|
| 改哪个文件 | `relaxin-src/Vendor/Dopamine/BaseBin/launchdhook/src/roothider.m:93-160`；新增 `jbserver_mach.c` / `xpc_hook.m` / `ipc_hook.c` |
| 参考 | rd-3x `launchdhook/src/roothider.m:146-155`；`libroothider/src/launchd.m:23-44`；`libroothider/src/xpc_hook.m:271-348`；`launchdhook/src/ipc_hook.c:26-38`；`launchdhook/src/spawn_hook.c:75-80` |
| 预期收益 | jbserver 不进 bootstrap 命名空间；黑名单进程看不到 `jailbreakd`/JB job/pid；子进程不继承异常端口 |
| 风险 | mach 端口注册在 16.3.1 的行为需实测；`xpc_hook` 依赖 job 缓存，搬漏会拿不到 identifier |

### P1-8 trustcache 覆盖面 + iOS 17 TXM

| 项 | 内容 |
|---|---|
| 改哪个文件 | `relaxin-src/engine/RLXBaseBinTrustTask.m:109-139`（校验范围扩到全目录）；`relaxin-src/trustcache.c:24-40`（补 TXM） |
| 参考 | rd-3x `BaseBin/libroothider/src/common.m:457-498`（全目录）；`BaseBin/libjailbreak/src/trustcache.c:29-34`（`ksymbol_txm`）；`launchdhook/src/jbserver/jbdomain_roothide.c:27-55`（递归信任） |
| 预期收益 | 不会因漏信任 dlopen 的库而崩；17/18 可移植 |
| 风险 | 全目录随机化会改更多 cdhash（当前也是全量，只是校验少）；TXM 分支在 16.3.1 上无法验证 |

### P2-9 `ensure_jbroot_symlink()` 调用点

| 项 | 内容 |
|---|---|
| 改哪个文件 | `relaxin-src/engine/RLXBaseBinTrustTask.m`（或 trust 库实现） |
| 参考 | rd-3x `BaseBin/libroothide/src/signatures.m:215`；`BaseBin/libroothide/src/common.m:365-429` |
| 预期收益 | `@loader_path/.jbroot/...` 依赖不再需要静态 tar 预置链接（S10 §11.1 坑 5） |
| 风险 | 低；注意要在 tweak 的 `realpath` hook 之前执行 |

### P2-10 关闭 syslog / 日志降噪

| 项 | 内容 |
|---|---|
| 改哪个文件 | `relaxin-src/Vendor/Dopamine/BaseBin/systemhook/Makefile:5` |
| 参考 | rd-3x `BaseBin/libroothider/src/log.h:1`（默认 `ENABLE_LOGS` 未定义） |
| 预期收益 | 不把 jbroot 路径/“roothide”关键字写进 ASL 与 sysdiagnose |
| 风险 | 排障变难；建议保留一个 `DEBUG=1` 编译开关 |

### P2-11 crash log 里的镜像列表

| 项 | 内容 |
|---|---|
| 改哪个文件 | relaxin 新增 crashreporter（若需要）时，过滤 `_dyld_get_image_name`；或直接不为 jb daemon 注册 CrashReporter |
| 参考 | rd-3x `BaseBin/libroothider/src/crashreporter.m:295-301`（反面教材：完整列表落盘）；`launchdhook/src/crashreporter.m:1`（`#if 0` 版本） |
| 预期收益 | `.ips` 不再出现 jbroot dylib 路径 |
| 风险 | 影响排障；对 App 检测影响很小（App 读不到该目录） |

### P2-12 dyld 计数/结构体（jbb，不属于 relaxin）

| 项 | 内容 |
|---|---|
| 改哪个文件 | `jb-bypass/src/jbb_v5.c`（`_dyld_image_count` / `dyld_all_image_infos` 快照） |
| 参考 | roothide 无；S13 §7 P0/P1、S14 §2.2 |
| 预期收益 | 关闭“count vs name”交叉验证；补齐 `dyld_all_image_infos` 直读 |
| 风险 | dyld 锁下重建会死锁（S14 §8.3 已实测），必须 callback-only + trylock |

---

## 10. 不建议做的事

1. **不要为了“更隐藏”去启用 patched dyld**，除非同时把 UUID 前缀 `DOPA`（`basebin_gen.m:64-84`）改成随机值，并改掉 systemhook 的识别方式（`systemhook/src/main.c:352-355`）。否则 `_dyld_get_image_uuid` 一条就穿。
2. **不要重写 syscall 层路径 hook 到 relaxin**。jbb 已经覆盖 14 个函数，重复 hook 会与 ellekit/MSHook 叠加，且 `__interpose` 在 dyld4 下不可靠（S13 §2.2、S14 §2.1）。
3. **不要删除 `/var/jb` token**。roothide 3.x 的隐藏开关已被注释（`DOEnvironmentManager.m:626-703`），`/var/jb` 常驻。
4. **不要用“黑名单”当默认**。黑名单 = 不注入 = 没有 jbb；只在检测到“注入即检测”的 App 上使用。

---

## 11. 验证清单（下一步，不需要改设备）

| # | 要验证的点 | 方法（静态/只读） |
|---|---|---|
| 1 | relaxin 的 `RLXBaseBinInstaller` 调用方传的 `root` 是什么 | 在完整工程 grep `installBaseBinAtRoot:` 与 `jailbreakInfo.rootPath` 赋值 |
| 2 | relaxin 是否有 launchdhook 的 `spawn_hook` / `main.m` | 完整工程 `find . -name spawn_hook.c`；本快照没有 |
| 3 | `isBlacklistedPath()` 在 relaxin 链接自哪里 | 完整工程 grep 定义；本快照只有调用点（`launchdhook/src/roothider.m:357`） |
| 4 | `runningboarddInit` vs `rbdInit` | 本快照已确认不匹配（`roothidehooks/main.m:29-30` vs `runningboardd.x:74`），需确认完整工程是否有别名 |
| 5 | `/var/jb` 在 relaxin 设备上是否存在 | 不做设备操作；从 `root` 值推断 |
| 6 | `csops` 是否真的能看到 `CS_GET_TASK_ALLOW` | 只读代码推断（`common.m:25-49`）；真机验证留给有授权窗口时 |
| 7 | roothide 3.x `.fakelib` 是否真的没挂载 | 主路径已确认注释（`jbctl/src/internal.m:6-95`、`DOJailbreaker.m:445-488,728-734`）；仅 `BaseBin/dopamine/src/main.m:132` 残留调用，而方法实现也在注释内（`DOEnvironmentManager.m:626-703`），需完整工程确认该 CLI 是否参与构建 |

---

## 附录 A：证据索引（按文件）

**roothide 3.x**
- `Application/Dopamine/Jailbreak/DOBootstrapper.m:249-265,879-962,1081-1124,1141-1175,1339`
- `Application/Dopamine/Jailbreak/DOJailbreaker.m:354-375,445-488,635,736-766`
- `Application/Dopamine/Jailbreak/DOEnvironmentManager.m:626-703`
- `Application/Dopamine/UI/Settings/DOSettingsController.m:265-276,323-345,728-735`
- `BaseBin/dyldhook/src/{main.c:14-76,107-110,202-218; roothider.c:12-55; reimpl.c; lv_bypass.c:165-296; fakelib_redirect.c:1-58}`
- `BaseBin/libjailbreak/src/{jbroot.h:10-39; basebin_gen.m:38-170; trustcache.c:29-34,139-168; trustcache_fs.c:12-107; trustcache.h:11-12}`
- `BaseBin/libroothider/src/{common.m:25-49,185-225,365-498,560-592,762-769; blacklist.m:53-94; xpc_hook.m:271-348; signatures.m:215; recdhash.m:170-218; crashreporter.m:161-163,295-301; log.h:1; launchd.m:23-44; jailbreakd.c:98-176}`
- `BaseBin/launchdhook/src/{main.m:106-225; roothider.m:58-155,429-486; spawn_hook.c:75-80,219-221; daemon_hook.m:1-84; ipc_hook.c:26-38; crashreporter.m:1}`
- `BaseBin/launchdhook/src/jbserver/{jbdomain_roothide.c:14-55,100-128,183-198; jbdomain_systemwide.c:246-256; jbserver_mach.c:110-178}`
- `BaseBin/systemhook/src/{main.c:346-403,489-540; roothider_main.c:76-173,578-618,620-667; roothider_common.c:124-186; common/common.c:305-358}`
- `BaseBin/roothidehooks/src/{pathhook.x:11-43; main.x; cfprefsd.x:11-96,130-156; lsd.x:30-43,96-232,409-707; springboard.x:6-111; runningboardd.x:13-83}`
- `Packages/libroot/src/paths.c:8-11`
- `BaseBin/jbctl/src/internal.m:6-95`

**relaxin**
- `engine/RLXBaseBinInstaller.m:19,37-76,78-110`
- `engine/RLXBaseBinTrustTask.m:73-80,93-139`
- `engine/RLXSystemHookActivationTask.m:43-84`
- `Vendor/Dopamine/BaseBin/roothidehooks/{main.m:16-31; pathhook.m:6-37}`
- `Vendor/Dopamine/BaseBin/dyldhook/src/roothider.c:12-71`
- `Vendor/Dopamine/BaseBin/systemhook/Makefile:5`
- `Vendor/Dopamine/BaseBin/systemhook/src/{main.c:782-820,856-917; roothider_main.c:61-157,185-219,221-328,491-529; roothider_common.c:123-165}`
- `Vendor/Dopamine/BaseBin/libjailbreak/src/roothider/common.m:28-49,181-196,214,343-431,448-590,668-769,773-933`
- `trustcache.c:13-17,24-40,107-152,154-194,297-376,378-396,467-475`

**jb-bypass**
- `src/jbb_v5.c:117-162,173-192,196-239,441-470,520-568`
- `src/jbb_v6.c`（同构）
- `reports/S10-dyld-image-hiding.md`
- `reports/S13-jbb-implementation-effectiveness.md`
- `reports/S14-jbb-v5-design.md`
- `HANDOVER.md:16-18,45,420-436`
