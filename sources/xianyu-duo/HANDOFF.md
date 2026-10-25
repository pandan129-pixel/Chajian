# 交接：闲鱼助手 + 存图 融合版（com.pandan.xianyuduo 1.0.6）

日期：2026-10-25
目标设备：`.28` iPhone 15 Pro / iOS 17.0 / Relaxin（roothide，arm64e）
产物：`dist/com.pandan.xianyuduo_1.0.6_iphoneos-arm64e.deb`
（dylib：`build/XianyuDuo.dylib`，arm64 + arm64e）

## 1. 做了什么

1. 下载并拆解 `im.mjh.xianyuadblock 3.2.2`（roothide）：
   - 未 strip，79 个命名 C 函数；28 个 ObjC 类。
   - 用 unicorn 模拟安装函数，解出运行时解密的类名/选择器（FMSplashModule、FMHomeRefreshHelper、
     FishSplashAdWindow/Config、WaterfallItemCell/SingleRowItemCell 等）。
2. 拆解存图插件（XianYuPlus）：
   - 5 处 `MSHookMessageEx`；`detailContext.routerURL` 读 itemId；`UIImage imageWithData:` 截获原图；
     MTOP H5 签名直连；Photos 写入。
3. 交叉对比后写了一个**单 dylib 融合版**（不是把两个 dylib 塞进一个 deb）：
   - 去广告：开屏/热启动、信息流 cell、我的页净化；
   - 入口：我的页胶囊 + 详情页悬浮球；
   - 存图：原图/视频收集、面板选择、保存到相册；
   - 无 SQLite、无 NSTimer 轮询、无常驻后台任务。
4. 用闲鱼 `7.28.70` 的 `Runner.app/Runner` ObjC 元数据逐类核对了 hook 目标（见
   `docs/RE-COMPARE.md` §7），并按核对结果改成“类名子串枚举 + 逐类 hook”。

## 2. 关键文件

```
src/XYDCommon.h      公共声明
src/XYDPrefs.m       CFPreferences / hook 助手 / 类名枚举缓存 / URL 解析
src/XYDAdBlock.m     开屏/热启动/信息流/我的页
src/XYDMedia.m       媒体模型、UIImage/NSURLSession 采集、详情页上下文与 init 兜底
src/XYDItemAPI.m     MTOP H5（MD5 签名）与 JSON 解析
src/XYDSaver.m       Photos / WebP 转换 / 进度
src/XYDPanel.m       媒体网格、设置、缩略图队列、诊断页
src/XYDEntry.m       悬浮球、我的页入口
src/XYDMain.m        构造函数、延迟重试
docs/RE-COMPARE.md   逆向对比报告（含真机类名核对）
```

## 3. 构建 / 安装

```sh
cd plugins/xianyu-duo
./scripts/build.sh
python3 scripts/pack-deb.py
DEVICE_HOST=<ip> DEVICE_PASSWORD=<密码> sh scripts/install.sh
```

手动：

```sh
scp dist/com.pandan.xianyuduo_1.0.6_iphoneos-arm64e.deb mobile@<ip>:/var/mobile/xyd.deb
ssh mobile@<ip> 'echo <sudo密码> | sudo -S dpkg -i /var/mobile/xyd.deb; echo <sudo密码> | sudo -S sbreload'
```

## 4. 验证状态（2026-10-25 实测）

已在 `.20`（iOS 16.3.1 / 闲鱼 7.28.70）与 `.28`（iOS 17.0 / 7.28.70）安装 1.0.6，日志确认：

- 全部 hook 命中：`FMSplashModule` 4 个、`FMHomeRefreshHelper` 4 个、`FishSplashAdWindow/Config`、
  `XDetailViewController`（含 `initWithURL:query:nativeParams:`）、`FM3FlutterViewContainer`、
  `WaterfallItemCell/SingleRowItemCell/HomeCardCell/SearchResultCardCell` 共 30+ cell 类、
  `FloatingUserInfoContentView/TopUserInfoContentView` 共 5 个 view 类。
- `blocked showSplashView`：开屏拦截命中。
- `blocked requestHotStartDecide:`：热启动拦截命中。
- `.28` 上 `detail init item=1086904896314`：详情页 init 入参取 itemId 命中。
- API 链路（在 `.20` 用 debug 一次性测试）：`api test: items=1 title=...`，
  说明无 cookie 时能自己 bootstrap `_m_h5_tk`、签名、解析 `imageInfos`。
- 面板无头构建：`panel built, items=1`；原图下载：`status=200 bytes=87685`。
- 启动开销：同步安装（capture/context/splash）约 8ms；信息流/我的页 hook 延迟 0.6s 安装，
  不再占用首帧前的主线程。

仍未现场验证的只有“详情页悬浮球 → 点开面板 → 保存到相册”这一段 UI 交互：
`.20/.28` 交付时都处于锁屏，`uiopen` 能拉起 App 但 URL/路由不生效，无法自动点到详情页。
设备解锁后手工打开任意商品页即可，日志会追加 `detail appear item=...` 与 `ball installed`。


- **静态**：类/方法/ivar 已在 7.28.70 真机二进制上核对；dylib 编译无警告、arm64+arm64e 双切片、
  ad-hoc 签名通过、deb 用 GNU tar 格式（dpkg 可解）。
- 旧 combo 的三份备份仍在 `.20:/var/mobile/xyd-backup`，需要回滚时可用。

### 剩余手工验证（解锁后）

1. 打开闲鱼（已安装 1.0.6，无需重装）。
2. 进入任意商品详情页：右侧应出现悬浮球；`tmp/xianyuduo.log` 应有
   `hook -[FMSplashModule loadAd] ok`、`detail init item=...`、`detail appear item=...`。
