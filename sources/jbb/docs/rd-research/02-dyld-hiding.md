# roothide / Dopamine-roothide 3.x — dyld 层隐藏机制分析

- 分析对象：`/Users/dan/Desktop/iphone/rd-3x`，commit `24ea745`（"add roothide support for Dopamine 3"），工作树干净（`git status` 无改动）
- 目标设备：iPhone 14 Pro / iOS 16.3.1（arm64e，A16，无 SPTM —— `SPTMArgs` 符号在 A17/iOS 17 才出现，故 `forceCSAdhoc=false`；代码走 `pmap_cs` 分支）
- 性质：只读源码分析，未上机验证；所有"运行时行为"结论均从代码路径推导
- 标记约定：
  - **【已验证】** 有明确代码位置，逻辑闭环，可以直接引用
  - **【推测】** 由代码推断，但缺少运行时证据（或依赖仓库外组件）
  - **【旁证】** 不在本 commit 内，仅用于解释"为什么会有这个说法"

---

## 0. 一句话结论

**这套代码没有在 dyld 内部对 `all_image_infos` 链表做手术，也没有 hook `_dyld_image_count/_dyld_get_image_name/_dyld_get_image_header`。**
注入的 dylib 在 dyld 视图里是**正常可见的**，它做的是"**路径洗白**"：

1. jbroot 整体放在 `/var/containers/Bundle/Application/.jbroot-<64bit 随机>`（无固定 `/var/jb`，见 `Application/Dopamine/Jailbreak/DOBootstrapper.m:879-885, 930-948, 1081-1128`）；
2. 把 `systemhook-<jbrand>.dylib` 的 **vnode 直接挂进 `/usr/lib/` 的 namei cache**，于是 `DYLD_INSERT_LIBRARIES=/usr/lib/systemhook-XXXXXXXX.dylib`，路径看起来像系统库（`BaseBin/launchdhook/src/roothider.m:106-118` + `BaseBin/libroothider/src/unsandbox1.m:74` / `unsandbox2.m:112`）；
3. 进程内立刻 `unsetenv("DYLD_INSERT_LIBRARIES")`（`BaseBin/systemhook/src/main.c:396-403`）；
4. 每个二进制重新随机 cdhash（`BaseBin/libroothider/src/recdhash.m:120-230`），使静态 hash 指纹失效。

最硬的证据是**他们自己的检测代码**：`BaseBin/libroothider/src/common.m:561-563` 用
`_dyld_get_image_name(i)` 前缀匹配 `"/usr/lib/systemhook-"` 来判定"这是 roothide 1.x 越狱"。
如果镜像真的被隐藏了，这段代码永远命中不了。**→ 注入镜像对 dyld API 完全可见。**

另外需要指出：`/Users/dan/Desktop/iphone/rd27`（同一台机器上的 **本地改动工作树**，`git status` 显示 `BaseBin/systemhook/src/main.c` 有 +92 行未提交改动）里确实存在一个"隐藏镜像名"的原型：hook `_dyld_get_image_name` + `dladdr`，把命中黑名单的路径改写成 `"/usr/lib/libSystem.B.dylib"`（`rd27/BaseBin/systemhook/src/main.c:313-337, 384-400`）。**它不在 24ea745 里**，详见 §1.6。

---

## 1. Q1：注入的 dylib 为什么"看起来"不在 dyld 镜像列表里

### 1.1 dyldhook 到底 hook 了什么（完整清单）

`BaseBin/dyldhook/Makefile:5` 把所有 `src/*.c` 编成一个 dylib，再由 MachOMerger **物理合并进一份 dyld 可执行文件**（`BaseBin/libjailbreak/src/basebin_gen.m:90-97, 149-154`）。它只在 "dyld patch 模式" 下存在（见 §4.2）。

合并后 MachOMerger 按符号名对接 hook（`BaseBin/MachOMerger/Sources/MachOMerger/main.swift:293-410`），dyldhook 侧声明的 hook 只有 4 个：

| hook 目标 | 位置 | 作用 |
|---|---|---|
| `dyld::APIs::dlopen_from` | `dyldhook/src/fakelib_redirect.c:26-55`（**整文件 `#if 0`**） | 历史：/usr/lib → jbroot/.fakelib 重定向 |
| `dyld::loadDyldCache` | `dyldhook/src/spinlock_fix.c:104-146`（**仅 `IOS==15 && __arm64e__`**） | iOS15 spinlock panic 规避 |
| `dyld::Loader::expandAtLoaderPath` | `dyldhook/src/roothider.c:19-39` | 把 `@loader_path/.jbroot/...` 展开成真实 jbroot |
| `dyld::__fcntl` | `dyldhook/src/lv_bypass.c:165-296` | Library Validation bypass |

外加一个入口劫持 `_MACHOMERGER_START_HOOK`（`dyldhook/src/main.S:14-29`，在 dyld `_dyld_start` 之前跑 `dyldhook_init`）。
**清单里没有任何 image list / all_image_infos / `_dyld_*` API 相关钩子。**

顺带说明这个组件的工程特点：它运行在 libsystem 可用**之前**，所以 `nm -u` 必须为空（`Makefile:12-20` 强制检查），所有 libc 调用都是跳回 dyld 自带实现的 trampoline（`main.S:51-99`），syscall 全部手写 `svc #0x80`（`main.S:88-98`），`mach_msg`/`mach_msg2`/`mach_ports_lookup` 也是自己重写的（`reimpl.c:69-218`、`generated/ios16-17/task.c:43-266`）。

### 1.2 那 `_dyld_image_count` 里能看到什么？

**【已验证】** 能看到，而且路径是 `/usr/lib/systemhook-<16位十六进制>.dylib`：

- 注入路径生成：`BaseBin/launchdhook/src/roothider.m:106-118`
  ```objc
  NSString* systemhookFilePath = [NSString stringWithFormat:@"%@/systemhook-%016llX.dylib", JBROOT_PATH(@"/basebin"), jbinfo(jbrand)];
  assert(unsandbox("/usr/lib", systemhookFilePath.fileSystemRepresentation) == 0);
  asprintf(&HOOK_DYLIB_PATH, "/usr/lib/systemhook-%016llX.dylib", jbinfo(jbrand));
  ```
- 每个子进程注入这个字符串：`BaseBin/systemhook/src/common/common.c:185-235, 300-350`（`envbuf_setenv(&envc, "DYLD_INSERT_LIBRARIES", newLibraryInsert)`，见 `:322`）
- 他们自己的"越狱存在性检测"就是扫这个镜像名：`BaseBin/libroothider/src/common.m:561-563`
- TweakLoader / tweak dylib 也是普通 `dlopen`：`BaseBin/systemhook/src/main.c:530-540`（`dlopen(JBROOT_PATH("/usr/lib/TweakLoader.dylib"))`），因此同样出现在 image list 里，且路径是**完整 jbroot 路径**（`.jbroot-<jbrand>/...`）。这是最强的信息泄漏点，见 §6。

### 1.3 那"隐藏"到底做了什么（三层）

**第一层：文件系统层面的路径洗白（namei cache 拼接）**【已验证】

`unsandbox()` 用内核读写原语把 jbroot 里那个文件的 `vnode` 挂到 `/usr/lib` 的目录 namecache 链上：

