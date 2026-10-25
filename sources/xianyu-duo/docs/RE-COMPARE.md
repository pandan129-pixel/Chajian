# 闲鱼助手 3.2.2 × 存图助手 — 逆向对比与融合记录

日期：2026-10-25
目标包：`im.mjh.xianyuadblock 3.2.2`（roothide，`debs/im.mjh.xianyuadblock-3.2.2-roothide.deb`）
参考包：`com.pandan.xianyuplus`（存图助手，设备备份里的 `XianYuPlus.dylib`）
产物：`com.pandan.xianyuduo 1.0.6`（单 dylib，源码在本目录）
- dylib SHA-256：`2c2bd2f6a8ed148a8642881520d70ba91a00c9283fbab8658284f839fb01bc02`（构建随版本变化，以 dist/SHA256SUMS 为准）
- deb   SHA-256：`720613978afe016ec42314781bda3688a81b0e8d08f07642ac163d5333a592fd`

---

## 1. 样本与基础信息

| 项 | 闲鱼助手 3.2.2 | 存图助手/ XianYuPlus |
|---|---|---|
| deb SHA-256 | `29661a74d0410f45e345a5d3679e0a4808e229ad7d25550710b5c09bb13f733d` | — |
| dylib SHA-256 | `538ce3edd1001f99a57f753859bcd2357e35bfe2a4a3ad7d3a60f33107dfa324` | `544c20ea2beae272f4a98ddc1539d77cf0a482c6a2a7eccd5d6f26f01ec343` |
| 架构 | arm64（3.2.2 roothide 包内） | arm64 + arm64e（fat） |
| 大小 | 573 KB | 379 KB（arm64e 切片约 200 KB） |
| ObjC 类 | 28 | 8 |
| 命名 C 函数 | 79（未 strip，符号可读） | 5 |
| Hook 方式 | `method_setImplementation`/`class_addMethod` + `MSHookFunction`（C++/Swift 符号） | `MSHookMessageEx` ×5 + `method_setImplementation` |
| 依赖 | Foundation/UIKit/SQLite/zlib | Foundation/UIKit/Photos/AVFoundation/ImageIO |

3.2.2 保留了完整的函数符号（如 `_XYHInstallAdBlock` 一族、`_XYHInstallIMBridge`、`_XYHInstallDeliveryProgress`），
因此可以直接按函数边界做定点反编译，而不必全量盲扫。

---

## 2. 闲鱼助手 3.2.2 的 Hook 面

### 2.1 启动/开屏广告

安装函数 `0x77bc`（`_XYHInstallAdBlock` 路径）在运行时解密类名/选择器后安装：

| 类 | 选择器 | 作用 |
|---|---|---|
| `FMSplashModule` | `loadAd` / `showSplashView` / `fishSplashAdDidShow` / `fishSplashAdDidFinish` | 不加载、不展示开屏 |
| `FMHomeRefreshHelper` | `handleAppWillEnterForeground` / `requestHotStartDecide:` / `handleHotStartDecideResult:backgroundMinutes:` / `postHotStartRefreshHomeNotification` | 拦截热启动广告决策 |
| `_TtC6FishAd18FishSplashAdWindow` | 窗口隐藏（运行时字符串 + 视图扫描） | 兜底不显示广告 window |
| `_TtC6FishAd18FishSplashAdConfig` | `disableHotStartAd` / `setDisableHotStartAd:` / `updateConfig` | 关闭热启动广告配置 |
| `FMAboutViewController` | `viewDidLoad` | 注入入口/关于页按钮 |

### 2.2 信息流广告

- 信息流 cell：3.2.2 并不是按精确类名 hook，而是对 `NSStringFromClass(cell)` 做
  `containsString:@"WaterfallItemCell"` / `containsString:@"SingleRowItemCell"` 判断
  （反编译 0x6990 处可见），所以 Swift 混淆后的 `_TtC12XSearchSwift17WaterfallItemCell` 也能命中。