3. 点悬浮球：面板应出现；有登录 Cookie 时状态栏显示 `共 N 项（API x / 捕获 y）`。
4. 选 1~2 张保存：相册应出现原图；失败时面板会显示失败原因。
5. 冷启动看开屏是否被拦截；信息流/搜索页广告位是否被隐藏。
6. 设置 → 诊断信息：确认各 hook 为 YES、MTOP token 是否有。

日志路径：
`/var/mobile/Containers/Data/Application/<闲鱼>/tmp/xianyuduo.log`
（设置里打开“调试日志”才有内容）。

## 4.1 2026-10-25 闪退修复记录

真机（.20）打开详情页时出现闪退/自动重启，已定位并修掉三处：

1. **init 钩子返回值语义**：对 `initWithURL:query:nativeParams:` 用普通 C 函数 + ARC 调用原实现，
   初始化器的 +1 返回值语义不可靠 → 已关闭两个 init 钩子，改用 `viewDidLoad` / `viewWillAppear` /
   Flutter 路由字段与网络请求兜底。
2. **路由 hook 递归**：`updateFlutterRouteInfo:forKey:` 的实现里又调用了 `setTopRouteInfo:` 的
   hook（其内部再调原实现），形成 set→update→set 的无限递归 → 栈溢出闪退。
   现已拆成 `xyd_handleRouteInfo(info)`：两个 hook 各自只调用自己的原实现，再解析一次，不再互调。
3. **pageName 类型未校验**：个别路由下 `pageName` 不是 NSString，直接 `.length`/`lowercaseString`
   会崩 → 所有 KVC 取出的路由字段先做 `isKindOfClass` 校验。

当前状态：两台设备冷启动均 1 次 boot、无 crash 文件；悬浮球在 debug 模式下全页面可见（便于测试），
点球后若没有识别到 itemId，可用面板左下角“输入ID”手动输入商品 ID 验证原图/保存链路。

另外新增：`tmp/xyd-crash.log`（debug 模式下的 signal / NSException 简易 backtrace），用于后续定位。

## 4.2 1.0.6 源码修复（2026-10-25）

按真机踩坑逐条修掉：

1. 删除 `UIWindow setHidden:` 全局 hook（首页状态栏异常的根因）。
2. 删除 `initWithURL:query:nativeParams:` 两个 init hook（ARC 下初始化器 +1 返回值语义不可靠）。
3. 删除 `setPageName:` / `setUtPageName:` / `setTopRouteInfo:` / `updateFlutterRouteInfo:forKey:`
   四个路由 setter hook（原实现之间互相调用导致无限递归、栈溢出闪退）。
4. 悬浮球改为独立 `UIWindow`（`UIWindowLevelAlert + 1`，透明 root VC），不再往 App 的 key window 塞子视图，
   避免影响状态栏/窗口布局；样式还原原版存图：34×34、圆角 17、`rgba(0.99,0.35,0.20,0.88)`、
   白色 `arrow.down.to.line`（15pt semibold）、黑色阴影 0.25 / offset(0,2) / radius 4。
5. KVC 取出的 `pageName`/路由字段全部做 `isKindOfClass` 校验；请求 body 解析加 256 KB 上限。
6. `detailDidLoad/WillAppear` 里不再做 `detailContext` 的 KVC 读取（真机上 KVC 会卡住主线程），
   商品 ID 改由 Flutter `pageName`（`fleamarket://item?id=...`）和详情页 `idle.item` 请求兜底。
7. 只保留页面生命周期 hook（`viewDidLoad`/`viewWillAppear`/`viewDidAppear`/`viewWillDisappear`），
   并加 enter/exit breadcrumb + `tmp/xyd-crash.log`，方便下次定位。

**现状**：1.0.6 源码已构建（`dist/com.pandan.xianyuduo_1.0.6_iphoneos-arm64e.deb`），
但真机打开详情页仍偶发重启（breadcrumb 未留下 detail 阶段日志），暂不作为日常版；
`.20` 已恢复为 **原版 3.2.2 + 原版存图** 的合并包（`plugins/xianyu-hybrid/`），保证状态栏/存图可用。

## 4.3 1.0.6 真机通过（2026-10-25）

详情页崩溃的最后一环：`detailContext` 的 KVC 在 7.28.70 上会卡住主线程。
改为 hook 闲鱼自己的 `FMURLRouter`：

- `-openURL:withQuery:withParams:` / `-openURL:withQuery:withParams:withUniqueid:`
- `+safeOpenURL:withQuery:withParams:withUniqueid:`

从路由 URL（`fleamarket://native_detail?itemId=...` / `item?id=...`）直接取商品 ID。
`.20` 实测日志：

```
router(open4) fleamarket://item?id=1091430207724 item=1091430207724
enter detailDidLoad / exit detailDidLoad
enter detailWillAppear / exit detailWillAppear
enter detailAppear / exit detailAppear
```

BOOTS=1，无 crash 文件；悬浮球已还原原版样式（34×34 橙色 + 白色 download 图标 + 阴影）。

## 5. 已知限制

1. 不含 3.2.2 的自动发货/评分/IM 自动回复/邀请。
2. “我的页净化”没有恢复出 3.2.2 的偏好黑名单，使用广告类名 + “广告/赞助”文案的保守识别，可能漏行。
3. 实况照片保存代码在 `XYDSaver.m`（`XYDSaveLive`），当前 UI 未暴露；需要先确认真机接口字段。
4. MTOP 原图列表依赖闲鱼登录 Cookie；票据过期时只显示已解码捕获的图片。
5. 如果闲鱼升级改了类名，hook 会在日志里 `not found`，不会崩溃；按 `docs/RE-COMPARE.md` 的方法重新核对类名即可。
```