- 入口：`BaseBin/libroothider/src/unsandbox.m:90-96`（iOS ≥16.4 走 `unsandbox2`，否则 `unsandbox1`）
- 实现：`unsandbox1.m:74-263` / `unsandbox2.m:112-318`
  - 取 dir vnode / file vnode（`proc_fd_vnode`，`:20-38`）
  - 把 file 的 namecache 从原父目录的 `v_ncchildren` / `nchead` / hash 链上摘下来（`:190-250`）
  - 改写 `nc_dvp = dirvp`，让 `/usr/lib/systemhook-xxx.dylib` 这个名字解析到 jbroot 的 vnode
  - 重新 `open()` 校验，并把 `v_usecount` 加一防止被回收
- 效果：**没有 mount、没有 symlink、rootfs 一个字节都没改**。`open("/usr/lib/systemhook-xxx.dylib")` 成功，`statfs` 返回的是 jbroot 所在的卷（`/private/var`），而不是 `/`。

这也是 `BaseBin/launchdhook/src/jbserver/jbdomain_systemwide.c:123-133` 里那句判断能工作的原因：rootfs 上的文件直接跳过信任（"guaranteed to already be in trustcache"），而拼接出来的 `systemhook-xxx.dylib` 的 `f_mntonname != "/"`，所以会走真实 cdhash 注入 trust cache 的流程。同时 `/usr/lib` 的 bindfs 挂载那套逻辑被整段注释掉（`jbdomain_systemwide.c:127` 的 `/usr/lib` 分支被注释），因为这个方案不再需要覆盖 `/usr/lib`。

**第二层：jbroot 随机化（无固定挂载点）**【已验证】

- 目录名：`/var/containers/Bundle/Application/.jbroot-%016llX`（`BaseBin/libroothider/src/common.m:437`；创建逻辑 `DOBootstrapper.m:1081-1128`）
- 二级目录：`/var/mobile/Containers/Shared/AppGroup/.jbroot-%016llX`（`common.m:438`），jbroot 里的 `/var`、`/tmp`、`/private/var` 用符号链接指过去（`DOBootstrapper.m:1109-1128`）
- `jbrand` 是 64bit 随机 + 1 字节校验（`DOBootstrapper.m:944-965`），支持"ReRandomize"整体改名（`DOBootstrapper.m:1138-1190`）→ 任何基于路径字符串的签名/黑名单都会被下一次 re-randomize 打掉
- 没有 `/var/jb`；`isJailbreakHidden` 甚至就是"`/var/jb` 不存在"（`Application/Dopamine/Jailbreak/DOEnvironmentManager.m:658-661`，该函数反映的是上游 rootless 语义，roothide 下恒为 true）

**第三层：环境变量与进程内痕迹清理**【已验证】

- 注入变量在 systemhook 构造器里删掉，但**只在"只有 systemhook 一个条目"时删**：
  `BaseBin/systemhook/src/main.c:396-403`
  ```c
  const char *dyldInsertLibraries = getenv("DYLD_INSERT_LIBRARIES");
  if (dyldInsertLibraries) {
      if (!strcmp(dyldInsertLibraries, HOOK_DYLIB_PATH)) unsetenv("DYLD_INSERT_LIBRARIES");
  }
  ```
- `DYLD_IN_CACHE` / `DYLD_SHARED_REGION` 也在进程内撤销：`BaseBin/systemhook/src/roothider_main.c:582-592`
- 不在白名单的进程（黑名单/Choicy/SafeMode/DriverKit）**不注入**，并且会把已存在的 `DYLD_INSERT_LIBRARIES` 里的 systemhook 条目摘掉：`common.c:340-355`；黑名单进程列表 `common.c:126-146`

### 1.4 全仓唯一一处 `all_image_info` 手术：不是隐藏，是换 dyld

`BaseBin/libroothider/src/dyld_patch.m:99-160` 的 `task_set_dyld_info()` 会 `kwrite` 目标进程 `task` 结构里的 `all_image_info_addr/size` 两个字段（先用『在 task 结构里扫描这两个值』的方式定位偏移，`:117-131`）。

它的用途是把内核视角的 dyld_info 从**旧 dyld** 切换到**被 remap 进来的补丁 dyld**：
`dyld_patch.m:678`（spinlock-fix-only 分支）和 `:786`（完整替换分支）。

**结论：这段代码既不删除 infoArray 条目，也不改 `infoArrayCount`；它只是让 `task_info(TASK_DYLD_INFO)` 指向另一份 dyld 的 `__DATA,__all_image_info` 段。** `dyld_patch.m:386` 的代码说明了 `all_image_info` 段是从 mach-o 的 section 名里找出来的（`__all_image_info`）。

### 1.5 为什么"看起来"被隐藏了？（解释误解来源）

**【推测 + 推理】** 四个常见误判：

1. **只查 shared cache 列表**：`_dyld_shared_cache_contains_path("/usr/lib/systemhook-xxx.dylib")` 返回 false，`dyld_shared_cache_*` 里当然找不到它 —— 因为它不在 cache 里。有人把它当成"dyld 里没有"。
2. **只查 `/usr/lib` 目录列表**：`readdir("/usr/lib")` **不会**列出拼接出来的名字（namei cache 只影响 lookup，不影响 readdir），所以 `ls /usr/lib | grep systemhook` 为空。
3. **注入被禁用**：被 Choicy/黑名单/SafeMode 命中的进程根本不注入（`common.c:199-240`），那当然看不到。
4. **dyld patch 模式下旧 dyld 被抹掉**：`dyld_patch.m:451-470` 会把旧 dyld 的 mach header 清零（注释原文："Destroy the old dyld header first to avoid double dyld being found via vm_region*"），`:764` 直接 `vm_deallocate` 旧 dyld 区域。于是 `vm_region` 扫描看不到"两个 dyld"，容易被误读成"dyld 镜像被藏了"。

### 1.6 【旁证】rd27 里的"镜像名过滤"原型（不属于本 commit）

`/Users/dan/Desktop/iphone/rd27/BaseBin/systemhook/src/main.c`（未提交，+92 行）实现了：

- `jb_is_bad_path()`：路径含 `systemhook/jbroot/roothide/TweakInject/frida/Substrate/cycript/ellekit/libsandy/jbb` 即命中（`:313-320`）
- `jb_raw_image_name()`：直接读 `task_info(TASK_DYLD_INFO)` → `dyld_all_image_infos->infoArray[index].imageFilePath`（`:322-329`）
- `jb_hide_image_name()`：命中就返回 `"/usr/lib/libSystem.B.dylib"`（`:331-337`）
- `jb_dladdr()`：自己遍历 `infoArray` 反查地址（litehook 没有 trampoline），命中同样改写 `dli_fname`（`:339-382`）
- `jb_install_filters()` 只在"用户 App 容器进程"里安装（`:384-400`）

它是 **API 层 hook**，不是链表手术，而且有 4 个明显破绽（留给 §6）：
`_dyld_image_count` 没变、`_dyld_get_image_header` 没变、`dyld_all_image_infos` 可以直接读、多个 `libSystem.B.dylib` 重名。
（另：`/Users/dan/Desktop/iphone/roothide-src/BaseBin/systemhook/src/main.c:356-420, 508-524` 是同一思路的更早版本，含 `JBHIDE_MARKER_V1` 字符串。）

