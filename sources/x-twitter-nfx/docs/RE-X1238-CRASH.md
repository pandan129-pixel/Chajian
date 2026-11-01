# X 12.38.1 + NFX 7.2 启动闪退：根因复现报告

日期：2026-11-01  
对象：`X_12.38.1_Plus@巨魔商店.ipa`（X 12.38.1, build 2）  
插件：`com.bandarhl.bhtwitter 7.2`（NFX/NFB 7.2，来自 `X_Twitter_12.37_NFX7.2_秋名山.ipa`）  
结论：**不是签名问题，也不是"版本号写错"，是 X 12.38.1 删掉了 `T1TabView.titleLabel`，
而 NFX 7.2 用 KVC `valueForKey:@"titleLabel"` 读它；KVC 找不到 key 会抛
`NSUnknownKeyException`，未捕获 → 启动即 abort。**

---

## 0. TL;DR

```
X 12.38.1 启动
  → 创建底部 Tab Bar，调用 -[T1TabView _t1_updateImageViewAnimated:]
  → NFX 7.2 hook 命中（0x1b36c）
  → %orig 之后无条件 tail-call [self bh_applyCurrentThemeToIcon]
  → 该方法第一段就执行 [self valueForKey:@"titleLabel"]
  → 12.38.1 的 T1TabView 既没有 -titleLabel，也没有 _titleLabel ivar（改成了 _title）
  → KVC 抛 NSUnknownKeyException: ... not key value coding-compliant for the key titleLabel
  → 未捕获异常，X 闪退
```

关键点：`valueForKey:` 和普通发消息不同。普通 `[obj titleLabel]` 对 nil 安全、
方法不存在也只会 unrecognized selector（同样是崩，但可被 respondsToSelector 防住）；
KVC 在 key 不存在时**直接抛 Objective-C 异常**，而且这段代码在
`classicTabBarEnabled` 开关判断之前执行，所以**与用户是否开经典标签栏无关**。

---

## 1. 样本与身份确认（子任务 A）

| 项 | 值 |
|---|---|
| 源 deb | `plugins/x-twitter-nfx/dist/com.bandarhl.bhtwitter_7.2_iphoneos-arm64e.deb` |
| Package / Version | `com.bandarhl.bhtwitter` / `7.2` |
| deb 内 dylib | `Library/MobileSubstrate/DynamicLibraries/BHTwitter.dylib` |
| dylib SHA-256 | `c5b0bbcdf4aefec001773fbc27d58d7876cfaab9c4b567d7d188e08094778669` |
| 架构 | thin **arm64**（X 主程序也是 arm64，架构没问题） |
| 来源 IPA | `X_Twitter_12.37_NFX7.2_秋名山.ipa` |
| 另一份 7.2（12.38.1 IPA 内） | `NeoFreeBird v7.2.0 (bb8623d)`，commit `bb8623d` = 2026-10-27 "Update Liquid Glass experiment to 12.38+" |
| 上游正式修复版 | NeoFreeBird **7.3.0**（2026-10-28，release note: "Updated X to **12.38.1**"） |

> 说明：`bb8623d` 不是 7.2.0 正式 tag，而是 7.2.0 之后、7.3.0 之前的开发提交，
> 所以二进制里版本串仍写 7.2.0。它带了 12.38 的 Liquid Glass 修复，但**不是**
> 7.3.0 的完整 12.38.1 适配。

复现：

```sh
ar -x com.bandarhl.bhtwitter_7.2_iphoneos-arm64e.deb
tar -xzf data.tar.gz
shasum -a 256 data/Library/MobileSubstrate/DynamicLibraries/BHTwitter.dylib
lipo -info data/Library/MobileSubstrate/DynamicLibraries/BHTwitter.dylib   # arm64
```

---

## 2. X 12.37 → 12.38.1 的私有 API 变化（子任务 B）

用 Mach-O ObjC 元数据解析（`tools/objcdump.py`，见 §7）对比两版 App：

| Framework | 类（12.37 → 12.38.1） | 删除类 | 方法（12.37 → 12.38.1） | 删除方法 |
|---|---|---|---|---|
| `T1Twitter` | 2156 → 2102 | **64** | 97100 → 94600 | **3441** |
| `XAppLibraries` | 3252 → 3332 | **69** | 115259 → 118602 | **1999** |
| `XServiceLibraries` | 2498 → 2509 | 1 | 68696 → 69297 | 58 |
| 主程序 `Twitter` | 186 → 185 | 1 | 8772 → 8781 | 61 |

也就是说：**一次小版本升级，X 删掉了 130+ 个私有类和 5400+ 个方法**。
这些不是公开 API，NFX 这类插件完全依赖它们，所以每次 X 升级都必须重新适配。