- `UICollectionView`：`reloadData`、`performBatchUpdates:completion:`、`insert/delete/reload/move` items/sections，
  用于在数据源层过滤广告 cell。
- 广告判定：`0xa31c` 是 `ClassHasAnySelector(className, selectors[])`，
  通过 `NSClassFromString` + `class_getInstanceMethod` 判断广告 SDK 视图类；
  `0x964c`/`0x97a0` 用 associated object 给 cell 挂/摘屏蔽用的覆盖视图。

### 2.3 我的页

- `_XYHInstallEntrances` (0x527d0)：hook `IFMatrix.FloatingUserInfoContentView` / `IFMatrix.TopUserInfoContentView`
  的 `didMoveToWindow` / `layoutSubviews`，注入入口按钮。
- `_XYHInstallMyPageFilter` (0x553f8)：hook `IFMatrix.SPNNewContainer` / `IFMatrix.SPNCollectionView` /
  `IFMatrix.DXComponentView` 的 `recycle-reload` / `recycle-cell` / `recycle-layout` / `recycle-size`，过滤营销行。
- 规则来源是偏好键（`im.mjh.xianyuadblock` 域），不在明文字符串里，因此无法静态恢复成“行名单”。

### 2.4 自动化（本次不融合）

`_XYHInstallIMBridge`（C++ AIM 符号：`AIMConvert::ConvertConversationToGluePtr`、`GetMsgService`、`kSendMessage` 等）、
`_XYHInstallDeliveryProgress`、`_XYHInstallTipContextCapture`（Flutter `handleOpenURL:query:nativeParams:`、`MtopPlugin handleMethodCall:result:`）、
`XYHDelivery*` / `XYHRecordStore`（SQLite）/ `XYHAutomation`（定时器）属于自动发货、评分、自动回复、邀请奖励。
按你选择的范围，本次不重写；它们也是 3.2.2 里 CPU/内存/IO 占用的主要来源。

---

## 3. 存图助手的 Hook 面

构造函数只有 5 处 `MSHookMessageEx`：

| 类 | 选择器 | 作用 |
|---|---|---|
| `XDetailViewController` | `viewDidAppear:` | 读 `detailContext.routerURL` → 解析 `itemId`，记录页面打开时间，装悬浮球 |
| `XDetailViewController` | `viewWillDisappear:` | 标记离开详情页 |
| `FM3FlutterViewContainer` | `viewDidAppear:` | Flutter 容器进入时确保悬浮球存在 |
| `UIImage`（元类） | `imageWithData:` / `imageWithData:scale:` | 截获 App 已解码的原始图片字节 |

细节：

- **itemId 提取**（原版）：`object_getIvar(vc, ivar "detailContext")` → `object_getIvar(ctx, ivar "routerURL")`，
  再用 `NSURLComponents` 拆 query，取 `id=`；不是 KVC，直接读 ivar（兼容 Swift/ObjC 混排）。
  在 7.28.70 上 `XDetailContext.routerURL` 的 ivar size 为 0（Swift 计算属性，无直接存储），
  因此融合版改为：`detailContext` → 依次尝试 `routerURL` / `routerQuery` / `routerCombinedParams` / `detailData`，
  并额外 hook `XDetailViewController initWithURL:query:nativeParams:` 与
  `FM3FlutterViewContainer initWithURL:query:nativeParams:`，从入参 URL/query 直接取 `id`，作为首屏兜底。
- **图片采集**：`XYPMinKB`（默认 15 KB，`value*1024`）、格式魔数白名单、`length + 前 4 字节` 去重；
  详情页前后 20 秒窗口内的解码才计入。
- **网络采集**：`XYPCollectNet` 开关；只记录 CDN URL（alicdn/taobaocdn/tbcdn），不复制响应体。
- **MTOP 兜底**：`mtop.taobao.idle.item.info` + `h5api.m.goofish.com`，H5 签名
  `md5(token & t & appKey & data)`，appKey `12574478`，token 来自 `_m_h5_tk` Cookie；
  解析 `itemDO.item.imageInfos` 与 `itemDO.imageInfoDOList`。
