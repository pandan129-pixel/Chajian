# .28 崩溃日志分析（2026-11-02 ~ 11-03）

## 采集信息

- 设备：iPhone16,1（15 Pro）/ iOS 17.0 (21A327) / Relaxin + roothide
- SSH：`mobile@DEVICE_IP`，密码 `67352356`
  （与 `.buildtools/ssh28.exp` 一致）
- 日志目录：`/rootfs/private/var/mobile/Library/Logs/CrashReporter`
- 已拉取：**65 个 `.ips`，7.5 MB**，时间范围 `2026-11-02 02:36` ~ `2026-11-03 03:27`
- 本地副本：`plugins/crash-analyzer-pro/logs/28-CrashReporter/`

## 总览

| bug_type | 类型 | 数量 |
| --- | --- | --- |
| 309 | App crash | 26 |
| 308 | EXC_GUARD / LIBXPC user fault | 14 |
| 298 | JetsamEvent | 7 |
| 142 | wakeups_resource | 12 |
| 145 | diskwrites_resource | 2 |
| 202 | cpu_resource | 2 |
| 509 | watchdog termination | 1 |
| 221 | 其他资源报告 | 1 |

26 个 309 崩溃的分布：

| App | 次数 | 直接原因 |
| --- | --- | --- |
| Twitter 12.39 | 16 | `ZZNFXProbe.dylib` 的 `DumpObject` / `Probe` |
| TikTok 46.2.0 | 4 | `BHTikTok.dylib`（内嵌）`bundlePath` 路径 |
| WeChat 8.0.80 | 2 | `CallAssist.dylib` → roothide `jbroot()` 断言 |
| WFWidgetExtension 7.1.1 | 2 | iOS 18 编译的 widget 跑在 iOS 17 |
| Runner / 闲鱼 7.28.80 | 1 | nanov2 堆损坏（SIGABRT） |
| sharingd | 1 | NSXPCConnection 抛异常 → terminate |

---

## P0：WeChat 8.0.80 两次 SIGABRT —— CallAssist

时间：`2026-11-02 15:02:15`、`2026-11-02 16:08:38`

故障线程：`com.apple.main-thread`

```
0  libsystem_kernel.dylib  __pthread_kill
1  libsystem_pthread.dylib pthread_kill
2  libsystem_c.dylib        abort
3  libsystem_c.dylib        __assert_rtn
4  libroothide.dylib        jbrootat_alloc
5  libroothide.dylib        jbroot(NSString*)
6  CallAssist.dylib         (无符号)
7  CallAssist.dylib         (无符号)
8  libdispatch              _dispatch_call_block_and_release
...
```

结论：

- `CallAssist` 把一个**不是合法路径的字符串**传给 roothide 的 `jbroot()`，`jbrootat_alloc` 断言失败。
- 这是 CallAssist 的 roothide 适配问题，不是微信本身。
- 处理：更新/移除 `CallAssist`；或让作者把 `jbroot()` 调用改成只对真实路径使用。

文件：`WeChat-2026-11-02-150215.ips`、`WeChat-2026-11-02-160838.ips`

---

## P0：Twitter 12.39 十六次崩溃 —— ZZNFXProbe

时间集中在 `2026-11-02 05:00 ~ 06:41`，其中 4 次为：

```
EXC_BAD_ACCESS (SIGSEGV)
KERN_INVALID_ADDRESS at 0x69726f6765746163
  -> 0x00006f6765746163 (possible pointer authentication failure)
```

`0x69726f6765746163` 按小端是 ASCII `"categor i"`（像是把字符串当成了对象指针）。

故障线程：`com.apple.main-thread`

```
0  libobjc.A.dylib        object_getMethodImplementation
1  CoreFoundation         _NSIsNSString
2  CoreFoundation         -[NSArray descriptionWithLocale:indent:]
3  ZZNFXProbe.dylib       DumpObject
4  ZZNFXProbe.dylib       Probe
5  ZZNFXProbe.dylib       __newAppear_block_invoke
6  libdispatch            _dispatch_client_callout
...
```

结论：

- `ZZNFXProbe` 在 `DumpObject` 里对数组元素做 `description`/类型判断，遇到坏对象/非对象指针直接崩。
- 这不是 Twitter 官方代码的问题；`ZZNFXProbe` / `ZZNFXSettingsRow` 是直接嫌疑。
- 处理：移除或更新 `ZZNFXProbe.dylib`、`ZZNFXSettingsRow.dylib`；如果它是调试/探测工具，不要在日常使用中加载。

代表文件：`Twitter-2026-11-02-063727.ips`（同栈的还有 063633 / 063553 / 063506 等）。

---