与本次闪退直接相关的 `T1TabView`：

```
12.37    -titleLabel  -_t1_updateTitleLabel  -_t1_showsTitle  -showsTitleInDisplayMode:
         ivar: _titleLabel
12.38.1  以上方法全部消失
         ivar: _title  （_titleLabel 被删掉）
```

验证：

```sh
# 方法
python3 tools/objcdump.py ".../T1Twitter.framework/T1Twitter" | \
  python3 -c 'import json,sys; d=json.load(sys.stdin)["T1TabView"]; print([k for k in d if "itle" in k])'
# ivar
otool -oV T1Twitter | awk '/_OBJC_CLASS_\$_T1TabView$/{f=1} f&&/ivars/{g=1} g{print} g&&/baseProperties/{exit}' | grep 'name '
```

---

## 3. 插件侧：崩溃点定位（子任务 C）

### 3.1 还原 hook 表

插件是 stripped 的，符号表里没有 `_logos_method$...`。通过
`__init_offsets` → `_logosLocalInit` → `MSHookMessageEx` 调用点还原：

- 共 259 个 `MSHookMessageEx` 调用（196 个唯一 class::selector）；
- 其中与本崩溃相关的：

```
T1TabView :: _t1_updateImageViewAnimated:   imp = 0x1b36c
T1TabView :: _t1_updateTitleLabel           imp = 0x1b2f8   ← 12.38.1 已无此方法，hook 不安装
T1TabView :: setSelected:                   imp = 0x1b3a0
T1TabBarViewController :: loadView          imp = 0xc340
```

### 3.2 `_t1_updateImageViewAnimated:` 的 hook 体

```asm
0x1b36c  ...                  ; -[T1TabView _t1_updateImageViewAnimated:]
0x1b384  blr  x8              ; %orig(...)
0x1b38c  ldr  x2, [x8,#0x570] ; SEL = bh_applyCurrentThemeToIcon
0x1b398  ...
0x1b39c  b    0x10c860        ; objc_msgSend(self, bh_applyCurrentThemeToIcon)
```

**无条件**调用，没有任何设置判断。

### 3.3 `bh_applyCurrentThemeToIcon` 的 KVC

该方法是 NFX 用 `class_addMethod` 加到 `T1TabView` 上的（`class_addMethod` at 0xa514，
IMP = 0x1b09c）：

```asm
0x1b0b4  adrp x2, 0x192108     ; CFString "imageView"
0x1b0bc  bl   valueForKey:
...
0x1b0cc  adrp x2, 0x192128     ; CFString -> 0x192138 = "titleLabel"
0x1b0d8  bl   valueForKey:     ; ← 这里抛异常
...
0x1b0ec  adrp x2, 0x192148     ; CFString "selected"
```

字符串解析结果：

```
0x192118 "imageView"
0x192138 "titleLabel"
0x192158 "selected"
```

顺序是：先 `imageView`，再 `titleLabel`，再 `selected`；
而 `if (!imageView) return;` 的 nil 判断在 `titleLabel` **之后**（0x1b0e8），
所以即使 `imageView` 为空也挡不住。

### 3.4 异常行为

`-[NSObject valueForKey:]`（KVC）在 key 没有对应 getter、也没有 `_titleLabel`
这类 ivar 时，会走 `valueForUndefinedKey:`，默认实现抛：

```
NSUnknownKeyException:
[<T1TabView 0x...> valueForUndefinedKey:]:
this class is not key value coding-compliant for the key titleLabel.
```

未捕获 → `Terminating app due to uncaught exception` → 进程退出。
这解释了为什么是"打不开"而不是"某个功能失效"：崩溃发生在启动建 Tab Bar 的阶段。

> 注：12.38.1 的 `T1TabView` 仍然有 `-title` 和 `_title`，但 KVC key 是写死的
> `"titleLabel"`，不会自动回退到 `title`。

---

## 4. 为什么"每次更新版本号"都会闪退

1. **插件没有 X 版本检查**：NFB/BHT 源码里没有读 `CFBundleShortVersionString` 的
   逻辑；deb 的 `Version: 7.2` 只约束插件自己，和 X 的版本无关。
2. **deb 的 Version +1 不会重新编译 dylib**：它只是让 Sileo 认为"有新版本"。
   真正决定兼容性的是 dylib 编译时对应的 X 私有 API 快照。
3. 因此每次 X 升级（12.37 → 12.38.1），旧 dylib 仍被注入；它按旧 API 写死的
   selector / ivar / KVC key 一旦被删，就在启动路径上直接崩。
4. 本插件在 12.37 上正常、12.38.1 上必崩，正是 §2/§3 这条链。

---

## 5. 修复方案

### 方案 A（推荐）：换 7.3.0 重打 deb