- **保存**：`PHAssetCreationRequest addResourceWithType:`；实况用
  `com.apple.quicktime.content.identifier` + `com.apple.quicktime.still-image-time` 元数据配对。
- **UI**：`XYPBall`（可拖拽）+ `XYPPanelVC`（媒体网格/设置页）+ `XYPMediaCell`。

---

## 4. 交叉对比

### 4.1 重叠点

| 能力 | 3.2.2 | 存图 | 融合处理 |
|---|---|---|---|
| 详情页上下文 | 自己的 `XYHReadAPI`/MTOP 封装 | 读 `detailContext` ivar | 采用存图方案（无网络、无签名） |
| 网络层 | 自带 MTOP 请求封装（`XYHAutomation send:params:done:`） | H5 MD5 签名直连 | 独立实现，仅在打开面板且无缓存时请求 |
| 广告图过滤 | 广告 view 类识别 | URL 路径含 `BeiZiMaterial`/`GDT`/`splash` 直接丢弃 | 两者都保留：解码侧按体积/像素，URL 侧按路径 |
| 悬浮 UI | `XYHDeliveryStrip`（发货条） | `XYPBall` | 用存图的轻量球，去掉发货条 |
| UICollectionView hook | reload/批量更新（数据源过滤） | 无 | 本次不复制数据源过滤，改为 cell 内广告视图识别，避免与 App diff 冲突 |
| 我的页 | `FloatingUserInfoContentView` 注入 | 无 | 保留，并在同一视图上挂“存图设置”入口 |

### 4.2 结论

1. 两者**没有需要争抢的同一个方法**（3.2.2 在 `WaterfallItemCell`/`UICollectionView`，存图在 `UIImage`/`XDetailViewController`），
   所以“融合”不是把两个 dylib 塞进一个 deb，而是共享上下文与 UI、去掉重复的图片解码钩子。
2. 3.2.2 真正贵的是自动化（SQLite + 定时器 + 后台任务），不是去广告本身；
   轻量融合后可以做到**零常驻定时器、零 SQLite、无后台线程轮询**。
3. 存图的图片采集只挂在 `UIImage` 类方法上，触发频率与 App 自身解码次数相同，额外成本是一次长度/魔数判断。

---

## 5. 本产物的实现选择

| 模块 | 实现 |
|---|---|
| 开屏/热启动 | 按 3.2.2 反编译结果直接 hook `FMSplashModule` / `FMHomeRefreshHelper` / `FishSplashAdWindow`，并加 `UIWindow setHidden:` 兜底 |
| 信息流广告 | 运行时枚举所有 `UICollectionViewCell` 子类，按类名子串（WaterfallItemCell / SingleRowItemCell / HomeCardCell / SearchResultCardCell …）批量 hook `layoutSubviews`/`prepareForReuse`；首次布局做深度受限的广告标记扫描，命中后隐藏并缓存 |
| 我的页净化 | `FloatingUserInfoContentView layoutSubviews` 触发，3 秒节流、700 节点上限、主线程一次扫描 |
| 我的页入口 | `FloatingUserInfoContentView didMoveToWindow` 注入“存图设置”胶囊按钮 |
| 详情页入口 | 可拖拽悬浮球；点击开面板，长按开设置；位置持久化并吸边 |
| 图片采集 | `+[UIImage imageWithData:]` / `imageWithData:scale:`；体积/像素/格式过滤 + 去重 + 180 MB 上限 |
| 视频 | 记录详情页期间 `NSURLSession` 的 mp4/mov 请求 URL；面板内下载保存 |
| 原图列表 | MTOP H5 直连（MD5 签名），5 分钟缓存；失败则退回捕获结果 |
| 保存 | Photos `PHAssetCreationRequest`；WebP 自动转 JPEG；逐项进度/失败统计 |
| 设置 | 面板内设置页 + 我的页入口，CFPreferences 持久化 |

### 性能预算