---

## 2. Q2：fakelib_redirect 的作用与原理

### 2.1 现状：**死代码，未编译进产物**

`BaseBin/dyldhook/src/fakelib_redirect.c`：

- `:1` `#if 0` —— 整个文件被禁用
- `:24` 内部还有一层 `#if IOS < 18`
- 文件末尾 `:57-58` 双重 `#endif`

【已验证】它不会出现在任何 `dyldhook_merge.*.dylib` 里（`Makefile:22-50` 虽然把 `src/*.c` 全编进去，但预处理后为空）。

### 2.2 它当年想解决什么

`fakelib_redirect.c:18-22` 的注释写得很清楚：

> 隐藏越狱时，`/usr/lib` 这个 bindfs 挂载点会消失，很多进程会因为已 map 的 `/usr/lib` 下**不在共享缓存里**的库（例如 `libobjc_trampolines.dylib`）而崩溃。解决办法是把 `dlopen("/usr/lib/x")` 重定向到 `<jbroot>/basebin/.fakelib/x`，这样 vnode 就不在 `/usr/lib` 这个 mount 上，卸载 `/usr/lib` 就不会崩。

实现就是 hook `dyld::APIs::dlopen_from`：前缀 `/usr/lib/` → `<jbroot>/basebin/.fakelib/` + 后缀（`:27-55`），失败则 fall through 回原路径（`:48-54`）。

### 2.3 `.fakelib` 与 dyld shared cache 的关系

**没有直接关系**，但 `.fakelib` 是 dyld 替换方案的载体：

- `.fakelib` 是安装期对 `/usr/lib` 的 `carbonCopy`（`basebin_gen.m:130-134`），随后删掉其中的 `dyld`，改成符号链接 `<jbroot>/basebin/gen/dyld`（`:136-140`），`systemhook.dylib` 也做个符号链接（`:142-143`）
- 打补丁的 dyld 就生成到 `gen/dyld`，并单独上传 trust cache（`basebin_gen.m:149-154`、`launchdhook/src/roothider.m:137-142`、`Application/Dopamine/Jailbreak/DOJailbreaker.m:743-747`）
- dyld patch 时从这里读"补丁 dyld"：`dyld_patch.m:607` `loadDyldInfo(JBROOT_PATH("/basebin/.fakelib/dyld"))`
- 共享缓存本身（`/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e*`）**完全没有被改动**；need 的库仍然从 cache 里来。`.fakelib` 只是"如果 /usr/lib 被卸载时的替身目录" + "补丁 dyld 的存放点"

【已验证】**roothide 3.x 已经放弃了 bindfs 覆盖 `/usr/lib` 的方案**：`BaseBin/jbctl/src/internal.m:10-92` 的 `mount_unsandboxed/fakelib_set_mounted` 整段在 `/* */` 里；`launchdhook/src/main.m:193-207`、`spawn_hook.c:37-56, 111-113` 相关调用也全被注释。

---

## 3. Q3：lv_bypass 与 spinlock_fix

### 3.1 lv_bypass：hook dyld 的 `__fcntl`

`BaseBin/dyldhook/src/lv_bypass.c`

**原理**（`:20-22` 注释）：dyld 在 mmap 一个 dylib 之前会先 `fcntl(F_ADDFILESIGS*)` 把它的代码签名附加到 fd 上，之后 AMFI 才允许映射。**只要让这次 fcntl 成功**，Library Validation（teamID 必须一致）就不起作用了。

**流程**（`:165-296`）：

1. 门槛：`jbinfo_is_checked_in() || proc_has_bootstrap_port()`（`:176`）—— 没有 bootstrap port 的 DriverKit 进程不做，避免早期启动死锁/崩溃循环（`:167-175` 注释）
2. `F_ADDSIGS`（内存内签名）在 roothide 下**直接 `break`**，即不做特殊处理，走原生 syscall（`:178-181`，注释 `roothide specfic`）→ 说明内存内签名不在这套 bypass 覆盖范围内【已验证代码事实】
3. `F_ADDFILESIGS` / `F_ADDFILESIGS_RETURN`：
   - 先直接发原生 syscall：`msyscall_errno(0x5C, ...)`（`:185`，0x5C = 92 = `fcntl`；裸 syscall 实现在 `reimpl.c:34-48`）。成功就返回（`:186-188`）
   - 失败则组装 `struct siginfo`（`:189-193`），调用 `jbclient_mach_trust_file(fd, &siginfo, false)`（`:289`）—— 通过 mach 消息请 launchd/jailbreakd 把该文件的 cdhash 塞进**内核 trust cache**
   - 最后无论如何再走一次原生 syscall（`:295`）
4. 整段 `#if 0`（`:194-286`）是 SPTM/TXM 设备上"强制 CS_ADHOC"的逻辑：解析 SuperBlob → 找最优 CodeDirectory（`:66-127`）→ 判断是否 adhoc（`:129-163`）→ 按 "TXM 认为 CS_ADHOC 和 TeamID 二选一" 的规则改写 `cdFlags`（`:230-259`）→ 重新 trust + `F_ADDSIGS` 附加。**本 commit 里禁用**，所以 iOS 16.3.1（无 SPTM）不受影响；`forceCSAdhoc` 字段仍然被赋值（`jbdomain_systemwide.c:269-270`：`*forceCSAdhocOut = (ksymbol(SPTMArgs) != 0)`），只是没人用。

**信任落地的服务端**：`BaseBin/launchdhook/src/jbserver/jbdomain_systemwide.c:103-145`
- rootfs 上的文件直接返回 0（`:123-133`）
- 否则 `file_collect_untrusted_cdhashes(fd, ...)` → `jb_trustcache_add_cdhashes()`（`:137-144`）
- 注意：`systemwide_trust_file` 后半段（`sigInfos`/`trust_signatures`/`attach`）是上游逻辑，roothide 分支提前 `return` 了（`:144`），即**只做 trust cache，不再做签名附加**

**对 `csops` / `CS_OPS` 的影响**：
- LV bypass 本身不改 `csflags`。真正让"未签名代码可执行"的是 checkin 路径里的 `cs_allow_invalid()`：
  `BaseBin/libjailbreak/src/kernel.c:312-345`
  - arm64e + `pmap_cs`：`pmap_cs_allow_invalid(pmap)`（`:299-310, 339`）→ 只改 pmap/TXM 的 `allowsInvalidCode`
  - 非 arm64e（或 `emulateFully`）：`proc_csflags_clear(CS_KILL|CS_HARD)` + `proc_csflags_set(CS_DEBUGGED)`（`:328-336`），并清 `vm_map.flags.switch_protect`、置 `cs_debugged`
