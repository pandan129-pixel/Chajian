# 闲鱼（Runner / com.taobao.fleamarket）专项崩溃报告

- 设备：iPhone16,1 / iOS 17.0 (21A327) / Relaxin + roothide
- App：闲鱼 **7.28.80**（build 59435214，`com.taobao.fleamarket`）
- 数据来源：`.28` 的 `/rootfs/private/var/mobile/Library/Logs/CrashReporter`
- 专项日志副本：`plugins/crash-analyzer-pro/logs/28-xianyu/`
- 完整 65 份日志：`plugins/crash-analyzer-pro/logs/28-CrashReporter/`
- 采集时间：2026-11-02 02:36 ~ 11-03 03:27

本报告只保留与闲鱼相关的：

| 文件 | 类型 | 时间 |
| --- | --- | --- |
| `Runner-2026-11-02-232455.ips` | crash (SIGABRT) | 11-02 23:24:55 |
| `JetsamEvent-2026-11-02-081422.ips` | Jetsam | 11-02 08:14:22 |
| `JetsamEvent-2026-11-02-173752.ips` | Jetsam | 11-02 17:37:52 |
| `JetsamEvent-2026-11-03-002116.ips` | Jetsam | 11-03 00:21:16 |
| `JetsamEvent-2026-11-03-012343.ips` | Jetsam | 11-03 01:23:43 |
| `Runner.wakeups_resource-2026-11-02-143020.ips` | wakeups | 11-02 14:30:20 |
| `Runner.diskwrites_resource-2026-11-02-143305.ips` | disk writes | 11-02 14:33:05 |

另外 3 个 Jetsam 是微信/支付宝最大，不是闲鱼，放在 `logs/28-xianyu/` 里仅作上下文。

---

## 1. 崩溃：Runner 2026-11-02 23:24:55

### 1.1 基本信息

```
bug_type: 309
app: Runner 7.28.80
bundle: com.taobao.fleamarket
os: iPhone OS 17.0 (21A327)
exception: EXC_CRASH (SIGABRT)
termination: SIGNAL 6 / Abort trap: 6 / byProc Runner
asi: libsystem_c.dylib: abort() called
faultingThread: 22
threads: 64
images: 53
```

### 1.2 故障线程完整栈（关键段）

线程：`com.taobao.network.rwpolicy.queue`

```
0  libsystem_kernel.dylib  __pthread_kill
1  libsystem_pthread.dylib pthread_kill
2  libsystem_c.dylib        abort
3  libsystem_malloc.dylib   malloc_vreport
4  libsystem_malloc.dylib   malloc_zone_error
5  libsystem_malloc.dylib   nanov2_guard_corruption_detected
6  libsystem_malloc.dylib   nanov2_allocate_outlined
7  CoreFoundation           _CFRuntimeCreateInstance
8  CoreFoundation           CFNumberCreate
9  Foundation               -[NSPlaceholderNumber initWithDouble:]
10 Foundation               _NSGetDoubleValueInIvar
11 Foundation               -[NSObject(NSKeyValueCoding) valueForKey:]
12 Runner                   (无符号)
13 Foundation               _encodeObject
14 Foundation               -[NSKeyedArchiver _encodeArrayOfObjects:forKey:]
15 Foundation               -[NSDictionary(NSDictionary) encodeWithCoder:]
16 Foundation               _encodeObject
17 Runner                   (无符号)
18 Foundation               _encodeObject
19 Foundation               +[NSKeyedArchiver archivedDataWithRootObject:requiringSecureCoding:error:]
20 Runner                   (无符号)
21 Runner                   (无符号)
22 Runner                   (无符号)
23 libdispatch              _dispatch_call_block_and_release
24 libdispatch              _dispatch_client_callout
25 libdispatch              _dispatch_lane_serial_drain
26 libdispatch              _dispatch_lane_invoke
27 libdispatch              _dispatch_root_queue_drain_deferred_wlh
28 libdispatch              _dispatch_workloop_worker_thread
29 libsystem_pthread.dylib  _pthread_wqthread
30 libsystem_pthread.dylib  start_wqthread
```

**结论：这是 nanov2 guard page / 堆元数据损坏，不是直接空指针。**
崩溃点在 `NSKeyedArchiver` 编码一个字典时；`CFNumberCreate` 分配时检测到堆损坏，说明损坏发生在**更早的某次写入**，这里只是“踩到地雷”。

### 1.3 崩溃时加载的 tweak