- 启动：单 dylib，仅链接 Foundation/UIKit/Photos/ImageIO/CoreGraphics；构造函数只注册 hook，不建窗口、不建队列、不发请求。
- 空闲：无常驻定时器、无轮询、无后台队列空转。
- 图片路径：一次 `data.length` 比较 + 一次 16 字节读取；仅详情页窗口内才继续 ImageIO 取尺寸。
- 广告路径：`WaterfallItemCell` 首次布局扫描（≤120 节点），之后走 associated object 缓存；我的页扫描 3 秒节流。
- 内存：媒体条目上限 120 条 / 180 MB，超限按最旧淘汰；缩略图 `NSCache` 上限 120。

---

## 6. 已知限制

1. 3.2.2 的“我的页行过滤”规则是偏好驱动的黑名单，无法从二进制恢复；本作采用类名/“广告/赞助”文案的保守识别，可能漏掉原生营销位。
2. 3.2.2 的完整自动化（自动发货、评分、IM 自动回复、邀请）**未包含**。
3. 实况照片的配对保存代码保留在 `XYDSaver.m`，但当前 UI 未暴露；闲鱼实况资源依赖具体接口字段，需真机确认后再开。
4. MTOP 接口依赖登录 Cookie；未登录/票据过期时只显示已捕获的图片。
5. 所有 hook 都做了类/方法存在性检查，App 版本升级后失败的 hook 会在调试日志里留痕，不会崩溃。


---

## 7. 真机类名校验（闲鱼 7.28.70 / iOS 16.3.1）

从设备 `Runner.app/Runner` 的 ObjC 元数据中确认（`com.taobao.fleamarket`，CFBundleShortVersionString `7.28.70`）：

| 目标 | 结果 |
|---|---|
| `FMSplashModule` | 存在，含 `loadAd` / `showSplashView` / `fishSplashAdDidShow` / `fishSplashAdDidFinish` / `isADShowing` |
| `FMHomeRefreshHelper` | 存在，含 `handleAppWillEnterForeground` / `requestHotStartDecide:` / `handleHotStartDecideResult:backgroundMinutes:` / `postHotStartRefreshHomeNotification` |
| `_TtC6FishAd18FishSplashAdWindow` | 存在（`initWithFrame:` / `initWithCoder:` / `addSubview:` / `initWithWindowScene:`） |
| `_TtC6FishAd18FishSplashAdConfig` | 存在，含 `disableHotStartAd` / `setDisableHotStartAd:` |
| `XDetailViewController` | 存在，含 `viewDidAppear:` / `viewWillDisappear:` / ivar `detailContext` |
| `_TtC7XDetail14XDetailContext` | 存在，含 ivar `routerURL` |
| `FM3FlutterViewContainer` | 存在（`FBFlutterViewContainer` 子类） |
| 信息流 cell | `_TtC12XSearchSwift17WaterfallItemCell`、`_TtC12XSearchSwift17SingleRowItemCell` |
| 我的页 | `_TtC8IFMatrix27FloatingUserInfoContentView`、`_TtC8IFMatrix36WorkspaceFloatingUserInfoContentView`、`_TtC8IFMatrix20FloatingUserInfoView` |

因此最终实现做了两处适配：

1. 信息流/我的页不再使用 `NSClassFromString(@"WaterfallItemCell")`，改为
   `objc_getClassList` + 类名子串匹配 + 逐类 `class_addMethod` 覆盖（保留每个类各自的原始 IMP）。
2. `FishSplashAdWindow` 没有实现 `layoutSubviews`，额外 hook `addSubview:`，并保留 `UIWindow setHidden:` 兜底。

> 说明：`.20` 设备在本次交付时处于锁屏状态，`uiopen` 无法启动闲鱼，运行时 hook 命中/日志未能现场验证；
> 安装测试后已完整回滚到旧 combo（文件与 dpkg status 均恢复）。`.28` 在线后按 `scripts/install.sh` 安装即可，
> 打开调试开关后看 `tmp/xianyuduo.log` 里的 `hook -[...] ok` 行。
