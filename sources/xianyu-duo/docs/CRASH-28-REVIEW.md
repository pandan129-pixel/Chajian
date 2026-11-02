# 28 闲鱼崩溃报告 —— XianyuDuo 侧审计（1.0.28）

## 1. 报告结论怎么读

崩溃：`Runner 7.28.80 / 2026-11-02 23:24:55`
`EXC_CRASH (SIGABRT)` → `nanov2_guard_corruption_detected` →
`nanov2_allocate_outlined` → `CFNumberCreate` → `valueForKey:` → `NSKeyedArchiver`

这是 **nanov2 guard page / 堆元数据损坏**：崩溃点只是分配时检测到损坏，
真正写坏发生在更早，不能在 `NSKeyedArchiver`/`CFNumberCreate` 这一帧找根因。

崩溃时：

- 故障线程 22：`com.taobao.network.rwpolicy.queue`，闲鱼自己的网络策略归档；
- 线程 21：`jbb.dylib h_task_info` 在栈上（上面还叠了 `plcrash_signal_handler`）；
- `XianyuDuo.dylib` 只出现在镜像列表，**没有任何线程帧**。

## 2. XianyuDuo 是否有堆写坏风险

逐项审计了 1.0.27 的代码：

| 项 | 结论 |
| --- | --- |
| 原始内存写入 | 没有对 App 对象做 `object_setIvar` / 直接改 `NSDictionary` / `NSArray` |
| 图片/视频 buffer | 只读 `NSData`，`memcmp` 前都有长度判断 |
| 日志 buffer | 1.0.28 重写时加了 `plen` 截断和 16KB 缓冲边界检查 |
| hook ABI | 已按二进制 type encoding 核对：`FMURLRouter` 返回 BOOL；播放器方法 void；`AVURLAsset`/`AVPlayerItem` 签名一致；`loadWithVideoId:from:priority:` 第三个参数已从 `long long` 修正为 `id`（三个参数都是对象） |
| 危险 KVC | 删除了未使用的 `detailContext` ivar + `valueForKey:` 路径，避免读到非对象指针 |
| 异常 | 路由/网络/cell hook 均加 `@try`；启动安装按模块隔离 |

因此：**没有发现 XianyuDuo 直接写坏堆的证据**。它最多通过内存压力/IO/唤醒
放大问题，而不是 nanov2 的写坏源。

## 3. 关于 jbb `h_task_info`

对照工作区 `jbb/src/jbb_v617.c`：

```c
memcpy(&gFakeInfos, real, sizeof(gFakeInfos));
for (i = 0; i < real->infoArrayCount && w < JB_MAX_IMAGES; i++) { ... }
gFakeInfos.infoArray = gFakeImgArray;
gFakeInfos.infoArrayCount = w;
di->all_image_info_addr = &gFakeInfos;
```

报告里的“固定 0x170 memcpy”就是 `sizeof(struct dyld_all_image_infos)` 的整结构拷贝。
它写的是 **全局静态区**（`gFakeInfos`/`gFakeImgArray`），不是 malloc 堆；
从代码看更像“越界读 / ABI 不一致导致调用方行为异常”，而不是直接写坏 nanov2 堆。

但这仍然是崩溃时唯一在栈上的第三方 tweak，**必须按报告先禁用 jbb 做 A/B**。
XianyuDuo 无法在运行时修复 jbb 的 `task_info` hook。

## 4. 报告里真正属于我们插件的问题

### 4.1 磁盘写 / 唤醒

1.0.27 的 `XYDLog` 每写一行都：

```
NSDateFormatter 新建 → open → seek → write → close
```

`debug=true` 时这是非常差的路径，既产生大量 open/close 唤醒，也会放大磁盘写。
**1.0.28 已重写**：

- 常驻 `FILE*`，16KB 用户态缓冲；
- 最多 0.5 秒或 8KB 落盘一次；
- 200 行/秒限速；
- 文件 4MB 上限循环覆盖；
- 去掉每行 `NSDateFormatter`，改用 `localtime_r`。

### 4.2 内存 / Jetsam

`XYDStore` 原来最多保留 120 项 / 180MB 原图 `NSData`，且同一张图不同解码质量
可能重复存。**1.0.28 已改**：

- 上限 60 项 / 64MB；
- 按像素尺寸去重（±2px），避免同图多份；
- 离开详情页 `endPage` 立即释放本次捕获数据；
- 面板缩略图缓存 120 → 40。

### 4.3 无效扫描 / 唤醒

- 信息流/我的页 hook 从启动 0.6 秒主线程 → 2 秒后后台队列；
- 我的页广告扫描 1.5 秒/700 节点 → 3 秒/400 节点；
- 视频缓存扫描 6000 → 1200 个文件；
- 网络响应只在 JSON + item/video/detail URL 时扫描视频地址；
- 播放器 hook 不再在构造器安装；去掉重复的 `AVPlayerItem` hook。

### 4.4 兼容模式

设置页新增 **“兼容模式（少 Hook）”**：

- 只保留存图/视频捕获、悬浮球、面板；
- 跳过开屏窗口 hook、信息流净化、我的页入口/净化；
- 改完需要重启闲鱼。

用于在不卸载插件的情况下做 A/B。

## 5. 包

```
com.pandan.xianyuduo_1.0.28_iphoneos-arm64e.deb
SHA-256: ca068b6294a9c469a734c29feed4ec585f0e2fbd655e51a949effc764309c0a6
```

桌面副本：`~/Desktop/com.pandan.xianyuduo_1.0.28_iphoneos-arm64e.deb`

## 6. 建议复现顺序

1. **先禁用 jbb**（按报告命令），正常用 2~4 小时；
2. 若 `nanov2_guard_corruption_detected` 不再出现 → 主线转 jbb；
3. 若仍出现 → 保留 jbb，装 XianyuDuo 1.0.28，打开“兼容模式”，再复现；
4. 同时对比：
   - `Runner.diskwrites_resource`（应明显低于 767KB/s）；
   - `Runner.wakeups_resource`（看是否仍 356/s）；
   - Jetsam 的 `Runner rpages/lifetimeMax`（我们的常驻内存已压到 ~64MB 上限）。

如果 4 里磁盘写/唤醒明显下降，说明我们这侧的资源问题已收敛；
剩下的 nanov2 损坏按报告继续排查 jbb/闲鱼自身/其他 tweak。