| imageIndex | 名称 | UUID | 大小 | 路径 |
| --- | --- | --- | --- | --- |
| 1 | `libellekit.dylib` | `7339385d-36e0-38ac-ba42-a735f5072657` | 147456 | `/usr/lib/libellekit.dylib` |
| 2 | `jbb.dylib` | `a794041d-eb85-39ce-b504-200af873d021` | 49152 | `/usr/lib/TweakInject/jbb.dylib` |
| 4 | `XianyuDuo.dylib` | `d2a47ef6-54ca-3d21-8400-ca47660bf64e` | 180224 | `/usr/lib/TweakInject/XianyuDuo.dylib` |
| 5 | `roothidepatch.dylib` | `499a528b-8c4f-33e7-98e7-e095619a3000` | 32768 | `/usr/lib/roothidepatch.dylib` |
| 6 | `libroothide.dylib` | `195a8791-b22d-38ad-b959-a54ab4adeaed` | 32768 | `/usr/lib/libroothide.dylib` |
| 7 | `roothideinit.dylib` | `978ca172-8062-3c6b-8d1b-d77540e088ce` | 32768 | `/usr/lib/roothideinit.dylib` |

### 1.4 唯一命中 tweak 的线程帧

```
thread 21  queue=com.apple.root.default-qos  frames=59
  frame 12: jbb.dylib  h_task_info  imageOffset=30508 (0x772c)
```

`XianyuDuo.dylib` 没有出现在任何线程的帧里；`jbb.dylib` 是崩溃时唯一在栈上的第三方 tweak。

---

## 2. 重点线索：jbb 的 `h_task_info`

### 2.1 与本地构建完全对应

`.28` 上加载的 `jbb.dylib` UUID：

```
a794041d-eb85-39ce-b504-200af873d021
```

工作区 `jbb/build/jbb.dylib` 的 UUID **完全一致**：

```
A794041D-EB85-39CE-B504-200AF873D021
```

符号：

```
0000000000007548 t _h_task_info
```

崩溃帧 `imageOffset=0x772c` 落在 `_h_task_info` 内部（0x7548 ~ 0x7780）。

### 2.2 `h_task_info` 做了什么

反汇编关键段（0x7548 起）：

```
7548  pacibsp
...
75bc  cmp w8, #0                 ; JBB_NO_HIDE / 开关
75c0  ccmp x21, #0, #4, eq       ; task_info_count != NULL
75c4  ccmp x19, #0, #4, ne       ; task_info_t != NULL
75c8  ccmp w22, #0x11, #0, ne    ; flavor == TASK_DYLD_INFO (17)
75cc  ccmp w0, #0, #0, eq        ; 原始 task_info 返回 0
75d0  b.eq 75f4
...
75f4  ldr w8, [x21]              ; *task_info_count
75fc  ldr x9, [global]           ; 预期 image count
7604  cmp w8, #5
7608  ccmp w20, w9, #0, hs       ; 额外校验
760c  b.ne 75d4                  ; 不满足就原样返回
7610  ldr x20, [x19]             ; task_info_t 里的 info 指针
7618  ldr x8, [x20, #8]          ; image array 指针
7620  ldr w8, [x20, #4]          ; image count
...
762c  lock gInfosLock
7638  mov x1, x20
7644  mov w2, #0x170
7648  bl _memcpy                 ; memcpy(gFakeInfos, x20, 0x170)
764c  ldr w9, [x20, #4]          ; count
...
7684  ldr x8, [x20, #8]          ; images
768c  add x23, x8, x25*24        ; 每个 image info 24 字节
7690  ldr x22, [x23, #8]         ; name
...
76c0  ldr q0, [x23]
76c4  ldr x9, [x23, #0x10]
76c8  str x9, [x8, #0x10]
76cc  str q0, [x8]               ; 复制 24 字节到 gFakeImgArray
...
7734  add x25, x25, #1
7738  cmp x25, x9
7740  cmp x26, #0x800            ; 最多 2048 个
7744  b.lo 7680
...
7750  str x9, [gFakeInfos+8]     ; fake images 指针
7764  str w26, [gFakeInfos+4]    ; fake count
7768  str x8, [x19]              ; *task_info = gFakeInfos
7774  unlock
```

它是在 hook `task_info(TASK_DYLD_INFO)`：

1. 把调用方 `task_info` 输出结构体固定 **memcpy 0x170 字节**到全局 `gFakeInfos`；
2. 读取 `[info+4]` 的 image count，遍历 `[info+8]` 的 image 数组，每个 24 字节；
3. 过滤掉要隐藏的 image 名，把剩余条目复制到全局 `gFakeImgArray`，最多 **0x800 (2048)** 个；
4. 把 `*task_info` 指向 `gFakeInfos`，返回。