- 调用点：`jbdomain_systemwide.c:273`（每次 checkin）、`jbdomain_platform.c:23-29`（`platform_set_process_debugged`，供 Frida/调试器场景）
- 结果：iOS 16.3.1 上必然可见的是 `CS_GET_TASK_ALLOW`（§4.3 的 `proc_patch_csflags`）；`CS_DEBUGGED` 与 `CS_KILL/CS_HARD` 的改动只发生在 `emulateFully || !host_is_arm64e()` 分支（`:322`），即"非 arm64e"或"App 且 `markAppsAsDebugged` 开启"时；`pmap_cs` 设备上其余进程只是 pmap 的 `allowsInvalidCode` 被打开（`:339`）。这三类都是可检测的异常（§6）

### 3.2 spinlock_fix：只在 iOS 15 arm64e 上存在

`BaseBin/dyldhook/src/spinlock_fix.c:1` 就是 `#if IOS==15 && __arm64e__`

- 问题：iOS 15 arm64e 上若原地 patch 共享缓存里的可执行页（为了下 hook），会触发 spinlock panic
- 做法：hook `dyld::loadDyldCache`（`:128-146`），共享缓存加载完后，遍历 cache 头里的每个 mapping（`:27-77`，含 subcache `.1`~`.9`），对 `initProt & PROT_EXEC` 的段：
  1. `fcntl(fd, F_ADDFILESIGS_RETURN, dsc 代码签名)`（`:79-86`）
  2. `mmap(MAP_FIXED|MAP_PRIVATE, PROT_READ|PROT_EXEC, 同一文件同一偏移)`（`:88-97`）
  
  即把共享缓存的 `__TEXT` 换成本进程的**私有 COW 映射**，之后改页不会影响别人，也不会触发 panic
- `ORIG__...loadDyldCache` 里塞了 10 个 `nop`（`:109-125`），给 MachOMerger 留出改写首指令的空间（hook 机制要求原函数前 4 字节可替换）
- 开关：环境变量 `SPINLOCK_FIX_DISABLED`（`roothider.c:43-54`），用于"全局禁用 dyld patch 但仍给 WebContent 打 dyld"的场景（`:49-50` 注释）

**对 CS_OPS 的影响**：私有映射后这些页不再与共享缓存共享物理页，`pmap` 的 CS 校验对它们失效；他们靠 `F_ADDFILESIGS_RETURN` 先把 dsc 的签名挂上，避免 `mmap` 被 AMFI 拒。**A16/iOS 16.3.1 上这段代码不参与编译**，所以对本机无影响。

---

## 4. Q4：注入时机与"子进程为什么还能注入"

### 4.1 两条完全不同的注入通道

```
                ┌─ dyld patch 模式（开关，默认关）──► 整个 dyld 被替换（带 dyldhook）
launchd ──posix_spawn──┤
                └─ 默认模式 ────────────────────► 只改子进程 csflags + trust cache
```

开关默认值：`Application/Dopamine/Jailbreak/DOJailbreaker.m:635`
`gSystemInfo.jailbreakInfo.dyld_patch_enabled = [[DOPreferenceManager sharedManager] boolPreferenceValueForKey:@"dyldPatchEnabled" fallback:NO];`
（设置项默认 `@NO`：`DOSettingsController.m:268`）
运行期可通过 jbserver 切换：`BaseBin/launchdhook/src/jbserver/jbdomain_roothide.c:149-178`（要求 uid==0 或 `CS_PLATFORM_BINARY`）。

**例外**：即使开关关闭，`process_force_dyld_patch()` 也会强制让 WebKit 的 `com.apple.WebKit.WebContent(.CaptivePortal)` 及其 `xpcproxy` 走 dyld patch（`BaseBin/libroothider/src/common.m:184-211`，判定点 `:218-226`）。也就是说"默认模式"并不是全局统一，WebContent 进程里依然会出现 §4.2 的全部特征（`DOPA` UUID、`__jbinfo`、匿名 dyld 映射）。

### 4.2 dyld patch 模式（可选）：整份 dyld 换掉

1. 安装期生成补丁 dyld（`basebin_gen.m:38-88`）：
   - `dyld::ProcessConfig::Security::getAMFI` 首指令改成 `mov x0, #0xff; ret`（`:48-62`）→ **DYLD_* 环境变量永远被接受**
   - `LC_UUID` 改成 `"DOPA" + Dopamine 版本 + \0 + 原 UUID 剩余部分`（`:64-84`）→ 注释说明目的是"防止内核继续用 cache 里那份 dyld"
   - `MachOMerger` 把 dyldhook 合并进去（`:90-97`），`resign_file` 重签（`:149-154`）
2. 运行期在子进程里替换：`BaseBin/libroothider/src/dyld_patch.m:593-808`
   - `task_for_pid` 拿 task port（`:613-620`）→ 调用方需具备取任务端口的能力（jailbreakd 是 root + unsandboxed + platform binary）
   - `vm_remap` 把补丁 dyld 整份映射进目标（`:626`）
   - `task_threads` 找到 PC 正好等于**原 dyld 入口**的线程（`:700-760`），把 PC 改成新入口（arm64e 上做 `ptrauth` 重签，`:735-757`）
   - `vm_deallocate` 旧 dyld 区域（`:764`），`task_set_dyld_info` 把内核记录的 dyld_info 指向新 dyld（`:786`）
   - 失败兜底 `hook_dyld_entry`（`:451-500`）：清零旧头 + 在旧入口写 `movz/movk...br x0` 跳板
3. 之后子进程的 dyld 一启动就执行 `dyldhook_init`（`main.S:14-29`）：
   - `getpid()==1`（launchd）直接 return（`dyldhook/main.c:114-117`）
   - 从 `kernelParams` 手工解出 `argc/argv/envp`（`:119-122`）
   - 识别 `DYLD_HOOK_PRINT` / `DYLD_HOOK_SETUID`（后者解析 `--uid/--ruid/--gid/--rgid/--groups/--fd`，改完凭证后 `write(fd,0x42)` 再 `b .` 自旋；【推测】用于 `launchctl` 的 setuid/降权场景，`:128-200`）
   - 只有 `DYLD_INSERT_LIBRARIES` 存在且包含 `"/systemhook"` 时，才在 **dyld_start 之前**完成 checkin（`:202-218`）

### 4.3 默认模式（iOS 16.3.1 实际走这条）：改 csflags + trust cache

1. **先让子进程停住**：`POSIX_SPAWN_START_SUSPENDED`，然后从 launchd 侧打补丁再 resume
   - launchd：`BaseBin/launchdhook/src/roothider.m:162-221`（`:176-178` 加 flag，`:206-215` 调 `jbdSpawnPatchChild`）
   - 已在进程内的 systemhook：`BaseBin/systemhook/src/roothider_main.c:222-327`
2. **jailbreakd 侧**：`BaseBin/libroothider/src/common.m:218-226`
   ```c
   if (dyld_patch_enabled() || process_force_dyld_patch(...)) return proc_patch_dyld(pid);
   return proc_patch_csflags(pid);
   ```
   `proc_patch_csflags`（`common.m:24-34`）只做一件事：`proc_csflags_set(proc, CS_GET_TASK_ALLOW)`。
   `unrestrict()`（`common.m:155-180`）会先等进程真正 `SSTOP`（`proc_paused`）再打补丁，最后 `SIGCONT`。