## P0：TikTok 46.2.0 四次 SIGILL —— BHTikTok

时间：`2026-11-02 07:02:56 ~ 07:03:18`

```
EXC_BREAKPOINT (SIGILL)
faulting thread: com.apple.main-thread

0  libsystem_c.dylib     opendir
1  CoreFoundation        _CFIterateDirectory
2  CoreFoundation        _CFBundleCopyInfoDictionaryInDirectoryWithVersion
3  CoreFoundation        _CFBundleRefreshInfoDictionaryAlreadyLocked
4  CoreFoundation        CFBundleGetInfoDictionary
5  CoreFoundation        _CFBundleCreate
6  Foundation            -[NSBundle _cfBundle]
7  Foundation            -[NSBundle bundlePath]
8+ BHTikTok.dylib        (无符号)
...
```

结论：

- `BHTikTok.dylib` 位于 `TikTok.app/Frameworks/BHTikTok.dylib`（内嵌 mod），在 `bundlePath` / `CFBundle` 路径上触发非法指令。
- 同时加载了 `jbb.dylib`、`libsubstrate`、roothide 库；BHTikTok 与越狱注入的组合是直接触发点。
- 处理：移除/更新 BHTikTok；或把 TikTok 从 jbb/substrate 注入中排除后再测。

代表文件：`TikTok-2026-11-02-070318.ips`（另有 070316 / 070259 / 070256）。

---

## P1：闲鱼 Runner 7.28.80 堆损坏 —— jbb / XianyuDuo 嫌疑

时间：`2026-11-02 23:24:55`

```
EXC_CRASH (SIGABRT)
asi: libsystem_c.dylib: abort() called
faulting thread: com.taobao.network.rwpolicy.queue

0  libsystem_kernel        __pthread_kill
1  libsystem_pthread       pthread_kill
2  libsystem_c             abort
3  libsystem_malloc        malloc_vreport
4  libsystem_malloc        malloc_zone_error
5  libsystem_malloc        nanov2_guard_corruption_detected
6  libsystem_malloc        nanov2_allocate_outlined
7  CoreFoundation          _CFRuntimeCreateInstance
8  CoreFoundation          CFNumberCreate
9  Foundation              -[NSPlaceholderNumber initWithDouble:]
10 Foundation              _NSGetDoubleValueInIvar
11 Foundation              -[NSObject(NSKeyValueCoding) valueForKey:]
12 Runner                  (无符号)
13 Foundation              _encodeObject
14 Foundation              -[NSKeyedArchiver _encodeArrayOfObjects:forKey:]
15 Foundation              -[NSDictionary encodeWithCoder:]
16 Foundation              _encodeObject
17 Runner                  (无符号)
...
19 Foundation              +[NSKeyedArchiver archivedDataWithRootObject:requiringSecureCoding:error:]
```

已加载的 tweak：

```
libellekit.dylib
jbb.dylib
XianyuDuo.dylib
roothidepatch.dylib
libroothide.dylib
roothideinit.dylib
```

其它线程里唯一命中 tweak 的帧：

```
thread 21 (com.apple.root.default-qos) frame 12: jbb.dylib h_task_info
```

结论：

- 这是 **nanov2 guard page / 堆元数据损坏**，不是直接的空指针；损坏发生在更早的某次分配/写入。
- 崩溃栈落在闲鱼的 `NSKeyedArchiver` 编码路径，不能直接证明是闲鱼或某个 tweak，但 `jbb` 的 `h_task_info` 在另一个线程出现，`XianyuDuo` 也加载了。
- 建议排除法（按顺序）：
  1. 先禁用 `jbb`，冷启动闲鱼反复操作，观察是否还出 `nanov2_guard_corruption_detected`；
  2. 仍复现则禁用 `XianyuDuo`；
  3. 两者都禁用仍复现，再按闲鱼自身/其他 tweak 排查。
- 同时有 **7 次 Jetsam**，其中 4 次 `largestProcess=Runner`（闲鱼）：
  - 崩溃日志的 `vmSummary` 显示 `MALLOC 611.3MB`、`WebKit Malloc 160.1MB`；
  - 闲鱼内存峰值很高，Jetsam 与堆损坏可能相关（内存压力会放大越界/释放后使用）。

文件：`Runner-2026-11-02-232455.ips`

---

## P1：JetsamEvent 7 次

| 时间 | largestProcess |
| --- | --- |
| 2026-11-02 05:08:20 | WeChat |
| 2026-11-02 05:08:43 | WeChat |
| 2026-11-02 06:04:53 | AlipayWallet |
| 2026-11-02 08:14:22 | Runner |
| 2026-11-02 17:37:52 | Runner |
| 2026-11-03 00:21:16 | Runner |
| 2026-11-03 01:23:43 | Runner |