### 2.3 为什么可疑

- **固定 0x170 memcpy**：没有按调用方实际 buffer size 校验。`task_info` 的 `task_info_t` 在不同 flavor/版本下大小可能不同；如果调用方传入的 buffer 小于 0x170，这里会读越界（读通常不直接造成堆写坏，但会放大异常）。
- **信任 `[info+4]` 的 count**：如果调用方的 image count 与实际数组不匹配，遍历会读越界。
- **把 `*task_info` 换成全局 fake 结构**：调用方随后按真实 `task_info` 结构/大小使用 fake 数据时，可能发生 ABI/大小不一致；如果调用方把 fake 数据再写入自己的堆对象，就可能出现堆损坏。
- 崩溃是 **nanov2 写坏**，不是直接读崩；`h_task_info` 本身主要写全局静态区，但它是崩溃时唯一在栈上的 tweak，必须优先排除。

> 注意：这不是“已确认 jbb 就是根因”。它是目前最强的可操作线索，先禁用 jbb 复现是最快的验证方式。

---

## 3. Jetsam：闲鱼是最大内存进程

| 时间 | Runner rpages | 约 | Runner lifetimeMax | 系统杀掉的进程 / 原因 |
| --- | --- | --- | --- | --- |
| 11-02 08:14:22 | 65,283 | ~1.07 GB | 77,772 (~1.27 GB) | `iconservicesagent` / `per-process-limit` |
| 11-02 17:37:52 | 92,272 | ~1.51 GB | 114,863 (~1.88 GB) | `intents_helper` / `sustained-memory-pressure` |
| 11-03 00:21:16 | 79,741 | ~1.31 GB | 83,523 (~1.37 GB) | `nehelper` / `per-process-limit` |
| 11-03 01:23:43 | 86,440 | ~1.42 GB | 100,278 (~1.64 GB) | `QQMail` / `vm-compressor-thrashing`；`kbd` / `highwater` |

（page size = 16384）

关键点：

- 闲鱼不是被杀的进程，但它是 **largestProcess**，4 次都是第一。
- 系统已经进入 **compressor thrashing**（01:23：compressorSize 177,634 pages ≈ 2.9GB；active 88,789；wired 133,627），开始杀其他进程。
- 闲鱼的内存峰值 1.0~1.9GB，对 6GB 设备来说非常激进；Flutter + WebKit + 广告 SDK + 视频 SDK 都可能在吃内存。
- 崩溃日志的 `vmSummary` 也显示：`MALLOC 611.3MB`、`WebKit Malloc 160.1MB`、虚拟总 2.7GB。

内存压力本身不直接产生 nanov2 guard corruption，但会放大越界/释放后使用类 bug 的概率，也会让复现更不稳定。

---

## 4. 资源异常：wakeups / disk writes

### 4.1 Wakeups

`Runner.wakeups_resource-2026-11-02-143020.ips`

```
45,001 wakeups over 126 seconds
356 wakeups/s，limit 150/s over 300s
```

126 秒 4.5 万次唤醒，远超限制。栈主要集中在：

```
UIKitCore → GraphicsServices → CoreFoundation → QuartzCore
Runner + 103259308
Runner + 63906620
```

说明闲鱼在采样窗口里有高频 UI/动画/定时器/网络唤醒。与崩溃不是同一件事，但会加剧耗电和调度压力。

### 4.2 Disk writes

`Runner.diskwrites_resource-2026-11-02-143305.ips`

```
1,073.76 MB file-backed memory dirtied over 1,399 seconds
767.27 KB/s，limit 12.43 KB/s
```

23 分钟内写了 **1.07GB**，非常夸张。栈主要在：

```
Runner + 209376
Runner + 16032528
Runner + 47116336
Runner + 40930636 / 40931516 / 41337172 / 41334724 / 41457160
```

建议同时查闲鱼的日志/缓存/广告 SDK 写入；如果启用了我们的调试日志，也要确认不是日志在狂写。

---

## 5. 结论与优先级

### 结论

1. **崩溃是 nanov2 堆损坏**，不是普通空指针；崩溃点只是“检测到损坏”的位置，真正写坏发生在更早。
2. **jbb 的 `h_task_info` 是唯一在崩溃时出现在线程栈上的 tweak**，且它的 `TASK_DYLD_INFO` 伪造逻辑存在固定 0x170 memcpy、信任 count、替换 `task_info` 指针等风险点。**先禁用 jbb 验证。**
3. **XianyuDuo 也加载了**，但没有任何线程帧；第二优先级排除。
4. **闲鱼内存 1.0~1.9GB**，4 次 Jetsam 都是 largestProcess；内存压力是独立的严重问题，可能放大堆 bug。
5. wakeups 356/s、disk writes 767KB/s 是另外两个性能问题，不是本次崩溃的直接原因，但建议一起修。