3. **为什么这样就能加载 dylib**：
   `CS_GET_TASK_ALLOW` 让 dyld 认为"这个进程允许 DYLD_* 变量"（等价于 get-task-allow 签名进程；项目自己的注释就写着 "To replace dyld patch, make dyld respect DYLD_ environment variables"，`common.m:23`），同时 checkin 里 `cs_allow_invalid()` 打开了"可执行无效页"（§3.1）。
4. **为什么 dylib 不会被 codesign 拦**：spawn 前把二进制和所有依赖的 cdhash 塞进 trust cache：
   `common.c:178-183`（`trust_binary`）、`roothide_trust_executable_recurse`（`jbdomain_roothide.c:57-71`）、
   dlopen 时也会 trust：`systemhook/src/roothider_main.c:397-431`（`dyld_dlopen*/dlopen_preflight` 四个 hook）
5. **额外细节**：
   - 强制关掉 dyld-in-cache：`envbuf_setenv(envc, "DYLD_IN_CACHE", "0")` + `"DYLD_SHARED_REGION","use"`（`roothider.m:182-186`、`roothider_main.c:290-294`、`:371-374`），原因写在 `:180-181` 注释（dsc `__DATA_CONST` 上 `vm_protect` 失败）
   - jetsam 上限乘 3（`common.c:245-260`），persona root 修复（`common.c:262-300`）

### 4.4 `DYLD_INSERT_LIBRARIES` 的生命周期

| 阶段 | 变量值 | 代码 |
|---|---|---|
| launchd 自身（永久） | `<jbroot>/basebin/launchdhook.dylib` | `launchdhook/src/main.m:213` |
| 越狱刚完成时 | `<jbroot>/basebin/systemhook.dylib`（真实路径，先能用就行） | `DOJailbreaker.m:760` |
| 之后每个子进程 | `/usr/lib/systemhook-<jbrand>.dylib` | `roothider.m:117` + `common.c:322` |
| 进程内 | 被 `unsetenv`（仅当完全相等时） | `systemhook/src/main.c:396-403` |
| 不注入的进程 | 若存在则摘除该条目 | `common.c:325-355` |
| 再次派生子进程 | 由 systemhook 的 `posix_spawn` hook 重新加回 | `main.c:436-440`、`common.c:300-322` |

**注意 launchd 那行是永久的**：`setenv("DYLD_INSERT_LIBRARIES", JBROOT_PATH("/basebin/launchdhook.dylib"), 1)` —— 目的是让用户态重启后 launchd 能被重新注入，但它同时是一条"root 可读"的痕迹（`kern.procargs2` / `ps eww 1`，需 root 权限）【已验证代码，利用条件为推测】。

补充一个容易被忽略的细节：进程内 `HOOK_DYLIB_PATH` 不是硬编码，而是
`strdup(dyld_image_path_containing_address(&__dso_handle))`（`BaseBin/systemhook/src/roothider_main.c:611`），
即"dyld 记录的这个镜像的路径"——也就是 `/usr/lib/systemhook-<jbrand>.dylib`。
这就是 `main.c:400` 的 `strcmp(dyldInsertLibraries, HOOK_DYLIB_PATH)` 能精确命中并删除环境变量的原因；
同时也说明子进程注入时用的仍是这个"假系统库"路径（`common.c:310-322`）。

### 4.5 特殊 mach port / ptrace 的作用

- **checkin 只用一个 port**：进程的 bootstrap port（`task_get_bootstrap_port`）。如果没有（xpcproxy 在 iOS 16 上就没有），fallback 到 `mach_ports_lookup` 返回的 `registeredPorts[0]`：
  `BaseBin/libjailbreak/src/jbclient_mach.c:10-27`
- **消息 ID 有魔法值**：`msgh_id = 0x40000000 | 206`，注释写着"206 是 WebContent 沙箱唯一放行的 ID"（`jbclient_mach.c:45-46`）
- **dyldhook 里为什么重写 `mach_ports_lookup`**：iOS 16 的 dyld 里没有 mach_msg / mach_ports_lookup，必须在 dyld 内部自实现（`dyldhook/src/reimpl.c:69-218`、`generated/ios16-17/task.c:151-266`）。`ios16-17/task.c` 是 MIG 生成的 `task_get_special_port`(3409) 和 `mach_ports_lookup`(3404)
- **ptrace 不用于注入**，只用于两条边角：
  1. `execve` 路径：`posix_spawn(SETEXEC)` 失败且进程只允许 `execve` 时（例如 iOS 15 的 `configd`），用**异常端口**（`EXC_SOFTWARE`/`SIGTRAP`）在 "exec 之后、dyld 填 image list 之前" 抓住进程再补补丁：`BaseBin/libroothide/src/exec_trace.m:114-180`，注释 "Like LLDB, recognize exec before dyld populates its image list."
  2. debugserver 场景：`systemhook/src/main.c:500-507` + `:105-121`（attach 后补 `platform_set_process_debugged`）
- **`CS_GET_TASK_ALLOW` 在这儿的作用**：让 `task_for_pid`/`ptrace` 成功，也是 dyld 接受 `DYLD_*` 的前提。它**不是**"借某个特殊 port 注入"。

---

## 5. Q5：`dyld_jbinfo` 保存了什么，谁能读

### 5.1 结构

`BaseBin/dyldhook/src/dyld_jbinfo.h:1-19`

```c
#define DYLD_JBINFO_MAXSIZE 0x4000
struct dyld_jbinfo {
    uint64_t state;              // == 1 (DYLD_STATE_CHECKED_IN)
    char *jbRootPath;            // 指向 data[]
    char *bootUUID;              // 指向 data[]
    char *sandboxExtensions;     // 指向 data[]
    bool fullyDebugged;
    bool forceCSAdhoc;
    char data[];                 // 0x4000 缓冲区
};
```

载体是 dyldhook 里的一个段：
`BaseBin/dyldhook/src/main.c:14-15`
```c
__attribute__((section("__DATA,__jbinfo"))) static char jbinfoSection[0x4000];
#define jbInfo ((struct dyld_jbinfo *)&jbinfoSection[0])
```

写入内容（`main.c:51-76`）：
- `jbRootPath`：jbserver 回包里的真实 jbroot（形如 `/var/containers/Bundle/Application/.jbroot-<jbrand>`）
- `bootUUID`：`LAUNCHD_UUID`（每次用户态启动随机，`launchdhook/src/main.m:213, 220`）
- `sandboxExtensions`：3 个 token 用 `|` 连接（`libroothider/src/common.m:431-456`）：
  `com.apple.app-sandbox.read-write @ .../AppGroup/.jbroot-XXX/`、
  `com.apple.app-sandbox.read @ .../Bundle/Application/.jbroot-XXX/`、
  `com.apple.sandbox.executable @ 同上`
- `fullyDebugged`、`forceCSAdhoc`（前者来自"是否 App + 设置项"，后者来自"是否有 SPTMArgs"）

### 5.2 谁来读

`BaseBin/systemhook/src/main.c:346-372`
1. `task_info(TASK_DYLD_INFO)` → `dyld_all_image_infos->dyldImageLoadAddress`
2. `_dyld_get_image_uuid()` 检查前 4 字节是 `"DOPA"`（`:352-355`）
3. `getsectiondata(dyldHeader, "__DATA", "__jbinfo", &size)`（`:358-360`）
4. `state == DYLD_STATE_CHECKED_IN` 才取数据（`:363-369`）

