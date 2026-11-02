# 崩溃风险审计：jbb 的 `task_info` 模式会不会出现在这些插件上

审计对象：

- 报告：`plugins/crash-analyzer-pro/docs/28-XIANYU-REPORT.md`
- 高德插件：`plugins/amap-splash`（本次新做，安装在 `.20`）
- 闲鱼插件：`plugins/xianyu-duo`（`.28` 上崩溃时加载的是 **1.0.27**，
  UUID `D2A47EF6-54CA-3D21-8400-CA47660BF64E`，与 `dist/..._1.0.27_*.deb` 完全一致）
- 原始 WKK 高德 dylib：`plugins/amap-splash/src-dis/orig-xxhook.dylib`

## 1. 报告里的四个危险模式

`jbb` 的 `h_task_info` 替换了 C 函数 `task_info(TASK_DYLD_INFO)`：

1. 固定长度 `memcpy(..., 0x170)`；
2. 直接信任 `[info+4]` 的 image count；
3. 把 `*task_info` 指向全局 `gFakeInfos`（返回 fake 指针）；
4. 向全局数组 `gFakeImgArray` 写最多 0x800 条。

这类写法才是可能把调用方/自身内存写坏的来源。

## 2. 对照结论

| 模式 | jbb `h_task_info` | AmapSplash | XianyuDuo 1.0.27 | WKK 原 dylib |
|------|------------------|------------|------------------|--------------|
| Hook C 函数（`task_info`/`dyld`） | 是 | **否** | **否** | 否 |
| 无界/固定长度 `memcpy` | 是（`0x170`） | **否** | **否**（1.0.27 无 memcpy 导入） | 否 |
| 信任外部 count 遍历数组 | 是 | **否** | 否 | 否 |
| 返回全局 fake 结构指针 | 是 | **否** | **否** | 否 |
| 原始内存写 | 全局 BSS | **无** | 仅静态日志缓冲（有界） | 无 |
| 实际加载进程 | 多 App（含 Runner） | **仅 com.autonavi.amap** | com.taobao.fleamarket | 仅 com.autonavi.amap |

## 3. AmapSplash：结构上不可能复现该问题

### 3.1 它根本不会进 Runner

注入过滤只有高德：

```xml
<key>Bundles</key><array><string>com.autonavi.amap</string></array>
```

闲鱼 Runner 的 bundle id 是 `com.taobao.fleamarket`，所以 AmapSplash **不会加载**，
与这次闲鱼崩溃没有关系。

### 3.2 二进制导入表

```text
$ nm -m -u build/AmapSplash.dylib
_method_setImplementation   (libobjc)
_free                       (libSystem)
```

没有 `task_info`、没有 `memcpy`、没有 `malloc`、没有 `MSHookFunction`。

### 3.3 实现方式

- 只用 `method_setImplementation` 替换 Objective-C 方法；
- 替换函数是 `ret` / `return nil` / `return NO` / `return @NO`，**不写调用方内存**；
- `free()` 只用于释放 `class_copyMethodList` 返回的数组；
- 安装时机是 constructor，App 主线程尚未开始，无并发写。

### 3.4 已知风险（不是堆损坏）

- `-initWithFrame:` / `-init` 返回 `nil` 时，`alloc` 出来的对象没有释放，会泄漏。
  开屏/弹窗调用频率低，量很小；如果在意，可以改成 `[self release]; return nil;`
  或干脆不 hook 这两个 init。
- 如果高德未来再改方法签名，返回值类型可能不再匹配（例如 `@` 改成 `B`）。
  当前已按 `method_getTypeEncoding` 核对；`isLocalSplashDataCanExposure` 已从
  `NO` 改为 `@NO`（它的 encoding 是 `@`，不是 `B`）。

## 4. XianyuDuo 1.0.27：没有 jbb 的模式，但仍有内存压力风险

设备上实际的 1.0.27 二进制：

```text
$ nm -m -u /tmp/xyd-1.0.27.dylib
_class_addMethod            (libobjc)
_method_setImplementation   (libobjc)
_malloc / _free             (libSystem)
```

- **没有** `task_info`、`dyld`、`vm_*`、`MSHookFunction`；
- **没有** `memcpy` 导入（1.0.27 的日志拷贝被编译器内联；1.0.28 才显式导入，
  但目标是 `static char buf[16384]`，并且有 `bufLen + need > sizeof(buf)` 检查）；
- Hook 继承方法时用 `class_addMethod` 在本类加 override，不会直接改父类 Method；
- 图片/视频缓存有上限：60 条 / 64MB，离开详情页立即释放。

所以它也不会出现 jbb 那种“C 函数 + 固定长度拷贝 + fake 指针”的写坏模式。

但报告里的另一个问题与它相关：**Runner 内存 1.0–1.9GB、4 次 Jetsam**。
这类插件在大图/大视频场景会放大内存压力，虽然内存压力本身不是 nanov2 写坏的直接原因。
如果要排除它，按报告第 3 步禁用 1.0.27 复现即可。

## 5. 对 jbb 报告的一处技术修正（建议复核）

按当前 `jbb/src/jbb_v617.c`：

```c
const struct dyld_all_image_infos *real =
    (const struct dyld_all_image_infos *)(uintptr_t)di->all_image_info_addr;
memcpy(&gFakeInfos, real, sizeof(gFakeInfos));   // 源是 dyld 的真实结构
```

反汇编里 `ldr x20, [x19]` 取的是 `task_dyld_info.all_image_info_addr`，
也就是 `real`，**不是调用方那个 24 字节的 `task_dyld_info` 结构体本身**。
因此报告里“固定 0x170 memcpy 会从调用方小 buffer 越界读”这一条，可能把
`real` 误当成了 `info`。

仍然成立的风险是：

- `sizeof(gFakeInfos)` 是按当前 SDK 头文件编译的，可能与运行中的 dyld 结构体大小不一致；
- 返回 `&gFakeInfos` 给调用方，调用方按自己版本的 `dyld_all_image_infos`
  读字段时，存在版本/偏移不一致风险；
- 遍历 `real->infoArray` 时信任 dyld 提供的 count（正常应可信，但异常时没有兜底）。

另外，报告里设备 jbb UUID `A794041D…` 与当前工作区 `jbb/build/jbb.dylib`
（`310EA54A…/23E57C9F…`，已到 6.22.7）不一致。建议从 `.28` 把当时那个
`jbb.dylib` 拉回来，按同一 UUID 审计，避免拿新源码解释旧二进制。

## 6. 建议顺序

1. 按报告先禁用 jbb（`h_task_info`），跑 2–4 小时；
2. 仍复现 → 禁用 XianyuDuo 1.0.27；
3. 仍复现 → 关闭闲鱼图片/视频自动捕获（`autoCapture=NO`）再测，区分插件与闲鱼自身；
4. AmapSplash 不需要参与 Runner 的排查——它只注入 `com.autonavi.amap`。