NeoFreeBird 7.3.0（2026-10-28）release note 明确写了 *"Updated X to 12.38.1"*，
并且包含针对 12.38 的具体修复：

- `FeatureSwitches.x`：`installGateWithRedesignEnabled:` 被 12.38 删除，加
  `respondsToSelector` 保护（源码注释就写着 "In 12.38 this selector got removed,
  so this is to prevent a crash"）。
- `SplitTweetView.x`：12.38 删除了 `initWith...extendedContentViewController:...`，
  改为 `class_getInstanceMethod` 探测后选择 hook group。
- `Theme.x` / `T1TabView`：改为 `applyTintColor:` 等新 API（commit `5da007b`）。
- `Misc.x`：12.38.1 新增追踪参数 `a`，`twitterURLForShareWithSParam:` 参数类型
  从 `unsigned int` 改为 `unsigned long long`。

把 7.3.0 的 `BHTwitter.dylib` 按现有打包脚本改写成
`@loader_path/.jbroot/usr/lib/libsubstrate.dylib`（roothide）/
`/var/jb/usr/lib/libsubstrate.dylib`（rootless），重新签名、打 deb、Version 升到
7.3.0 再推源即可。

> 注意：附件 IPA 里的 `bb8623d` 构建**不是**正式 7.3.0。它的 legacy
> `applyCurrentThemeToIcon` 仍然直接消息 `_t1_updateTitleLabel`（12.38.1 已删），
> 所以不要直接把 IPA 里的 dylib 抽出来当修复版。

### 方案 B（应急热修 7.2 二进制）

在 `bh_applyCurrentThemeToIcon` 里，把三个 KVC 改成安全访问，例如：

```objc
UILabel *label = [self respondsToSelector:@selector(titleLabel)]
    ? [self valueForKey:@"titleLabel"] : nil;
```

对应二进制层面：把 `valueForKey:` 调用替换成 `respondsToSelector:` + `objc_msgSend`，
或直接 NOP 掉 `titleLabel` 的 KVC 分支（只影响经典标签栏文字配色）。
同时给 `_t1_updateTitleLabel` 的调用加 `respondsToSelector` 保护。
热修能救启动，但 12.38.1 还有几十处 hook 目标消失，功能仍会残缺——只适合临时过渡。

### 方案 C（发布流程加固）

在每次 X 发版后、推源前跑一次"hook 目标存在性审计"：

```sh
# 1) 导出新 X 的 ObjC 元数据
python3 tools/objcdump.py .../T1Twitter.framework/T1Twitter > t1.json
python3 tools/objcdump.py .../XAppLibraries.framework/XAppLibraries > xapp.json

# 2) 导出版本内 dylib 的 hook 表（unstripped 用 nm，stripped 用 tools/hookdump.py）
nm BHTwitter.dylib | grep '_logos_method$_ungrouped$' > hooks.txt

# 3) 比对：class / selector 是否存在；KVC key 是否还有对应 ivar
```

任何 hook 的 class 或 selector 在新版里消失，就必须在发版前处理：
加 `respondsToSelector` / `objc_getClass` nil 检查，或删除该 hook。
这套检查能把"每次升级必崩"变成"升级前就能发现"。

---

## 6. 现场验证（用户侧）

1. 卸载 `com.bandarhl.bhtwitter`（或 Choicy 关掉 X 的注入）后冷启动 X：
   能进 → 确认是插件问题。
2. 崩溃日志里应出现：
   ```
   NSUnknownKeyException ... valueForUndefinedKey: ... key titleLabel
   T1TabView
   bh_applyCurrentThemeToIcon
   _t1_updateImageViewAnimated:
   ```
   路径：设置 → 隐私与安全性 → 分析与改进 → 分析数据 → 搜 `Twitter`/`X`。
3. 装 7.3.0 后同样位置应无异常。

---

## 7. 复现工具

`tools/objcdump.py`：Mach-O（arm64 + chained fixups）ObjC 类/方法/类型导出。
用法：

```sh
python3 tools/objcdump.py <macho> > out.json
```

本报告用到的其它脚本（hook 表还原、函数内 selector 扫描）为一次性脚本，
逻辑已写在 §3；需要长期用可固化成 CI 检查。

---

## 8. 结论一句话

**X 12.38.1 把 `T1TabView` 的 `titleLabel`（getter + `_titleLabel` ivar）换成了
`title`；NFX 7.2 在启动建 Tab Bar 的 hook 里用 KVC 读 `titleLabel`，KVC 对缺失 key
直接抛 `NSUnknownKeyException`，于是 X 启动即崩。改 deb 的 Version 号没用，必须换
按 12.38.1 重新适配的 dylib（NeoFreeBird 7.3.0 或自行加 guard 重建）。**
