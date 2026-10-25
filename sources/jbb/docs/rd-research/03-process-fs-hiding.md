# roothide / Dopamine-roothide 3.x —— 进程 / 文件系统 / 守护进程层的隐藏与反检测

- 目标仓库：`/Users/dan/Desktop/iphone/rd-3x`，commit `24ea745`（"add roothide support for Dopamine 3"）
- 分析对象：iPhone 14 Pro（A16，arm64e）/ iOS 16.3.1，已越狱
- 性质：**只读源码分析**，未修改源码、未接触设备。文中所有“可检测”结论都标注了证据强度。
- 标注约定：
  - **【实现】**：代码在当前 commit 中真实编译并会执行。
  - **【条件】**：代码存在，但受开关 / `__builtin_available` / 运行时配置控制，16.3.1 默认路径下不一定生效。
  - **【禁用】**：代码存在但被 `#if 0`、注释或默认关闭，16.3.1 上不生效。
  - **【推测】**：由实现推导、未在设备上验证的行为（尤其是沙盒是否放行某个 syscall）。

**问题 → 章节对照**

| 任务问题 | 对应章节 |
|---|---|
| 1. 进程枚举隐藏（sysctl / proc_listallpids / launchctl / ps） | §2 |
| 2. 文件系统层（mount / sandbox extension / getattrlistbulk / NSFileManager / `.jbroot*` / `/var/jb` / systemhook dylib / MobileSubstrate / `.installed_*`） | §3 |
| 3. launchd 侧 spawn 注入、attr/env 清理、`CS_GET_TASK_ALLOW` | §4 |
| 4. daemon_hook / ipc_hook / jetsam_hook / crashreporter 各自解决什么 | §5 |
| 5. trustcache（basebin.tc、trustcache_fs.c、可枚举性） | §6 |
| 6. forkfix 解决什么 | §7 |
| 7. 16.3.1(A16) 仍存在的可检测痕迹（按 App 沙盒优先级） | §8 |

---

## 0. 结论速览（先看这 10 条）

1. **roothide 3.x 没有做内核级进程隐藏**。整个仓库里没有 hook `sysctl(KERN_PROC_ALL)`、`proc_listallpids`、`proc_pidpath` 的代码，也没有把进程从 `allproc` 链表摘除的代码。`jailbreakd` 在 `ps` / `sysctl` 里是**可见**的。【实现 + 已验证性的代码检索】
2. 它的隐藏思路是“**不产生可疑的持久实体**”：`jailbreakd` 不是 launchd job（`launchctl list` 看不到），由 launchd 用 `posix_spawn` 直接拉起，路径落在随机名的 `.jbroot-<16hex>` 里，`argv[0]` 就叫 `jailbreakd`。
3. `hookd` 进程在 **iOS 16.3.1 上根本不会启动**：`hookd_provider_init()` 被 `if (__builtin_available(iOS 19.0, *))` 包住（`launchdhook/src/main.m:175-181`），`systemhook` 里同一逻辑也在 19+（`systemhook/src/main.c:405-434`）。
4. 进程隐藏真正的落点是 **launchd 的 XPC 应答过滤**，而且**只对被标记为 blacklist 的 App 生效**：`libroothider/src/xpc_hook.m:271-367` 把 job 名清空、把 pid 改成 `INT_MAX`、把 coalition 信息抹掉。普通 App 拿到的仍是全量信息。
5. 文件系统层最核心、也最“黑”的一招：`/usr/lib/systemhook-<jbrand>.dylib` **在磁盘上不存在**，是 `libroothider/src/unsandbox1.m:74-295` 直接改内核 `namecache` 造出来的**虚拟目录项**——`readdir/getattrlistbulk` 看不到，但按路径 `open/stat` 能命中，vnode 实际在 jbroot 里。
6. 整套东西的“根”是 jbroot：`/private/var/containers/Bundle/Application/.jbroot-<16hex>`，`jbrand` 是 64 位随机数且低字节是校验和（`DOBootstrapper.m:944-962`），并且 `/var/jb` 是指向它的符号链接（`DOBootstrapper.m:249-264`）。
7. 沙盒不是靠 hook 文件 API 绕过的，而是**在 checkin 时给每个被注入进程发 sandbox extension**（`libroothider/src/common.m:431-455`），App 因此真的能读 jbroot。
8. 注入链的关键内核位是 **`CS_GET_TASK_ALLOW`**：`dyld_patch_enabled` 默认是 **NO**（`DOJailbreaker.m:635`），于是每个子进程被 `proc_csflags_set(proc, CS_GET_TASK_ALLOW)`（`libroothider/src/common.m:24-35`），让**原厂 dyld** 愿意接受 `DYLD_INSERT_LIBRARIES`。这是 16.3.1 上最稳的一条注入路径，也是最稳的一条**检测特征**。
9. App JIT 默认开启（`appJITEnabled` fallback `YES`，`DOJailbreaker.m:612`）→ checkin 时 `fullyDebugged=true` → arm64e 上也会 `CS_DEBUGGED`。所以注入过的 App **同时带 `CS_GET_TASK_ALLOW | CS_DEBUGGED`**，`csops(CS_OPS_STATUS)` 一行就能判定。
10. 崩溃日志确实是泄露面：launchd 的 crash reporter 会写 `/var/mobile/Library/Logs/CrashReporter/<name>-*.ips`，里面 `Images:` 段完整打印 `_dyld_get_image_name()`（`libroothider/src/crashreporter.m:295-301`），必然包含 `/usr/lib/systemhook-<jbrand>.dylib` 和 jbroot 路径。App 沙盒读不到这个目录，但日志会被 Analytics / 用户导出。

---

## 1. 16.3.1 / A16 上到底哪些代码生效

这一节很重要，因为仓库里有大量“看起来在隐藏、其实在 16.3.1 上是死代码”的部分。

| 机制 | 16.3.1/A16 是否生效 | 证据 |
|---|---|---|
| `systemhook` 注入（DYLD_INSERT_LIBRARIES） | 生效 | `systemhook/src/main.c:437-440` |
| forkfix | 生效（仅能 fork 的进程） | `systemhook/src/main.c:481-487` |
| `csops`/`necp` 伪造（`CS_VALID`） | **不生效**（`#ifndef __arm64e__`，A16 是 arm64e） | `systemhook/src/main.c:123-197`、`509-522` |
| dyld 重映射（patched dyld / `DOPA` UUID） | **默认不生效**（`dyldPatchEnabled` fallback NO） | `DOJailbreaker.m:635`、`libroothider/src/dyld_patch.m:593-810` |
| `.fakelib` bind mount 到 `/usr/lib` | **不生效**（代码整段被注释） | `jbctl/src/internal.m:9-95`、`launchdhook/src/spawn_hook.c:37-56`、`DOEnvironmentManager.m:634-650` |
| `hookd` 进程 | **不生效**（iOS 19+） | `launchdhook/src/main.m:175-181` |
| `/usr/lib/systemhook-*.dylib` namecache 虚拟文件 | 生效 | `launchdhook/src/roothider.m:106-118`、`libroothider/src/unsandbox1.m:74-295` |
| launchd XPC 应答过滤 | 生效，但只对 blacklist App | `libroothider/src/xpc_hook.m:271-367` |
| `developer_mode_status` OID 交换 | 生效（仅 firstLoad） | `libroothider/src/launchd.m:122-154`、`334-341` |
| launchdhook 内的 crash reporter | 生效（`launchdhook/src/crashreporter.m` 整个 `#if 0`，实际用 `libroothider` 那份） | `launchdhook/src/crashreporter.m:1`、`libroothider/src/crashreporter.m:599-620` |

> 结论：16.3.1 上这套东西是“**内核 CS 位 + 原始 dyld + 明修栈道的 namecache**”的组合，而不是 2.x 时代的 bind mount 方案。

---

## 2. 进程枚举与进程隐藏

### 2.1 越狱相关进程清单（真实运行态）

