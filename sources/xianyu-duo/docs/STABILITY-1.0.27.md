# 1.0.27 稳定性排查

用户反馈：点通知进入闲鱼直接闪退；偶发界面冻结。

## 根因

### 1) 通知冷启动闪退（最可能）

`XYDConstructor`（`__attribute__((constructor))`）里同步执行 `XYDInstallAll()`，
其中 `XYDInstallEntry()` 会调用：

```
XYDHookAllSubclassesOf([UIView class], ...)
```

这会在**启动最早期枚举全部 2 万个类**并做继承链判断。通知冷启动给 App 的时间非常短，
主线程一旦被拖住就会被 watchdog 杀掉，表现为“点通知直接闪退”，
而且这种杀法往往没有 crash log（还可能触发闲鱼自己的 TBSafeMode）。

**修复**：

- `XYDInstallEntry` 只对 4 个已知类名逐个 hook，不再枚举 UIView 子类。
- 信息流/我的页净化 hook 从 0.6s 主线程改为 **2s 后后台队列**安装，重试也不会再阻塞主线程。
- 启动安装全部加 `@try/@catch`，构造器也包了一层，单点异常不再拖垮启动。

### 2) 偶发冻结

三个来源：

- `debug=true` 时安装了 `SIGSEGV/SIGBUS/...` 信号处理器，处理器里调用
  `backtrace()` / Objective-C 文件写入。信号上下文里这些都不是 async-signal-safe，
  很容易二次死锁 —— 看起来就是界面冻结、还没日志。
- 热启动广告的状态机被我们从中间掐断：
  拦掉 `requestHotStartDecide:` 和 `handleHotStartDecideResult:backgroundMinutes:`，
  App 可能在等一个永远不会来的回调。
- 信息流 cell 的 `layoutSubviews` 在滚动时扫描视图树。

**修复**：

- 只保留 `NSUncaughtExceptionHandler`，移除所有信号处理器。
- 开屏/热启动生命周期**全部放行**，只异步隐藏 `FishSplashAdWindow`，
  热启动广告通过 `disableHotStartAd` 返回 YES 关闭。
- `layoutSubviews` 扫描加 `@try`，并且每个 cell 只扫描一次（已有缓存）。
- 网络响应里的视频扫描只对 JSON + item/video/detail 请求做。
- 播放器 hook 不再在构造器里安装，改为 App 激活/详情页出现时安装。
- 视频缓存扫描上限 6000 → 2000 个文件、最多 12 条。
- 去掉重复的 `+[AVPlayerItem playerItemWithURL:]` hook。
- 路由、网络、cell hook 全部加 `@try` 兜底。

## 包

```
com.pandan.xianyuduo_1.0.27_iphoneos-arm64e.deb
SHA-256: 48c9c4218027213c809d6b6ecd537dae96a5b5fe3e500adec01789f8cd2469f4
```

安装后强杀闲鱼再打开；如果之前进过 TBSafeMode，重启 App 一次即可退出。
若还有冻结，先在设置里关掉“信息流净化/我的页净化”再观察，可进一步缩小范围。