失败则退回 XPC checkin（`:383-394`）。这条 fallback 是**默认模式（无 dyld patch）**必走的路径，此时 `__jbinfo` 根本不存在。

### 5.3 攻击面（任何人可在自己的进程里读）

**【已验证，只需公开 API】**

```c
task_dyld_info_data_t di; uint32_t c = TASK_DYLD_INFO_COUNT;
task_info(mach_task_self_, TASK_DYLD_INFO, (task_info_t)&di, &c);
struct dyld_all_image_infos *infos = (void *)di.all_image_info_addr;
const struct mach_header_64 *dyld = (void *)infos->dyldImageLoadAddress;
size_t sz; void *sec = getsectiondata(dyld, "__DATA", "__jbinfo", &sz);   // 0x4000
```

不需要任何 entitlement，只需要走 dyld-patch 分支（用户在设置里打开"dyld patch"时）。泄露内容与后果：

| 泄露项 | 后果 |
|---|---|
| `jbRootPath` | **直接击穿 jbroot 随机化**（本来要枚举 `.jbroot-<16hex>` 才能猜到） |
| `sandboxExtensions` | 是 bearer token；虽然通常已被本进程消费，但可用于"证明这个进程拿到了越狱方签发的扩展"，也是稳定的越狱指纹 |
| `bootUUID` | 与 `LAUNCHD_UUID` 关联，可用于跨进程/跨日志关联 |
| `fullyDebugged` / `forceCSAdhoc` | 泄露 jailbreak 配置（是否 markAppsAsDebugged、是否 SPTM 设备） |
| 段本身存在 | `__DATA,__jbinfo` + `LC_UUID` 前缀 `DOPA` = **零误报的越狱判定** |

此外 `parse_dyldhook_jbinfo` 依赖的 `"DOPA"` UUID 本身就是设计上的自证：
`BaseBin/systemhook/src/main.c:355`、`basebin_gen.m:64-84`。任何 App 读一下自己 dyld 的 `LC_UUID` 就能判定。

---

## 6. Q6：对检测方来说，还能看到什么（iOS 无 procfs 的等价手段）

前提：iOS 没有 `/proc/<pid>/maps`。等价/更强的面有：`_dyld_*` API、`task_info(TASK_DYLD_INFO)`、`vm_region_64` + `vm_read_overwrite`、`proc_regionfilename`、`csops(CS_OPS_STATUS)`、`mach_vm_region` 的 `share_mode`、以及"直接读自己进程内存"。

| # | 检测手段 | 在 roothide 3.x 下能看到什么 | 代码依据 | 可靠性 |
|---|---|---|---|---|
| 1 | `_dyld_image_count` / `_dyld_get_image_name` | **`/usr/lib/systemhook-<16hex>.dylib`**；TweakLoader 与所有 tweak 的**完整 `.jbroot-<jbrand>` 路径** | 可见性：`launchdhook/roothider.m:106-118`；自身检测代码 `libroothider/common.m:561-563`；TweakLoader `systemhook/main.c:530-540` | 极高（本 commit 未隐藏） |
| 2 | `_dyld_shared_cache_contains_path(path)` 交叉验证 | **凡是 `/usr/lib/*`、`/System/*` 却不在共享缓存里的镜像 = 越狱**（Apple 的 rootfs 库几乎全在 dsc；已知例外如 `libobjc_trampolines.dylib`，见 `fakelib_redirect.c:18-20`，需白名单） | 逻辑：`libroothider/signatures.m:167` 自己就在用这个前提；注入路径 `/usr/lib/...` 由 `roothider.m:117` 决定 | 极高（少量例外需排除） |
| 3 | `readdir("/usr/lib")` vs 镜像列表对照 | 名字在 image list 里，但**目录枚举里没有** → namei cache 拼接（真 rootfs 不可能出现） | `unsandbox1.m:74-263` / `unsandbox2.m:112-318` | 极高（原理性矛盾） |
| 4 | `stat()/fstatfs()` 检查该镜像 | `f_mntonname` 不是 `/`（是 `/private/var`），`st_dev` 与同目录其它条目不同 | `jbdomain_systemwide.c:123-133` 的注释正好说明这点 | 高 |
| 5 | mach-o load command 扫描：`__TEXT` 第一个 section 的 `segname[8..15]` | **非 0（等于 jbrand）**。正常镜像这两个字段是 0 填充 | `recdhash.m:120-141, 201-220`（`*rd2 = jbinfo(jbrand)` 写进 section segname 尾部） | 极高（未见合法例外）、还能直接恢复 jbrand |
| 6 | 直接读 `task_info(TASK_DYLD_INFO)` → `dyld_all_image_infos->infoArray` | 绕过一切 API 层 hook（rd27 原型就死在这里）；`infoArrayCount`/`imageFilePath` 原样 | `systemhook/main.c:337-340` 自己就是这么用的；rd27 `:322-329` | 极高（API hook 无法覆盖） |
| 7 | 遍历 `vm_region_64` + `proc_regionfilename` + 读每个 r-x 区的 mach header | 注入 dylib 的 `__TEXT` 是 preboot/data 卷的 file-backed 私有映射；dyld patch 模式下还会多出一大块**匿名** r-x（整份 dyld） | dyld patch：`dyld_patch.m:626, 693-760`；旧 dyld 被 `vm_deallocate`（`:764`）或清零头（`:451-470`） | 高（需要排除正常 App 自身 __TEXT） |
| 8 | dyld 自身校验：`LC_UUID` 是否 `DOPA*`；`getsectiondata(dyld,"__DATA","__jbinfo")` 是否存在；dyld 是否在 dsc 区间内 | dyld patch 模式下**三项全部命中** | `basebin_gen.m:64-84`；`systemhook/main.c:346-372` | 极高（但只覆盖 patch 模式） |
| 9 | `csops(pid, CS_OPS_STATUS)` | `CS_GET_TASK_ALLOW`（生产 App/系统守护进程不该有）；App 且 `markAppsAsDebugged` 时还有 `CS_DEBUGGED`、`CS_HARD/CS_KILL` 被清；其余进程是 `pmap` 层异常（csops 看不出） | `libroothider/common.m:24-34`；`kernel.c:312-345`；`jbdomain_systemwide.c:259-273` | 高（需知道基线） |
| 10 | "能不能执行未签名代码"自测 | iOS 16.3.1 上大概率**可以**（`pmap_cs_allow_invalid`；前提是 `koffsetof(pmap,txm_address_space)` 或 `wx_allowed` 命中） | `kernel.c:299-310, 339` | 高（行为型，绕不过） |
| 11 | 环境变量 | 大多数进程已清；但 **launchd 永久持有** `DYLD_INSERT_LIBRARIES=<jbroot>/basebin/launchdhook.dylib`；额外注入器存在时也不会被清 | `systemhook/main.c:396-403`（只清完全相等）；`launchdhook/main.m:213` | 中（App 读不到别的进程 env；root 工具可以） |
| 12 | 沙箱足迹 | 每个被注入进程都拿到 jbroot 的 `read`/`executable` 扩展；知道 jbroot 路径后 `open()` 直接成功 | `libroothider/common.m:431-456`；消费：`dyldhook/main.c:34-49`、`systemhook/main.c:43-58` | 高（需先拿到路径，通常从 #1 拿） |
| 13 | `.jbroot` 符号链接 | 越狱 App 的可执行目录里会被塞一个 `.jbroot -> <jbroot>` | `libroothider/common.m:364-412`，唯一调用点 `signatures.m:215`（只对 jbroot 内路径生效） | 中（仅越狱 App 自身） |
| 14 | 路径侧信道 | 枚举 `/var/containers/Bundle/Application/` 下 `.jbroot-<16hex>`（沙箱内读不到，root/entitled 进程可以） | `DOBootstrapper.m:930-948` | 中 |
| 15 | 静态文件/CDHash 指纹 | **失效**：每个 basebin 二进制 cdhash 都被 jbrand 随机化 | `recdhash.m:201-230`、`randomizeAndLoadBasebinTrustcache`（`common.m:457-500`） | 不可用（这正是设计目标） |