| 进程 | 谁拉起 | 是否存在 launchd job | 路径 / argv |
|---|---|---|---|
| `jailbreakd` | launchd 自己 `posix_spawn` | **否** | `<jbroot>/basebin/jailbreakd`，`argv[0]="jailbreakd"` |
| `hookd` | launchdhook（仅 iOS 19+） | 否 | `<jbroot>/basebin/hookd` |
| `boomerang` | launchd（用户态重启时短暂存在） | 否 | `<jbroot>/basebin/boomerang` |
| bootstrap 里的守护进程（sshd 等） | `launchctl bootstrap system` 从 `<jbroot>/Library/LaunchDaemons` 载入 | **是** | 各自 plist |
| `jbserver` | **不是进程**，跑在 launchd 内部 | — | `xpc_hook.c` 把 launchd 收到的 XPC 截下来自己处理 |

`jailbreakd` 的启动代码：

```c
// BaseBin/libroothider/src/jailbreakd.c:136
int ret = posix_spawn(&pid, JBROOT_PATH("/basebin/jailbreakd"), NULL, &attr,
                      (char*[]){"jailbreakd",NULL}, ...);
```

关键点：

- **没有 plist**。它不经过 launchd job 机制，所以 `launchctl list` / launchd 的 job 字典里根本没有它（`daemon_hook` 只是把 `<jbroot>/basebin/LaunchDaemons` 和 `<jbroot>/Library/LaunchDaemons` 合进 launchd 的 "LaunchDaemons"/"Paths" 字典，见 `launchdhook/src/daemon_hook.m:35-65`）。
- launchd 侧显式放行它、不做注入：
  ```objc
  // BaseBin/launchdhook/src/roothider.m:408-410
  if(string_has_suffix(path, "/basebin/jailbreakd")) {
      return __posix_spawn_orig_wrapper(pidp, path, desc, argv, envp);
  }
  ```
- 通信端口不注册成 bootstrap 服务名，而是塞进 **host special port `HOST_LAUNCHCTL_PORT`**：
  ```c
  // BaseBin/libroothider/src/jailbreakd.c:55-59
  host_set_special_port(self_host, HOST_LAUNCHCTL_PORT, gJailbreakdPort);
  ```
  客户端用 `host_get_special_port(...HOST_LOCAL_NODE, HOST_LAUNCHCTL_PORT...)` 取（同文件 `64-77`）。
  → **没有 `com.opa334.jailbreakd` 之类的 Mach 服务名可枚举**（对比 1.x，`common.m:554-558` 还在检测这个老服务名）。

### 2.2 sysctl / libproc：**没有隐藏**

全仓库检索结果（`grep KERN_PROC|proc_listallpids|proc_listpids|PROC_PIDLIST`）只有：

- `systemhook/src/roothider_common.c:12-35`：读自己的 ppid（`KERN_PROC_PID` + `proc_pidinfo`）。
- `systemhook/src/roothider_main.c:28-49`：读自己的 suid（`KERN_PROC_PID`）。
- `libjailbreak/src/util.c:1193-1233`：`killall()` 自己遍历 `KERN_PROC_ALL`。
- `dopamine/src/main.m:319-341`：调试打印进程列表。

**没有任何一处** hook 这些函数，也没有 `allproc` 链表摘除（`grep allproc` 只命中 `info.h` 的符号表和 `util.c:77` 的 `proc_find`）。

因此：

- 【实现/确定】`ps`、`sysctl(KERN_PROC_ALL)`、`proc_listallpids()` 都能看到 `jailbreakd`。
- 【实现/确定】`proc_pidpath(jailbreakd_pid)` 返回 `<jbroot>/basebin/jailbreakd`，路径里带 `.jbroot-<16hex>`，直接泄露 jbrand。
- 【推测】沙盒 App 是否能看到**别的**进程，取决于 16.3.1 上 `kern.proc.all` 的沙盒策略；`KERN_PROC_PID`（查自己）一定可以。这一点必须在设备上实测（见 §8 的测试清单）。

### 2.3 `__sysctl` hook 实际只干一件事：伪装开发者模式

```c
// BaseBin/systemhook/src/roothider_common.c:124-164  __sysctl_hook
// BaseBin/systemhook/src/roothider_common.c:171-190  __sysctlbyname_hook
```

逻辑：把 `security.mac.amfi.developer_mode_status` 的读取**重定向**到 `security.mac.amfi.launch_env_logging`，失败则强行写回 `1`。
这个 hook 在 launchd 里装（`launchdhook/src/roothider.m:120-126`），在普通进程里由 systemhook 装（`systemhook/src/roothider_main.c:634-639`，且 `isRemovableBundlePath()` 为真时**不装**——即普通 App 进程里不装，避免 App 自己读到差异）。

配套的内核级操作：

```c
// BaseBin/libroothider/src/launchd.m:122-154  hideDeveloperMode()
// 把 developer_mode_status 与 launch_env_logging 两个 sysctl_oid 的
// number / name / descr / kind 互换后重新挂链
```

→ 从 root shell 看 `sysctl -a | grep developer`，两个节点已经“名字对调”，是**取证可观测**的（见 §8）。

### 2.4 真正做“进程隐藏”的地方：launchd XPC 应答过滤（条件性）

`launchdhook` 在 launchd 里 hook 了 `xpc_receive_mach_msg`：

```objc
// BaseBin/launchdhook/src/xpc_hook.c:17-62
// 1) 先看是不是 jbserver 的私有 mach 消息（magic "DOPAMINE"）
// 2) 不是的话交给 jbserver_received_xpc_message()
// 3) 是越狱消息就吞掉（return 22）
```

`libroothider/src/xpc_hook.m:271-367` 的 `roothide_handle_xpc_msg()` 会看**调用者是不是 blacklist 进程**，是的话改请求/改应答：

```objc
// 隐藏 job（launchd 的 job 描述查询，subsystem=2 routine=708）
// BaseBin/libroothider/src/xpc_hook.m:280-313
xpc_dictionary_set_string(xmsg, "name", "");
```

```objc
// 隐藏 pid（subsystem=6 routine=301）
// BaseBin/libroothider/src/xpc_hook.m:315-335
xpc_dictionary_set_int64(xmsg, "pid", INT_MAX);
```

```objc
// 隐藏 coalition / resource usage（应答侧，subsystem=3 routine=829）
// BaseBin/libroothider/src/xpc_hook.m:181-206
xpc_dictionary_set_value(reply, "cid", NULL);
xpc_dictionary_set_value(reply, "name", NULL);
xpc_dictionary_set_value(reply, "bundle_identifier", NULL);
xpc_dictionary_set_value(reply, "resource-usage-blob", NULL);
xpc_dictionary_set_int64(reply, "error", 3);
```

**适用范围**（很关键）：

- `isBlacklistedToken()`（`libroothider/src/blacklist.cpp:101-106`）只对 `RootHideConfig.plist` 里 `appconfig[bundleID] == true` 的 App 为真（`libroothider/src/blacklist.m:69-94`）。
- 默认没有全局隐藏。Dopamine 自己永远不算 blacklist（`blacklist.m:53-67` 的 `builtinApps()`）。
- 【推测】subsystem/routine 号分别对应 launchd 的 job 描述查询与 coalition/进程信息查询；具体由哪个公开 API 触发（`launchctl` / RunningBoard / libproc 私有 XPC）需在设备上抓包确认。代码里的注释明确写了 "hide job" / "hide pid"，语义是确定的。

### 2.5 其他与“进程可见性”相关的小动作

| 动作 | 位置 | 作用 |
|---|---|---|
| 进程被标记 debugged 后 `P_TRACED`/`p_oppid` 处理 | `systemhook/src/roothider_common.c:12-35` | 给 `__getppid()` 用，避免 sandbox 杀 |
| `ptrace` hook，附着时给自己和对方补 `cs_allow_invalid` | `systemhook/src/main.c:105-121` | 让 debugserver/`frida -f` 能挂上“未注入”的进程 |
| Dopamine App 自身被 platformize | `jbdomain_systemwide.c:338-347` | 给 App 加 `CS_PLATFORM_BINARY|CS_INSTALLER` |
| blacklist App 被禁止被注入 | `launchdhook/src/roothider.m:429-486` | 走 `allocBlacklistProcessId()` 记录，spawn 后登记 pidversion |