### 建议顺序

**第 1 步：禁用 jbb，复现**

```sh
# .28，先备份
sudo mv /usr/lib/TweakInject/jbb.dylib /usr/lib/TweakInject/jbb.dylib.disabled
sudo mv /usr/lib/TweakInject/jbb.plist /usr/lib/TweakInject/jbb.plist.disabled
# respring / 重启用户态
killall -9 Runner 2>/dev/null
uiopen --bundleid com.taobao.fleamarket
```

然后正常使用闲鱼 2~4 小时，重点复现之前 23:24 的操作（网络/消息/收藏/分享/图片视频）。检查新日志：

```sh
grep -l "nanov2_guard_corruption_detected" /rootfs/private/var/mobile/Library/Logs/CrashReporter/Runner-*.ips
```

- 不再出现 → jbb 高度可疑，进入第 2 步审计 `h_task_info`。
- 仍出现 → 恢复 jbb，进入第 3 步禁用 XianyuDuo。

**第 2 步：如果 jbb 可疑，审计 `h_task_info`**

本地构建与设备 UUID 一致：

```
jbb/build/jbb.dylib  UUID A794041D-EB85-39CE-B504-200AF873D021
_h_task_info @ 0x7548
```

重点检查：

- `memcpy(gFakeInfos, caller_info, 0x170)` 是否应按实际 `task_info` 结构大小复制；
- `[info+4]` 的 image count 是否与 `[info+8]` 的数组长度一致；
- `gFakeImgArray` 的 0x800 上限是否足够，`x26` 越界保护是否正确；
- `*task_info = gFakeInfos` 后，调用方是否按真实结构大小读取；是否应该复制回调用方 buffer，而不是替换指针；
- 对 `TASK_DYLD_INFO` 的不同 iOS 版本/结构体大小做兼容。

**第 3 步：禁用 XianyuDuo，复现**

```sh
sudo mv /usr/lib/TweakInject/XianyuDuo.dylib /usr/lib/TweakInject/XianyuDuo.dylib.disabled
sudo mv /usr/lib/TweakInject/XianyuDuo.plist /usr/lib/TweakInject/XianyuDuo.plist.disabled
killall -9 Runner; uiopen --bundleid com.taobao.fleamarket
```

- 不再出现 → 审计 XianyuDuo 里对 NSDictionary/NSArray 的修改、retain/release、图片/视频 buffer、URLSession 回调。
- 仍出现 → 两个 tweak 都恢复，按“闲鱼自身 + 其他 tweak”继续排查。

**第 4 步：内存**

- 记录每次复现后的 `Runner` rpages / lifetimeMax（Jetsam 或 `vmSummary`）。
- 如果禁用 tweak 后内存仍 1.5GB+，属于闲鱼自身/广告 SDK/Flutter 的问题，考虑限制后台、清理缓存、升级闲鱼。
- 关注 01:23 那种 `vm-compressor-thrashing`，它会让系统杀别的 App（QQMail/kbd），用户体验是“后台全被杀”。

**第 5 步：性能**

- wakeups 356/s：查闲鱼的定时器/动画/网络轮询；如果是我们的 tweak 引入的轮询，优先去掉。
- disk writes 767KB/s：查日志/缓存写入；关闭调试日志后再测。

---

## 6. 复现记录模板

每次测试记录：

```
日期/时间：
jbb：启用 / 禁用
XianyuDuo：启用 / 禁用
操作路径：
是否崩溃：
新日志文件：
grep nanov2：
Runner rpages / lifetimeMax：
备注：
```

---

## 7. 附件

- 专项日志：`plugins/crash-analyzer-pro/logs/28-xianyu/`（含 SHA256SUMS）
- 完整日志：`plugins/crash-analyzer-pro/logs/28-CrashReporter/`
- 本报告：`plugins/crash-analyzer-pro/docs/28-XIANYU-REPORT.md`
- 全量分析：`plugins/crash-analyzer-pro/docs/28-LOG-ANALYSIS.md`

`.20` 当前 SSH 超时（设备可能休眠），所以本报告没有跑 DeepSeek API；结论全部来自原始 IPS 栈、Jetsam 数据和 jbb 二进制反汇编。需要 AI 版分析时，等 `.20` 上线或把 tweak 装到 `.28` 后再跑。