补充说明 #1 与 #6 的关系：本 commit 的注入镜像在 `_dyld_get_image_name` 里**名字是"干净"的（`/usr/lib/...`）**，但 #2/#3/#4/#5 都是"名字干净反而更可疑"的检查，所以"路径洗白"并不能降低被判定概率，只是把"明显是 /var/jb"换成"一个不该存在的 /usr/lib 库"。

---

## 7. 该设计比传统 rootless 强在哪 / 仍可能被检测的点

### 强在哪（每条都能落到代码）

1. **没有固定挂载点，也没有覆盖系统目录**。传统 rootless 的核心破绽是 `/var/jb` + 对 `/usr/lib` 等的 bind mount；roothide 用 namei cache 拼接替代 mount（`unsandbox1/2.m`），`statfs("/usr/lib").f_mntonname` 仍然是 `/`，`/var/jb` 不存在（`DOEnvironmentManager.m:658-661`），大量"查挂载/查 /var/jb"的检测直接失效。
2. **jbroot 名字是 64bit 随机 + 可重随机**（`DOBootstrapper.m:944-965, 1138-1190`），且藏在 `Bundle/Application/.jbroot-*` 这种"像 App 容器"的位置，路径型 IOC 无法长期有效。
3. **每个二进制的 cdhash 都被随机化**（`recdhash.m:216-230`），并同步更新 trust cache —— 基于哈希的静态特征库（包括"某个 dylib 的 cdhash 上黑名单"）完全失效。传统 rootless 的 basebin 二进制 hash 是全局同一份。
4. **注入库的文件名/路径伪装成系统库**（`/usr/lib/systemhook-<jbrand>.dylib`），比 `/var/jb/usr/lib/systemhook.dylib` 在"只看字符串"的检测里更像合法组件。
5. **每个进程的 `DYLD_INSERT_LIBRARIES` 被及时清除**（`systemhook/main.c:396-403`），且能按进程粒度决定"不注入 + 摘除"（`common.c:199-240, 325-355`），比"全局注入、进程里自查"更干净。
6. **dyld 层可以整体替换**（`dyld_patch.m` + `basebin_gen.m`），把 `getAMFI` 直接改成 `0xff`（`basebin_gen.m:48-62`），比"依赖 entitlements/签名"更根本；且旧 dyld 被 deallocate/清零，`vm_region` 不会出现"两个 dyld"。
7. **iOS 15 arm64e 的 shared cache 私有化**（`spinlock_fix.c:88-102`）解决了"给共享缓存页下 hook 会 panic"的老问题，使 hook 面可以覆盖 dsc 内的系统库。
8. **注入链路对"非 posix_spawn 场景"有兜底**：`execve` 用异常端口在 exec 后/dyld 前抓进程（`exec_trace.m:114-180`），`SETEXEC` 用 `jbdSpawnExecStart/Cancel`（`roothider_main.c:280-286, 313-314`），比只 hook posix_spawn 的方案覆盖更全。

### 仍可能被检测的点（按"性价比"排序）

1. **`/usr/lib/*` 但不在共享缓存** —— 一行代码、近似零误报（#6.2，注意排除少数本来就不在 dsc 的库）。这是整套方案最硬的破绽，而且**它由"路径洗白"这个设计本身产生**：不洗白就是 `/var/jb`，洗白就是"假系统库"。
2. **section `segname` 尾部被写入 jbrand**（`recdhash.m:216`）—— 这是为了随机化 cdhash 而引入的**新的、零误报的特征**，还能直接反推 jbrand。检测方只需遍历 `_dyld_get_image_header(i)` 的 load commands。
3. **image list 里出现完整 `.jbroot-<jbrand>` 路径**（TweakLoader/tweaks，`systemhook/main.c:533`）—— 直接击穿第 2 条"随机化"的价值；再配合 #12 的沙箱扩展，App 通常可以 `opendir()` 整个 jbroot（`/var` 与 `/private/var` 的路径归一化由沙箱处理【推测】）。
4. **直接的 `task_info(TASK_DYLD_INFO)` 读 `infoArray`**（#6.6）—— 任何在 `_dyld_*` 上做文章的方案（包括 rd27 原型）都绕不过它；`infoArrayCount` 也没有被改小。
5. **`csops` 基线异常**：默认模式（非 dyld patch）下 `CS_GET_TASK_ALLOW` 出现在所有被注入进程上（`common.m:30`）；App 且开启 `markAppsAsDebugged` 时还会被清 `CS_KILL/CS_HARD`、置 `CS_DEBUGGED`（`kernel.c:322-336`）—— 这类"进程安全属性被改"没法用路径伪装掩盖。
6. **可执行未签名代码**（`pmap_cs_allow_invalid`，`kernel.c:339`）—— 行为型检测，最抗对抗；传统 rootless 也需要，但 roothide 把它开得更彻底（每个 checkin 进程）。
7. **`__DATA,__jbinfo` + `LC_UUID` 前缀 `DOPA`**（`basebin_gen.m:64-84`、`systemhook/main.c:355`）—— 只在 dyld patch 模式出现，但一旦出现就是铁证，并且 `__jbinfo` 还**主动泄露 jbroot 路径、bootUUID、sandbox token、配置位**（§5.3）。
8. **dyld patch 模式的 vm 布局异常**：整份 dyld 是匿名/文件私有映射（`dyld_patch.m:626`），`dyld_all_image_infos->dyldImageLoadAddress` 落在 dsc 之外；`vm_region` + `proc_regionfilename` 能看出"一个不属于任何系统文件的 r-x 大块"。
9. **namei cache 拼接的固有矛盾**：`open` 成功但 `readdir` 看不到（#6.3）；且这种名字在**重启后消失**，检测方只要"重启后枚举 + 运行中查 image list"就能构造不一致证据。另外它是内核结构篡改，`v_usecount` 被手工加一（`unsandbox1.m:106-122`），在极端内存压力/审计下仍有痕迹【推测】。
10. **launchd 永久持有 jbroot 路径的 `DYLD_INSERT_LIBRARIES`**（`launchdhook/main.m:213`）—— 对 root 级检测方（企业 MDM/越狱扫描器拿 root）是稳定的路径泄漏；也是"为什么 App 里看不到 env"的反面证据。