---

## 3. 文件系统层：不止“路径 hook”

### 3.1 布局总览

```
/var/jb  ──symlink──▶  /private/var/containers/Bundle/Application/.jbroot-<16hex>/
                            ├── basebin/            (launchdhook.dylib, systemhook-<jbrand>.dylib, jailbreakd, ...)
                            ├── usr/lib/            (TweakLoader.dylib, roothidepatch.dylib, roothideinit.dylib, ...)
                            ├── Library/            (bootstrap 的 LaunchDaemons / MobileSubstrate)
                            ├── var/ -> private/var (symlink)
                            └── private/var -> /private/var/mobile/Containers/Shared/AppGroup/.jbroot-<16hex>/var
```

- jbroot 名字生成：`DOBootstrapper.m:944-949`（`arc4random` 64 位，低字节 = 高 7 字节 XOR，见 `958-962`）。
- `/var/jb` 的创建：`DOBootstrapper.m:249-264`。
- “隐藏越狱”时把 `/var/jb` 删掉、同时取消 systemwide domain（`DOEnvironmentManager.m:658-690`）——注意 `jbclient_platform_set_systemwide_domain_enabled` 在 roothide 里是 **unsupported**（`jbdomain_platform.c:69-76` → `roothide_unsupport_request`），所以“隐藏”实际上只是删链接 + 停止注入，不是真的把系统还原。

### 3.2 核心：`/usr/lib/systemhook-<jbrand>.dylib` 是内核 namecache 造出来的假文件

【实现，且是本套机制里最独特的一层】

1. launchd 初始化时把 `basebin/systemhook.dylib` 改名为 `systemhook-<jbrand>.dylib`：
   ```objc
   // BaseBin/launchdhook/src/roothider.m:106-112
   NSString* systemhookFilePath = [NSString stringWithFormat:@"%@/systemhook-%016llX.dylib",
                                    JBROOT_PATH(@"/basebin"), jbinfo(jbrand)];
   ... moveItemAtPath ... toPath:systemhookFilePath
   ```
2. 调 `unsandbox("/usr/lib", systemhookFilePath)`（`roothider.m:114`），并在 16.3.1 上落到 `unsandbox1()`（`libroothider/src/unsandbox.m:90-97`，`>=16.4` 才用 v2）。
3. `unsandbox1()` 做的事（`libroothider/src/unsandbox1.m:74-295`）：
   - `open("/usr/lib")`、`open(<jbroot>/basebin/systemhook-<jbrand>.dylib)` 拿两个 vnode；
   - 把文件 vnode 的 `nc_dvp`（父目录）改成 `/usr/lib` 的 vnode（`182`）；
   - 把 `filevp->v_parent` 清零（`183`）；
   - 从 `nchead` / `nc_hash` / 父目录 `v_ncchildren` 里摘下原 namecache，按 `hash(dirvnode.v_id ^ crc32(name)) & nchashmask` 重新插进 `nchashtbl`（`186-244`，`index` 计算在 `170`）；
   - 最后 `open("/usr/lib/systemhook-<jbrand>.dylib")` + `F_GETPATH` 验证（`266-282`）。

实际效果：

| 行为 | 结果 |
|---|---|
| `ls /usr/lib` / `readdir` / `getattrlistbulk` | **看不到**（目录项在磁盘上没有，`v_ncchildren` 里也已被摘掉） |
| `open/stat("/usr/lib/systemhook-<jbrand>.dylib")` | **成功**（namecache 命中），vnode 是 jbroot 里的文件 |
| 不知道 jbrand 的进程 | 猜不到（2^64，且低字节有校验） |
| `fcntl(fd, F_GETPATH)` / `realpath` | 会暴露真实路径（jbroot 里） |
| 法证角度 | `v_parent == 0` 的 vnode + 跨 mount 的 `nc_dvp`，是**异常内核状态**，root 侧可查 |

> 这就是为什么 `HOOK_DYLIB_PATH` 是运行时算出来的（`systemhook/src/roothider_main.c:611`：`dyld_image_path_containing_address(&__dso_handle)`），而不是写死 `/usr/lib/systemhook.dylib`。

### 3.3 sandbox extension 层（比路径 hook 更重要）

【实现】`generate_sandbox_extensions()`：

```objc
// BaseBin/libroothider/src/common.m:431-455
jbroot_base     = /private/var/containers/Bundle/Application/.jbroot-<jbrand>/
jbroot_writable = /private/var/mobile/Containers/Shared/AppGroup/.jbroot-<jbrand>/

extension1 = sandbox_extension_issue_file_to_process("com.apple.app-sandbox.read-write", jbroot_writable, ...);
extension2 = sandbox_extension_issue_file_to_process("com.apple.app-sandbox.read",        jbroot_base, ...);
extension3 = sandbox_extension_issue_file_to_process("com.apple.sandbox.executable",      jbroot_base, ...);
```

- 由 launchd 里的 jbserver 在 `JBS_SYSTEMWIDE_PROCESS_CHECKIN` 时签发（`jbdomain_systemwide.c:251-256`），`writable` 取决于调用者是否有 `CS_PLATFORM_BINARY`（`247-252`）。
- 子进程拿到 token 字符串后 consume：
  - dyldhook 路径：`dyldhook/src/main.c:20-40` + `78-80`
  - systemhook 路径：`systemhook/src/main.c:43-58`（`consume_tokenized_sandbox_extensions`）
  - `sandbox_apply` 的 dlsym 篡改：`systemhook/src/main.c:60-103`
- **副作用（重要的检测面）**：任何被注入的 App 都**真的**拥有对 `.jbroot-<jbrand>` 的 read + executable extension。只要它知道 jbrand，就能 `stat/open` jbroot 里的文件（例如 `/.installed_dopamine`、`/basebin/.version`）。

### 3.4 路径重定向（只影响“越狱侧二进制”）

```c
// BaseBin/systemhook/src/roothider_main.c:129-173  redirect_paths()
if (realexepath 在 jbroot 内) {
    redirect_env_paths(rootdir);          // 把 CFFIXED_USER_HOME 指到 <jbroot>/<原 home>
    if (_CFCanChangeEUIDs()) loadPathHook();  // hook __CFCopyHomeDirURLForUser
}
if (ppid == 1 && getcwd() == "/") chdir(rootdir);   // launchd 拉起的 jbroot 二进制，cwd 改成 jbroot
```

- `CFFIXED_USER_HOME` 的计算见 `roothider_main.c:76-127`（容器内进程直接返回，不覆盖）。
- `__CFCopyHomeDirURLForUser` 的 hook 在 `roothidehooks/src/pathhook.x:11-43`，只在 `_CFCanChangeEUIDs()` 为真或 Dopamine App 里加载（`roothider_main.c:155-157`、`662-664`）。
- 这套只对“从 jbroot 启动的二进制”生效，**不会重定向 App 自己的路径**。

### 3.5 组件级的局部路径 hook（不是全局）

| 组件 | Hook | 作用 |
|---|---|---|
| cfprefsd | `__CFPrefsGetPathForTriplet` | 把非 Apple 的 `/var/<user>/Library/Preferences/*.plist` 重定向进 jbroot；blacklist 进程的请求不重定向（`roothidehooks/src/cfprefsd.x:11-96`） |
| lsd | `_LSSchemaCacheRead/Write`、`_UT*`、`_LSQueryContext` | 对 blacklist 进程隐藏“来自越狱 bundle 的 UTType / 插件”（`lsd.x:236-631`）；`_LSGetInboxURLForBundleIdentifier` 把 Inbox 重定向进 jbroot（`635-648`） |
| SpringBoard | `XBSnapshotContainerIdentity.snapshotContainerPath`、`FBSApplicationLibrary`、`FBSystemService.openApplication` | 快照/查询/拉起 jailbreak App 时重定向或拒绝（`springboard.x:48-111`） |
| runningboardd | `-[RBProcess _allowedLockedFilePaths]`（iOS16+） | 把越狱 App 的“允许锁定文件路径”换成 realpath 后的 jbroot 路径（`runningboardd.x:13-83`） |