建议：

- 闲鱼是最大内存占用者；结合堆损坏，优先做 tweak 排除 + 内存峰值观察。
- 微信/支付宝各 1~2 次，属于偶发内存压力，不是当前主因。

---

## P2：sharingd SIGABRT —— NSXPCConnection 异常

时间：`2026-11-02 07:10:34`

```
faulting thread: com.apple.NSXPCConnection.user.com.apple.sharing.sharesheet.837
libc++abi: std::terminate
  <- -[NSXPCConnection _decodeAndInvokeMessageWithEvent:reply:flags:]
  <- NSInvocation invoke
  <- __exceptionPreprocess / objc_exception_throw
  <- _userInfoForFileAndLine
```

没有第三方 tweak 帧，只有 roothide 基础库。与 `.20` 上看到的 ShareKit/IconServices fault 属于同一类“分享面板/XPC”问题；检查第三方 App 的 Share Extension、分享扩展图标/Info.plist。

文件：`sharingd-2026-11-02-071034.ips`

---

## P2：WFWidgetExtension —— iOS 18 编译，跑在 iOS 17

时间：`2026-11-02 07:44:46`、`07:44:49`

```
termination: DYLD / Symbol missing
Symbol not found: _$s7SwiftUI21_ControlWidgetAdaptorVMn
Referenced from: WeiFeng.app/PlugIns/WFWidgetExtension.appex/WFWidgetExtension
  (built for iOS 18.0 which is newer than running OS)
Expected in: SwiftUI.framework
```

结论：WeiFeng（`com.feng.New.WPForumClient`）的 widget 是 iOS 18 编译，iOS 17 不兼容。更新 App 或移除该 widget。

---

## P2：WeiFeng watchdog

时间：`2026-11-02 07:45:06`

```
termination: code 2343432205, namespace <0xA>
[app<com.feng.New.WPForumClient>:990] failed to terminate gracefully after 5.0s
WatchdogEvent: process-exit, Foreground
Elapsed total CPU: 8.820s (user 5.930, system 2.890), 27% CPU
```

前台退出超时，主线程卡住/未及时退出。结合上面的 widget 崩溃，先更新 WeiFeng。

文件：`WeiFeng-2026-11-02-074506.ips`

---

## P3：SpringBoard.diskwrites_resource

时间：`2026-11-02 16:26:21`，440 KB。

SpringBoard 的磁盘写入资源报告。若持续增长，检查 tweak 日志/缓存写入；单次报告不足以定因。

文件：`SpringBoard.diskwrites_resource-2026-11-02-162621.ips`

---

## P3：EXC_GUARD（308）14 次

分布：Spotlight 7、Sileo 4、MessagesViewService 2、RootHide 1。

这些是 `EXC_GUARD` / `LIBXPC` 用户态 fault，多数是系统 guard/服务异常，通常不是 App 崩溃根因；除非数量持续快速增长，否则可以先忽略。

---

## 建议处理顺序

1. **P0 先处理三个直接 tweak 崩溃**
   - 移除/更新 `CallAssist`（微信）
   - 移除/更新 `ZZNFXProbe` / `ZZNFXSettingsRow`（Twitter）
   - 移除/更新 `BHTikTok`（TikTok）
2. **闲鱼堆损坏**
   - 先禁用 `jbb` 复现；仍复现再禁用 `XianyuDuo`；
   - 同时观察内存/Jetsam（闲鱼 611MB MALLOC + 160MB WebKit）。
3. **WeiFeng**
   - 更新 App（iOS 18 widget 在 iOS 17 不兼容），观察 watchdog 是否消失。
4. **sharingd / 分享扩展**
   - 检查第三方 Share Extension；与 `.20` 的 ShareKit/IconServices fault 对照。
5. **清理旧日志**
   - 处理完 P0 后清空 CrashReporter，观察 24 小时新增，确认修复效果。

---

## 备注

- 65 个日志中真正需要先修的是：**3 个直接 tweak 崩溃（CallAssist / ZZNFXProbe / BHTikTok）+ 闲鱼堆损坏**。
- 这次是直接读取 `.28` 的 `/rootfs/private/var/mobile/...` 路径；普通 shell 的 `/var/mobile/Library/Logs` 在该 rootless/roothide 环境下是另一个命名空间，找不到日志。
- `.20` 这次 SSH 超时（设备可能休眠），所以没有在 `.28` 日志上跑 DeepSeek API；上面的结论来自原始 IPS 栈和镜像列表。需要的话等 `.20` 上线后，可以把这些日志导入 App 用 DeepSeek 再跑一遍。