---

## 8. 关键结论对照表（速查）

| 问题 | 结论 | 状态 |
|---|---|---|
| 是否改 dyld `all_image_infos` 链表隐藏镜像 | **否** | 已验证（全仓无 infoArray 删除逻辑；唯一 `task_set_dyld_info` 是换 dyld） |
| 是否 hook `_dyld_image_count/name/header` | **否**（本 commit） | 已验证；rd27 原型 hook 了 name/dladdr，但不在 24ea745 |
| systemhook 在 dyld 视图里 | **可见**，`/usr/lib/systemhook-<jbrand>.dylib` | 已验证（自身检测代码 `common.m:561`） |
| TweakLoader/tweaks | **可见**，完整 jbroot 路径 | 已验证（`main.c:533`） |
| 真正的隐藏手段 | jbroot 随机路径 + namei cache 拼接 + env 清理 + cdhash 随机化 | 已验证（§1.3） |
| fakelib_redirect | `#if 0` 死代码；`.fakelib` 仅作为补丁 dyld 存放点/历史遗物 | 已验证 |
| bindfs 覆盖 `/usr/lib` | 已废弃（整段注释） | 已验证（`jbctl/internal.m:10-92`） |
| LV bypass | hook dyld `__fcntl`；F_ADDFILESIGS* 失败→把文件 cdhash 塞 trust cache | 已验证 |
| F_ADDSIGS（内存内签名） | roothide 下不特殊处理，走原生 syscall | 已验证（`lv_bypass.c:178-181`） |
| SPTM 的 forceCSAdhoc | 代码存在但 `#if 0` | 已验证（`lv_bypass.c:194-286`） |
| spinlock_fix | 仅 iOS15 arm64e；本机不编译 | 已验证（`spinlock_fix.c:1`） |
| 默认注入模式 | 改子进程 `CS_GET_TASK_ALLOW` + `cs_allow_invalid` + trust cache | 已验证（`common.m:218-226`、`kernel.c:312-345`） |
| dyld patch 模式 | 整份 dyld 替换，`getAMFI=0xff`，UUID=`DOPA*`，`__jbinfo` checkin | 已验证（§4.2） |
| checkin 通道 | bootstrap port（fallback `mach_ports_lookup`），`msgh_id=0x40000000\|206` | 已验证（`jbclient_mach.c:10-46`） |
| `dyld_jbinfo` 可被谁读 | 任何进程自己（无需 entitlement），含 jbroot/bootUUID/sandbox token | 已验证代码路径；"实际可读"为公开 API 推导 |
| 最有效的检测点 | `/usr/lib` 路径不在 dsc；section segname 尾部非 0；`infoArray` 直读；`csops` 基线 | 已验证代码依据 |

---

## 9. 未验证 / 需要上机确认的点（明确标注）

1. 【推测】`readdir("/usr/lib")` 确实不包含拼接名。依据是 namei cache 只参与 lookup 解析，APFS 目录枚举走 `vn_readdir` → 不经过 namecache。这是 VFS 常识，但没有在本机验证。
2. 【推测】拼接出来的 vnode 上 `fstat().st_dev` 与 rootfs 条目不同。代码里 `systemwide_trust_file` 通过 `fstatfs` 的 `f_mntonname` 区分（`jbdomain_systemwide.c:123-133`），可间接证明"能区分挂载点"，但 `st_dev` 未直接验证。
3. 【推测】`dyld_all_image_infos` 里的 `infoArray` 完全没被动过。代码里没有相关写入，但 dyld 内部 `gAllImages` 与 `infoArray` 的一致性无法静态证明。
4. 【推测】TweakLoader 具体如何加载 tweak（`/usr/lib/TweakLoader.dylib` 不在本仓库，来自 `basebin.tar`）；但"加载后是普通 dyld image"这点由 `dlopen` 语义保证。
5. 【推测】dyld patch 模式下 App 进程里 `__jbinfo` 的实际可读性（取决于该进程是否走了 dyld patch 分支；默认 `dyldPatchEnabled=NO`，所以默认模式下这一段**不存在**）。
6. 【推测】`sandbox_extension` token 是否可在同进程外重放。iOS 的扩展 token 通常是"发给某进程"的，但代码里只是字符串搬运（`main.c:55-68`），没有绑定校验，实际可否重放未验证。

---

### 附：本报告引用的核心文件清单

```
BaseBin/dyldhook/src/main.c                     dyldhook 入口 / checkin / __jbinfo
BaseBin/dyldhook/src/main.S                     MACHOMERGER_START_HOOK / trampoline / 裸 syscall
BaseBin/dyldhook/src/dyld_jbinfo.h              jbinfo 结构
BaseBin/dyldhook/src/lv_bypass.c                __fcntl hook / LV bypass
BaseBin/dyldhook/src/spinlock_fix.c             iOS15 dsc 私有化
BaseBin/dyldhook/src/roothider.c                @loader_path/.jbroot 展开
BaseBin/dyldhook/src/fakelib_redirect.c         #if 0 死代码
BaseBin/dyldhook/src/reimpl.c                   dyld 内自实现 libc/mach
BaseBin/dyldhook/src/generated/ios16-17/task.c  MIG: task_get_special_port / mach_ports_lookup
BaseBin/libroothider/src/unsandbox1.m|2.m       namei cache 拼接（/usr/lib 假文件）
BaseBin/libroothider/src/dyld_patch.m           dyld 整份替换 / task_set_dyld_info
BaseBin/libroothider/src/recdhash.m             cdhash 随机化（segname 写 jbrand）
BaseBin/libroothider/src/common.m               csflags / jbroot 布局 / sandbox 扩展 / 自检测
BaseBin/libroothider/src/exec_trace.m           execve 异常端口兜底
BaseBin/libjailbreak/src/basebin_gen.m          补丁 dyld 生成（getAMFI / DOPA UUID）
BaseBin/libjailbreak/src/kernel.c               cs_allow_invalid / pmap_cs
BaseBin/libjailbreak/src/jbclient_mach.c        checkin mach 协议
BaseBin/systemhook/src/main.c                   构造器 / jbinfo 解析 / unsetenv / TweakLoader
BaseBin/systemhook/src/common/common.c          posix_spawn 注入 / trust / env 处理
BaseBin/systemhook/src/roothider_main.c         dyld 函数指针 hook / 注入策略
BaseBin/launchdhook/src/roothider.m             systemhook 路径生成 + unsandbox
BaseBin/launchdhook/src/spawn_hook.c            launchd 侧 spawn hook
BaseBin/launchdhook/src/jbserver/jbdomain_systemwide.c  checkin / trust cache
BaseBin/launchdhook/src/jbserver/jbdomain_platform.c    set_process_debugged
Application/Dopamine/Jailbreak/DOBootstrapper.m jbroot 目录与 jbrand
Application/Dopamine/Jailbreak/DOJailbreaker.m  启动流程 / dyld_patch 默认值
```

（旁证，不属于本 commit：`/Users/dan/Desktop/iphone/rd27/BaseBin/systemhook/src/main.c`、`/Users/dan/Desktop/iphone/roothide-src/BaseBin/systemhook/src/main.c`）