注意：这些 dylib 只在 `cfprefsd / lsd / SpringBoard / runningboardd / watchdogd` 里加载（`systemhook/src/main.c:489-498`、`roothider_main.c:642-645`），**不是**全局文件系统 hook。

### 3.6 `/.jbroot` 符号链接链、`.installed_*` 与 `/Library/MobileSubstrate`

- **`.jbroot` 相对符号链接**：每个从 jbroot 里加载的 Mach-O，都会在同目录补一个 `.jbroot -> <jbroot 根>` 的链接（`libroothider/src/common.m:365-429`，调用点在 `signatures.m:215`）。
  目的：让 bootstrap 里那些“绝对路径符号链接”在目录整体被搬进 jbroot 后还能解析。安装期还会把 `readlink` 结果里 `/…/.jbroot-XXXX/<rest>` 改写成 `.jbroot/<rest>`（`DOBootstrapper.m:1374-1389`）。
  dyld 侧配合：`@loader_path/.jbroot...` 前缀被专门展开成 jbroot 实际路径（`dyldhook/src/roothider.c:12-39`）。
- **`.installed_dopamine` / `.installed_palera1n`**：位于 jbroot 根，内容分别是安装版本号/空（`DOBootstrapper.m:1497-1502`），也用于升级时识别旧安装（`DOEnvironmentManager.m:118-129`）。
  → 根文件系统上**不存在** `/.installed_*`；能读到它们就说明能进 jbroot。
- **`/Library/MobileSubstrate`**：本仓库**不处理**。Substrate 属于 bootstrap，实际位置是 `<jbroot>/Library/MobileSubstrate`；TweakLoader 从 `<jbroot>/usr/lib/TweakLoader.dylib` 加载（`systemhook/src/main.c:530-540`）。根文件系统的 `/Library/MobileSubstrate` 在 roothide 上不存在，所以这一类“老式检测路径”天然失效。

### 3.7 `NSFileManager` 走 libc 还是 syscall？——都没有 hook

- 全仓库没有 `getattrlistbulk` / `getdirentries` / `readdir` / `stat` 的 hook（唯一的 `statfs` 都在做自己的判断）。
- `NSFileManager` 最终走 Foundation → libsystem_kernel 的 `open/stat/getattrlistbulk/readdir`，与直接 syscall 等价。因此：
  - **目录枚举**永远看到“真实磁盘内容”（这就是 §3.2 的虚拟文件必须从 `v_ncchildren` 摘掉的原因）。
  - **按路径访问**能否成功，取决于三件事：路径是否真实存在、沙盒 extension 是否覆盖、是否命中 namecache 别名。
  - 隐藏的“魔法”不在 API 层，而在**布局**（jbroot 在数据卷）+ **沙盒 extension**（只有被注入进程有）+ **namecache**（唯一一个假路径）。

---

## 4. launchd 侧：注入决策与参数处理

### 4.1 spawn 决策树（`roothide_launchd___posix_spawn_prehook`）

`BaseBin/launchdhook/src/roothider.m:360-495`：

```
path == NULL                      → 走普通 __posix_spawn_hook（继承逻辑）
isRemovableBundlePath(path)       → 首次触发 fix__iosConnect()（修 IOSurface 句柄）
path == "/sbin/launchd"           → 强制 START_SUSPENDED（用户态重启）
path 是 Dopamine App 且首次加载   → EPERM（防中断后重入）；无 <path>.roothide 也 EPERM
path 以 /basebin/jailbreakd 结尾  → 直接 orig（不注入）
blacklist / Choicy 屏蔽           → 走“记录 pid + 可选 spinlock fix”分支
首轮（launchdhookFirstLoad）      → 直接 orig（先不全局注入）
其他                              → __posix_spawn_hook（正常注入）
```

`__posix_spawn_hook`（`launchdhook/src/spawn_hook.c:91-217`）再处理：

- **early boot 边界**：`gInEarlyBoot` 期间只有看到 `/usr/libexec/xpcproxy` 才结束 early boot，否则不注入（`191-200`）。
- **用户态重启**：`path == 自己` 时 `boomerang_stashPrimitives()`、`unmount(/Developer)`、应用 staged update，然后 `posix_spawn(argv, environ)`（`100-149`）。

### 4.2 注入参数到底怎么加、怎么删

**(a) posix_spawnattr**

roothide 版本在真正 spawn 之前**强制**给子进程加 `POSIX_SPAWN_START_SUSPENDED`：

```c
// BaseBin/systemhook/src/roothider_main.c:266-278
bool should_suspend = (proctype != POSIX_SPAWN_PROC_TYPE_DRIVER);
if (should_suspend) posix_spawnattr_setflags(attrp, flags | POSIX_SPAWN_START_SUSPENDED);
```

- 子进程先停在 `exec` 之后、用户态第一条指令之前；
- launchd 把 pid 发给 jailbreakd（`jbdSpawnPatchChild`，`roothider_main.c:315-323`），jailbreakd 做 `roothide_patch_proc(pid)`（`jailbreakd/src/server.m:69-92`）后再 `SIGCONT`；
- 调用者的 attr 在返回前被**恢复原样**（`roothider_main.c:310-311`），避免污染调用者后续复用。
- 若 patch 失败：`SIGQUIT` + `SIGKILL`（`roothider_main.c:317-322`），宁可杀掉也不让子进程裸奔。
- 如果是 `POSIX_SPAWN_SETEXEC`（exec 覆盖自身）：走 `jbdSpawnExecStart` → jailbreakd 用 `ptrace(PT_ATTACHEXC)` 跟踪 exec，再用 `kevent(EVFILT_PROC, NOTE_EXEC)` 在 exec 完成后补 patch（`libroothider/src/exec_trace.m:250-330`、`exec_patch.m:31-57`）。

**(b) 环境变量**

注入（`systemhook/src/common/common.c:312-323`，roothide 路径在 `roothider_main.c:290-301`）：

```c
snprintf(insert, ..., "%s:%s", HOOK_DYLIB_PATH, existingLibraryInserts);
envbuf_setenv(&envc, "DYLD_INSERT_LIBRARIES", insert);
if (envbuf_getenv(envc, "DYLD_INSERT_LIBRARIES")) {
    envbuf_setenv(&envc, "DYLD_IN_CACHE", "0");
    envbuf_setenv(&envc, "DYLD_SHARED_REGION", "use");
}
```

清除：

| 变量 | 清除位置 | 条件 |
|---|---|---|
| `DYLD_INSERT_LIBRARIES` | `systemhook/src/main.c:396-403` | **仅当值完全等于 `HOOK_DYLIB_PATH`**（即只有自己） |
| `DYLD_IN_CACHE` / `DYLD_SHARED_REGION` | `roothider_main.c:582-592` | 值分别为 `0` / `use` |
| `_SafeMode` / `_MSSafeMode` | `common.c:352-353`、`roothider.m:449-450` | **只在“不注入”分支**里删（给 Choicy 用） |

> 注意：如果 `DYLD_INSERT_LIBRARIES` 里还有别的条目（例如 launchd 继承下来的 `launchdhook.dylib`），`unsetenv` 条件不成立，变量会**留在 App 的 environ 里**。是否真的会残留取决于 launchd 给 job 传 env 的方式，需要在设备上 `getenv` 实测。

**(c) 其他“消痕”动作**

- `roothide_init()` 里 `dopamine_fixsugids()` 处理 dyldhook 的 setuid 辅助路径（`roothider_main.c:484-559`）。
- `main.m` 里 launchd 自己 `cs_allow_invalid(proc_self(), false)`（`launchdhook/src/main.m:173`），否则 launchd 改页后会被 CS 杀掉。

### 4.3 `CS_GET_TASK_ALLOW` 的作用（核心）

两条路径（`libroothider/src/common.m:218-225`）：

```c
int roothide_patch_proc(pid_t pid)
{
    if (dyld_patch_enabled() || process_force_dyld_patch(...)) return proc_patch_dyld(pid);
    return proc_patch_csflags(pid);          // ← 16.3.1 默认走这里
}

int proc_patch_csflags(pid_t pid)            // common.m:24-35
{
    uint64_t proc = proc_find(pid);
    if (proc) proc_csflags_set(proc, CS_GET_TASK_ALLOW);
}
```

- `CS_GET_TASK_ALLOW`（0x4）等价于“该进程带 get-task-allow”，**dyld 的 `ProcessConfig::hasGetTaskAllow()` 因此为真**，于是原厂 dyld 愿意处理 `DYLD_INSERT_LIBRARIES`，并且不再对插入的库做完整库验证。
- 因为是在 **exec 之前、进程已 suspend** 的状态下直接改内核 `proc->p_csflags`，子进程从第一条指令起就“自带 debuggable”，不需要 patched dyld。
- 副作用：任何调试器（含 `debugserver`）都能附着；`ptrace` hook 只是给**没被注入**的进程补这个位（`systemhook/src/main.c:105-121`）。
- 另一条路径 `proc_patch_dyld()`（`dyld_patch.m:593-810`）会把 `.fakelib/dyld`（带 `DOPA<version>` UUID，`basebin_gen.m:64-84`）`vm_remap` 进目标进程并从其 `entrypoint` 重新进入 dyld；默认关闭。

### 4.4 checkin：谁告诉进程“你在越狱里”

两条路：

1. **patched dyld 路径**：`dyldhook` 在 `dyld_start` 之前就跑（因为它被链接进 dyld），检查 `DYLD_INSERT_LIBRARIES` 含 `/systemhook` 后直接向 launchd 的 jbserver 发 mach checkin（`dyldhook/src/main.c:202-219`），把结果写进 dyld 的 `__DATA,__jbinfo` 段（`dyldhook/src/dyld_jbinfo.h`、`main.c:14`）。
2. **原始 dyld 路径（16.3.1 默认）**：`systemhook` 构造器里解析 `__jbinfo` 失败（因为 UUID 不是 `DOPA`），于是自己调 `jbclient_process_checkin()`（`systemhook/src/main.c:346-394`）。

jbserver 侧的 checkin 处理（`jbdomain_systemwide.c:205-396`）：

- 发 sandbox extensions（§3.3）；
- 判断是否 App → `fullyDebugged`（默认 true）；
- `cs_allow_invalid(proc, fullyDebugged)`；
- 修 setuid/setgid 二进制、`P_SUGID`（`275-307`）；
- **关掉 Protobox**：`proc_allow_all_syscalls(proc)` + `proc_remove_msg_filter(proc)`（`309-320`）。

---

## 5. daemon_hook / ipc_hook / jetsam_hook / crashreporter 各自解决什么

### 5.1 `daemon_hook`（`launchdhook/src/daemon_hook.m`）

- 在 launchd 的 `xpc_dictionary_get_value` 上挂钩，当它读 `"LaunchDaemons"` 时把 `<jbroot>/basebin/LaunchDaemons/*.plist` 和 `<jbroot>/Library/LaunchDaemons`（当前注释掉）塞进返回值；读 `"Paths"` 时追加 `<jbroot>/basebin/LaunchDaemons`（`35-65`）。
- 额外：删除 `com.apple.mtmergeprops.plist`（触屏固件重刷在用户态重启后会挂）。
- 放行 watchdogd 的 `com.apple.private.xpc.launchd.userspace-reboot`（`66-77`）。
- **反检测关系**：让守护进程可以完全生活在 jbroot 里，**不需要把 plist 写进 `/System/Library/LaunchDaemons`**（rootfs 上零残留），也不需要伪造 `launchctl` 的路径。

### 5.2 `ipc_hook`（`launchdhook/src/ipc_hook.c`）

- hook `sandbox_check_by_audit_token`：对非 blacklist 调用者，`mach-lookup` 的 `cy:` / `lh:` 前缀一律放行（`32-37`）；对 blacklist 调用者只记日志（`27-29`）。
- **反检测关系**：让 bootstrap 的 Mach 服务可以用非 Apple 命名空间而不被 launchd 的沙盒策略拦掉；同时**不给**检测类 App 开这个口子。

### 5.3 `jetsam_hook`（`launchdhook/src/jetsam_hook.c`）

- hook `memorystatus_control`，把 `MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT` 直接返回 0（`13-19`），并在初始化时清掉 launchd 的 limit/high-water（`23-24`）。
- 原因写在注释里：physrw 的页表记在 launchd 头上，容易被 jetsam 杀。
- **反检测关系**：纯稳定性，避免 launchd 被 jetsam 杀掉导致系统异常/重启（那本身会暴露）。

### 5.4 crashreporter（`libroothider/src/crashreporter.m`）

- `crashreporter_start()`：注册 `SIGILL/TRAP/ABRT/EMT/FPE/BUS/SEGV/SYS` 的 handler，并在 launchd / jailbreakd 里**装自己的 Mach exception port**（`599-620`）。
- 出错时写 `/<...>/CrashReporter/<comm>-<ts>.<usec>-<pid>.ips`，内容含寄存器、`Backtrace`、**完整 `Images:`**（`168-209`、`295-301`），然后 `reboot_np(RB_QUICK|RB_PANIC, ...)` —— 故意 panic 让问题“可见”（`31-39`、`330`、`385`）。
- **与反检测的关系（一正一负）**：
  - 正：`spawn_hook` 在调原始 `posix_spawn` 前后 `crashreporter_pause()/resume()`（`spawn_hook.c:75-80`、`libroothider/src/crashreporter.m:451-502`）。注释说得很直白：不暂停的话子进程会继承 exception ports，**这会触发越狱检测**（App 用 `task_get_exception_ports` 就能看到一个非系统的端口）。
  - 负：崩溃日志的 `Images:` 段把 `/usr/lib/systemhook-<jbrand>.dylib`、`<jbroot>/usr/lib/roothidepatch.dylib` 明文写盘。虽然 App 沙盒读不到 `/var/mobile/Library/Logs/CrashReporter`，但日志会被 Analytics/用户/取证工具带走。
- `launchdhook/src/crashreporter.m` 整个文件是 `#if 0`（第 1 行），16.3.1 实际链接的是 `libroothider` 这份。

### 5.5 `xpc_hook`（`launchdhook/src/xpc_hook.c` + `libroothider/src/xpc_hook.m`）

- 在 launchd 的 `xpc_receive_mach_msg` 上挂钩，把发给 launchd 的越狱消息接管（`xpc_hook.c:17-62`）。
- 意味着 **jbserver 不是一个独立进程/服务**：没有 `com.opa334.*` 的 launchd job，也没有 bootstrap 服务名可枚举。
- 同时做 §2.4 的 blacklist 过滤。

---

## 6. trustcache：16.3.1 上怎么工作、有没有可枚举条目

### 6.1 iOS 16 的链表位置

```c
// BaseBin/libjailbreak/src/trustcache.c:22-35  _trustcache_list_get_start()
if      (ksymbol(pmap_image4_trust_caches)) ...        // iOS <= 15
else if (ksymbol(ppl_trust_cache_rt))                  // iOS >= 16（PPL）
        return kread64(kread64(ksymbol(ppl_trust_cache_rt) + 0x20));
else if (ksymbol_txm(txm_trustcache_root)) ...         // iOS >= 17
```

16.3.1（PPL，非 TXM/SPTM）走第二条：`ppl_trust_cache_rt + 0x20` 指向链表头。

### 6.2 两类条目

| 类型 | 谁创建 | UUID | 是否带 `JB_MAGIC` | 能否被 `jbctl trustcache info` 枚举 |
|---|---|---|---|---|
| **JB 动态 trustcache** | `jb_trustcache_add_cdhashes()`（`trustcache.c:168-234`） | 随机（`uuid_generate`，`trustcache.c:10-15`） | 是（`JB_MAGIC`，`139-150`） | **能**（`jb_trustcache_info()` `252-276`） |
| **文件型 trustcache** | `trustcache_file_upload_with_uuid()`（`328-401`） | `"BASEBIN"` 或 `"DYLD"`（`trustcache.h:11-12`） | 否 | 不能（`_is_jb_trustcache` 为假） |

具体内容：

- **basebin**：roothide 3.x **不再用 `basebin.tc`**。Dopamine 启动时 `randomizeAndLoadBasebinTrustcache(JBROOT/basebin/)` 遍历目录里所有文件，逐个 `ensure_randomized_cdhash()` 后合成一个 `"BASEBIN"` 文件型 trustcache 上传（`libroothider/src/common.m:457-498`，调用 `DOJailbreaker.m:367-375`）。
- **dyld**：`ensure_dyld_trustcache(JBROOT/basebin/.fakelib/dyld)`（`common.m:669-698`）单独上传一个 `"DYLD"` 的。
- **`basebin.tc`**：仍然被 `update.m:32-41` 用于 jbupdate（从新 basebin 包里读 `basebin.tc` 再上传同 UUID 覆盖）。也就是说它是**升级通道的兼容格式**，不是日常加载路径。
- **运行时增量**：dyld 每次 `fcntl(F_ADDFILESIGS*)` 加载 dylib，都会被 `dyldhook/src/lv_bypass.c:165-296` 拦截，把 cdhash 加进 JB 动态 trustcache（`systemwide_trust_file()` → `jb_trustcache_add_cdhashes`，`jbdomain_systemwide.c:134-148`）。TrollStore Lite 的 App 在 spawn 时也整包加（`roothider.m:223-257`）。

### 6.3 `trustcache_fs.c` 的作用

`BaseBin/libjailbreak/src/trustcache_fs.c` 只是“遍历目录/文件 → 收集未受信的 cdhash → 调 `jb_trustcache_add_cdhashes`”的工具层（`80-107`），本身不碰内核。它被用于：

- `jb_trustcache_add_directory(bundlePath, true)`（TS Lite App 整包，`roothider.m:254`）；
- 其它 bootstrap/包管理路径。

### 6.4 cdhash 随机化（顺带的“反签名指纹”）

`ensure_randomized_cdhash_for_slice()`：

```objc
// BaseBin/libroothider/src/recdhash.m:216
*rd2 = jbinfo(jbrand);   // 写进 __TEXT,__text section 的 segname 尾部 8 字节
```

- 每个 basebin 二进制的 cdhash 因此**每次安装都不同**，无法用固定 cdhash 做指纹。
- 代价：`__TEXT,__text` 的 section name 尾部带着 **jbrand 明文**（8 字节，等于路径里的十六进制），成为一个可关联的标记（见 §8）。

### 6.5 “有没有留下可枚举的 trust cache 条目？”

- **App 沙盒内：没有**。trustcache 只在核内，没有用户态枚举接口；`csops` 只返回当前进程状态。
- **越狱侧（root）**：`jbctl trustcache info` 可以枚举 **JB 动态条目**（每条含 UUID + cdhash 列表，见 `jbctl/src/main.m:85-120` → `jbclient_root_trustcache_info()` → `jb_trustcache_info()`，`trustcache.c:252-276`）。文件型（BASEBIN/DYLD）不在此列（`_is_jb_trustcache` 为假），但内核链表里确实存在，任何有 krw 的进程都能遍历。
- **痕迹**：`jbctl trustcache info` 会打印出**当前加载的 TweakLoader / tweak dylib / TS Lite App 的 cdhash**，这是取证时最直接的“越狱正在运行”的证据之一（但需要 root）。

---

## 7. forkfix：解决“fork 之后 hook 失效/崩溃”

### 7.1 现象与原因

- systemhook 为了装 hook，会把可执行页改成可写（`vm_protect(... VM_PROT_WRITE|VM_PROT_COPY)`，`roothider_common.c:204-242`），并在 arm64e 上依赖 `pmap_cs_allow_invalid`（`kernel.c:299-310`）放行“无效代码页”。
- `fork()` 之后，子进程得到的是 COW 页，但：
  - 子进程的 `vm_map` 里每个 entry 的 `prot/maxprot`、`vme_xnu_user_debug` 标志并不保证与父进程一致；
  - 子进程的 `pmap->wx_allowed` / TXM `allowsInvalidCode` 不会自动继承；
  - TXM 设备的 code region 树需要复制。
  → 子进程一执行被 hook 过的页就崩（或 hook 静默失效）。

### 7.2 实现

`BaseBin/forkfix/src/main.c`：

```c
// 59-78
pid_t forkfix___fork(void) {
    open_pipes();
    pid_t pid = ffsys_fork();        // 内联 syscall，避免 hook 递归
    if (pid == 0) child_fixup();     // 子：写一个字节 → 阻塞读
    else         parent_fixup(pid);  // 父：等子就绪 → 让 jailbreakd 修 → 放行
    close_pipes();
    return pid;
}
```

- `parent_fixup` → `jbclient_mach_fork_fix(childPid)`（`main.c:49`）→ launchd jbserver → `systemwide_fork_fix()`（`jbdomain_systemwide.c:464-558`）：
  - 校验 `childProc->pptr == parentProc`（防伪造）；
  - `cs_allow_invalid(childProc, false)`；
  - 逐个 `vm_map_entry` 对齐，把父的 `prot/maxprot`、iOS16 的 `vme_xnu_user_debug` 复制给子（`495-543`）；
  - TXM 设备复制 code region 树（`429-462`、`546-551`）。
- 加载条件（只在确实能 fork 的进程里加载）：
  ```c
  // systemhook/src/main.c:481-487
  #ifdef __arm64e__
  if (sandbox_check(getpid(), "process-fork", SANDBOX_CHECK_NO_REPORT, NULL) == 0)
      dlopen(JBROOT_PATH("/basebin/forkfix.dylib"), RTLD_NOW);
  #endif
  ```
  → 普通 App 沙盒一般没有 `process-fork`，**不会**加载 forkfix（也就少一个 dylib 痕迹）；系统守护进程会加载。
- `forkfix` 里用 `dlopen("systemhook.dylib", RTLD_NOLOAD)` 找宿主（`forkfix/src/main.c:86-92`），说明它依赖 systemhook 已经加载。

---

## 8. iOS 16.3.1（A16）上仍然存在的可检测痕迹

排序原则：**App 沙盒内、几行代码、确定性高** 优先；需要 root/主动探测/取证 的靠后。

### P0 — App 沙盒内几行代码即可判定（高置信）

**① `csops(CS_OPS_STATUS)` 出现 `CS_GET_TASK_ALLOW | CS_DEBUGGED`**

- 证据链：注入时 `proc_csflags_set(CS_GET_TASK_ALLOW)`（`libroothider/src/common.m:24-35`，默认路径 `218-225`）；checkin 时 `cs_allow_invalid(proc, fullyDebugged)`，App 的 `fullyDebugged` 默认 true（`appJITEnabled` fallback YES，`DOJailbreaker.m:612`；`jbdomain_systemwide.c:258-267`），而 `cs_allow_invalid` 在 `emulateFully` 时会 `proc_csflags_set(CS_DEBUGGED)` 并清 `CS_KILL|CS_HARD`（`libjailbreak/src/kernel.c:322-337`）。
- A16 是 arm64e：`systemhook/src/main.c:123-197` 的 `csops` 伪装 hook 在 `#ifndef __arm64e__` 里，**不会**把这两个位抹掉。
- 检测代码（App 内，无需 entitlements）：
  ```c
  uint32_t f = 0; csops(getpid(), CS_OPS_STATUS, &f, sizeof(f));
  bool jb = (f & 0x4) && (f & 0x10000000);   // GET_TASK_ALLOW + DEBUGGED
  ```
- 注意：若用户关掉“App JIT”，`CS_DEBUGGED` 不一定会设，但 `CS_GET_TASK_ALLOW` 仍在 → 仍可判定。

**② dyld 镜像列表里出现 `/usr/lib/systemhook-`**

- 证据：`HOOK_DYLIB_PATH = dyld_image_path_containing_address(&__dso_handle)`（`systemhook/src/roothider_main.c:611`），实际值来自 `roothider.m:117` 的 `"/usr/lib/systemhook-%016llX.dylib"`，并且这个镜像**一定**在进程里。
- 检测：`_dyld_image_count()` + `_dyld_get_image_name()` 找 `strncmp(name, "/usr/lib/systemhook-", 20)==0` 并提取 16 位十六进制。
- 附带收益：拿到 jbrand 后可以直接走 ③。

**③ 用 ② 拿到的 jbrand 探测 jbroot（sandbox extension 已由 checkin 发放）**

- 证据：`generate_sandbox_extensions()` 给每个被注入进程发 read + executable 的 extension（`common.m:437-444`），App 由 dyldhook/systemhook 的 checkin consume（`dyldhook/src/main.c:78-80`、`systemhook/src/main.c:43-58`）。
- 检测（推断，需实测确认沙盒确实放行）：
  ```c
  char p[256]; sprintf(p, "/private/var/containers/Bundle/Application/.jbroot-%016llX/.installed_dopamine", jbrand);
  jb |= (access(p, R_OK) == 0);
  // 或读 /basebin/.version 拿版本号
  ```
- 若成立，这是**最强**的一条：既能判定，又能拿到版本。

### P1 — 主动探测（置信高，但“不像普通 App 会做的事”，易被反制）

**④ 直接向 launchd 发 jbserver 的 mach checkin（msg id 206 + magic "DOPAMINE"）**

- 证据：`jbclient_mach.c:39-48`（`msgh_id = 0x40000000|206`，注释说明 206 是 WebContent 沙盒唯一允许的 id）；`jbserver.h:52`（`JBSERVER_MACH_MAGIC 0x444F50414D494E45` = "DOPAMINE"）；`jbserver_mach.c:59-90`（回复里带 `jbRootPath`、`bootUUID`、`sandboxExtensions`、`fullyDebugged`）。
- 权限：`systemwide_domain_allowed()` 在 roothide 里被替换成 `roothide_domain_allowed()` —— 只要不是 blacklist 就放行（`jbdomain_systemwide.c:66-71`、`jbdomain_roothide.c:14-23`）。
- 检测：自己构造 message，收到 reply 的 `jbRootPath` 即实锤（还顺便拿到 jbroot 路径）。
- 代价：这个 probe 会让 launchd 对**调用者**执行 `cs_allow_invalid`、发 extensions（`jbdomain_systemwide.c:251-273`），即“探测即改变状态”。

**⑤ `/var/jb` → `.jbroot-` 符号链接**

- 证据：`DOBootstrapper.m:249-264` 创建 `/var/jb` 指向 `JBROOT("/")`；`DOEnvironmentManager.m:658-690` 只有“隐藏越狱”时才删。
- 检测：`lstat("/var/jb")` → `S_ISLNK` 且 `readlink` 含 `.jbroot-`。
- 置信：路径存在是确定的；**沙盒是否允许 lstat/readlink `/var/jb`** 需要实测（很多检测器用 `access("/var/jb")`，在沙盒里可能得到 EACCES 而非成功——那样只能算“不确定”）。

**⑥ `developer_mode_status` 被伪造**

- 证据：内核 OID 名字/编号互换（`libroothider/src/launchd.m:122-154`，仅 firstLoad `334-341`）+ launchd 内的 `__sysctl`/`__sysctlbyname` hook（`roothider.m:120-126`、`roothider_common.c:124-190`），把查询重定向到 `security.mac.amfi.launch_env_logging`，失败兜底返回 1。
- 检测思路：
  - 正常设备上 `developer_mode_status` 与 `launch_env_logging` 是两个独立 OID；被交换后，`sysctl -a` 里两个名字对应的描述/类型会“错位”。
  - App 侧可以对比 `sysctl("security.mac.amfi.developer_mode_status")` 与是否真的能用开发者模式相关 API（例如 `AMFI` 行为），出现不一致即为异常。
- 置信：机制确定；**具体返回值/可观测差异需实测**。

### P2 — 需要枚举进程 / 环境 / 端口（中等置信）

**⑦ 进程表里能看到 `jailbreakd`（路径含 `.jbroot-`）**

- 证据：没有 hook（§2.2）；`posix_spawn` 的 `argv[0]="jailbreakd"`、路径 `<jbroot>/basebin/jailbreakd`（`jailbreakd.c:136`）。
- 检测：`sysctl(KERN_PROC_ALL)` / `proc_listallpids()` 遍历，`proc_pidpath()` 找 `.jbroot-` 或 `basename=="jailbreakd"`。
- 置信：进程存在且路径如此是确定的；**沙盒 App 是否能拿到别的 pid 的 path** 需实测（`proc_pidpath` 对非本进程通常受 `com.apple.private.*` 限制）。

**⑧ 环境变量残留**

- `DYLD_INSERT_LIBRARIES` 只在“值恰好等于 HOOK_DYLIB_PATH”时被删（`systemhook/src/main.c:396-403`）。如果 launchd 的 environ 里还有 `launchdhook.dylib`，拼接后条件不成立 → 变量残留，可直接 `getenv` 读到 `/usr/lib/systemhook-` 前缀。
- `_SafeMode` / `_MSSafeMode` 只在“不注入”分支删除（`common.c:352-353`），被注入进程里如果调用者传了这两个变量，会原样保留。
- 置信：代码逻辑确定；实际是否残留取决于 launchd 传 env 的方式，建议设备上直接 `getenv` 验证。

**⑨ 异常端口（exception ports）**

- 设计上 `crashreporter_pause()` 在每次 spawn 前后摘掉 launchd 的 exception port（`spawn_hook.c:75-80`、`crashreporter.m:451-502`），就是为了避免子进程 `task_get_exception_ports` 看到非系统端口。
- 但这是“尽量”：如果 spawn 路径绕过 `__posix_spawn_orig_wrapper`（例如直接 `execve`、或 crashreporter 处于 active 状态的窗口期），仍可能继承。检测：`task_get_exception_ports(mach_task_self(), EXC_MASK_CRASH, ...)` 看是否有未知端口。
- 置信：缓解措施确定；“是否仍可复现”需实测。

**⑩ launchd XPC 侧信息（只对 blacklist App 隐藏）**

- 如果检测 App **没有**被用户加入 RootHide 黑名单，`launchctl` 类 XPC 查询仍会返回完整 job 列表/pid（`xpc_hook.m:271-367` 只在 `isBlacklistedToken` 为真时过滤）。
- 检测：通过 launchd 的 job 描述/coalition 查询（subsystem 2/708、6/301、3/829）看能否发现 jbroot 里的 job（例如 `com.openssh.sshd` 之类 bootstrap 守护进程）。
- 置信：过滤逻辑确定；**具体公开 API 映射**是推测。

### P3 — 沙盒内基本不可测 / 仅取证可见

| 痕迹 | 说明 | 证据 |
|---|---|---|
| `/usr/lib/systemhook-<jbrand>.dylib` 的 namecache 别名 | `readdir` 不可见；不知道 jbrand 无法 `stat`；`v_parent==0` 是内核异常状态 | `unsandbox1.m:182-183` |
| jbroot 目录本身（`.jbroot-<16hex>`） | 在 `/private/var/containers/Bundle/Application/` 下，App 无权限列举 | `DOBootstrapper.m:930-941` |
| BASEBIN / DYLD 文件型 trustcache | 仅内核链表可见 | `trustcache.c:328-401` |
| JB 动态 trustcache（含 TweakLoader / tweak dylib cdhash） | `jbctl trustcache info`（需 root） | `trustcache.c:252-276` |
| 崩溃日志 `Images:` 段 | 明文含 systemhook 路径 / jbroot 路径；App 读不到 `/var/mobile/Library/Logs` | `crashreporter.m:295-301`、`168-209` |
| sysctl OID 树错位（developer_mode） | root shell `sysctl -a` 可见 | `launchd.m:122-154` |
| `.jbroot` 符号链接（分散在 jbroot 各目录） | 只在 jbroot 内可见 | `common.m:365-429` |
| `DOPA<version>` 的 dyld UUID / `__jbinfo` 段 | **仅当 patched dyld 被使用**（`dyldPatchEnabled=YES` 或 2.x 遗留），16.3.1 默认不成立 | `basebin_gen.m:64-84`、`systemhook/src/main.c:346-372`、`dyldhook/src/main.c:202-219` |

### 8.1 一条“最短判定链”（建议设备实测）

```c
// 1) 内核 CS 位
uint32_t f=0; csops(getpid(), CS_OPS_STATUS, &f, sizeof(f));
if ((f & CS_GET_TASK_ALLOW) && (f & CS_DEBUGGED)) return JAILBROKEN;

// 2) dyld 镜像 + jbrand
for (uint32_t i=0;i<_dyld_image_count();i++) {
    const char *n=_dyld_get_image_name(i);
    if (!strncmp(n,"/usr/lib/systemhook-",20)) { jbrand = parse_hex(n+20); ... }
}
if (jbrand) {
    // 3) jbroot 可达性（依靠 checkin 发的 sandbox extension）
    char p[256]; snprintf(p,sizeof(p),
      "/private/var/containers/Bundle/Application/.jbroot-%016llX/.installed_dopamine", jbrand);
    if (access(p,F_OK)==0) return JAILBROKEN;
}
```

任何一步失败都不代表“干净”，因为 roothide 允许按 App 关闭注入/隐藏（blacklist + `_SafeMode`）。

---

## 9. “已实现 vs 推测”总表

| 结论 | 状态 |
|---|---|
| 没有 sysctl/libproc 层进程隐藏；`jailbreakd` 可见 | **实现**（代码缺失 + 调用链确定） |
| `jailbreakd` 不是 launchd job；走 `HOST_LAUNCHCTL_PORT` | **实现**（`jailbreakd.c:40-77, 136`） |
| `hookd` 在 16.3.1 不运行 | **实现**（`launchdhook/src/main.m:175-181`） |
| launchd XPC 应答对 blacklist App 隐藏 job/pid/coalition | **实现**（`xpc_hook.m:181-206, 271-367`） |
| 过滤只对 blacklist App 生效，不是全局 | **实现**（`blacklist.cpp:101-111`、`blacklist.m:69-94`） |
| `/usr/lib/systemhook-*.dylib` 是 namecache 虚拟项，readdir 不可见 | **实现**（`unsandbox1.m:74-295`） |
| `/var/jb` 是指向 jbroot 的符号链接 | **实现**（`DOBootstrapper.m:249-264`） |
| 每个注入进程获得 jbroot 的 sandbox extension | **实现**（`common.m:431-455`） |
| `CS_GET_TASK_ALLOW` 是 16.3.1 默认注入手段 | **实现**（`common.m:218-225`、`DOJailbreaker.m:635`） |
| App 默认 `fullyDebugged=true` → `CS_DEBUGGED` | **实现**（`DOJailbreaker.m:612`、`jbdomain_systemwide.c:258-267`、`kernel.c:322-337`） |
| 崩溃日志泄露 systemhook/jbroot 路径 | **实现**（`crashreporter.m:295-301`） |
| crash reporter 在 spawn 时被暂停以避免 exception port 继承 | **实现**（`spawn_hook.c:75-80`、`crashreporter.m:451-502`） |
| fork 后由 jailbreakd 修复 vm_map/TXM | **实现**（`forkfix/src/main.c:31-78`、`jbdomain_systemwide.c:464-558`） |
| basebin 不再用 `basebin.tc`，改为“遍历目录 + 随机化 cdhash + BASEBIN UUID” | **实现**（`common.m:457-498`、`recdhash.m:216`） |
| iOS 16 trustcache 在 `ppl_trust_cache_rt` 链表 | **实现**（`trustcache.c:22-35`） |
| `developer_mode_status` 被重定向/伪造 | **实现**（`launchd.m:122-154`、`roothider_common.c:124-190`） |
| 沙盒 App 能否 `stat` 到 jbroot（extension 是否足够） | **推测**（需实测） |
| 沙盒 App 能否用 `KERN_PROC_ALL` 看到别的进程 | **推测**（需实测） |
| subsystem 2/708、6/301、3/829 对应哪个公开 API | **推测** |
| `DYLD_INSERT_LIBRARIES` 在 App 里是否真的残留 | **条件**（取决于 launchd 传 env） |
| 能否用 `task_get_exception_ports` 发现残留 | **条件/需实测** |
| `DOPA` dyld UUID 在 16.3.1 默认存在 | **否**（默认 `dyldPatchEnabled=NO`，且 fakelib 未挂载） |

---

## 10. 关键文件索引

```
BaseBin/systemhook/src/main.c                 注入入口、dyld hook、forkfix 加载、env 清理
BaseBin/systemhook/src/roothider_main.c       roothide 版 spawn/execve hook、路径重定向、dlopen 信任
BaseBin/systemhook/src/roothider_common.c     sysctl 伪装、substrate 兼容、vm_protect
BaseBin/systemhook/src/common/common.c        spawn 公共逻辑（env/jetsam/persona）
BaseBin/systemhook/src/common/envbuf.c        环境变量数组操作
BaseBin/roothidehooks/src/{cfprefsd,lsd,springboard,runningboardd,pathhook}.x
BaseBin/launchdhook/src/main.m                launchd 注入、jbserver 初始化
BaseBin/launchdhook/src/roothider.m           systemhook 改名 + unsandbox + 注入决策树
BaseBin/launchdhook/src/spawn_hook.c           launchd posix_spawn hook
BaseBin/launchdhook/src/{daemon_hook.m,ipc_hook.c,xpc_hook.c,jetsam_hook.c}
BaseBin/launchdhook/src/jbserver/*            jbserver domain 实现（systemwide/platform/roothide/...）
BaseBin/libroothider/src/{common.m,launchd.m,xpc_hook.m,blacklist.*,unsandbox1.m,recdhash.m}
BaseBin/libroothider/src/{crashreporter.m,exec_trace.m,exec_patch.m,dyld_patch.m}
BaseBin/libjailbreak/src/{jbclient_mach.c,trustcache.c,trustcache_fs.c,kernel.c,jbroot.c}
BaseBin/libjailbreak/src/jbserver.c           jbserver 消息分发
BaseBin/forkfix/src/main.c                    fork 修复
BaseBin/hookd/src/main.c                      iOS 19+ 的 hook 代理（16.3.1 不用）
BaseBin/dyldhook/src/{main.c,lv_bypass.c,roothider.c}   patched dyld（默认不启用）
Application/Dopamine/Jailbreak/{DOJailbreaker.m,DOBootstrapper.m,DOEnvironmentManager.m}
```

---

### 附：给后续实测的建议（不改源码、只读验证）

1. 在注入 App 里打印 `csops` 结果、`_dyld_image_count/name`、`getenv("DYLD_INSERT_LIBRARIES")`、`task_get_exception_ports`。
2. 用上一步拿到的 jbrand，测试 `access()` / `stat()` / `open()` 到 jbroot 各文件；同时用 `readdir("/usr/lib")` 确认 systemhook 不在目录项里、但 `stat` 能命中。
3. 在非注入 App（Choicy 屏蔽或 blacklist）里重复 1-2，确认差异，区分“注入痕迹”和“全局痕迹”。
4. root shell 侧：`sysctl -a | grep -E "developer|launch_env"`、`jbctl trustcache info`、`cat /var/mobile/Library/Logs/CrashReporter/*.ips | grep -E "systemhook|jbroot"`。
