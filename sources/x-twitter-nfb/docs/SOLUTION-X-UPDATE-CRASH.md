# 怎么解决「X 一更新就闪退」

日期：2026-11-01  
适用：Pandan 源里的 NeoFreeBird / NFX 插件  
当前可用包：`com.nfb.tweak 7.3.0-2`（dylib 来自 `X_Twitter_12.39_NFB730_秋名山.ipa`）

---

## 0. 一句话结论

根因不是签名、也不是 deb 的 `Version:`，而是**插件把 X 的私有 ObjC API 写死了，而 X 每次更新都会删改一批**。
所以只有三条路同时做，才能让"更新即闪退"变成"更新后最多失效、但 App 能开"：

1. **跟版**：X 发版后先用新 IPA 里的 NFB 重新打包（本次已做）。
2. **发版前审计**：对比新旧 X 的类/方法/签名，关键 hook 缺失就不推。
3. **fail-open 闸门**：插件启动时先看 X 版本，不认识就**不装 hook**，让 X 正常打开。

第 3 条是根治；前两条只能保证"这次不崩"。

---

## 1. 为什么每次更新都会崩

以 12.37 → 12.38.1 → 12.39 的实测数据：

| 对比 | 删除类 | 删除方法 |
|---|---|---|
| 12.37 → 12.38.1（T1Twitter + XAppLibraries + XServiceLibraries） | 130+ | 5400+ |
| 12.38.1 → 12.39（同三个框架） | 25 | 1206 |

插件里大量代码是这种形式：

```objc
%hook T1TabView
- (void)_t1_updateTitleLabel { ... self.titleLabel.textColor = ...; }
%end
```

或者：

```objc
[self valueForKey:@"titleLabel"];   // KVC
```

X 12.38 把 `T1TabView.titleLabel` / `_titleLabel` / `_t1_updateTitleLabel` 全删了（换成 `title` / `_title`），于是：

- 普通发消息：`unrecognized selector` → 崩；
- KVC：`NSUnknownKeyException` → 崩；
- 更隐蔽的：方法还在但参数/返回类型变了 → 栈/寄存器错位 → 随机崩。

而 NFB/BHT 没有 X 版本检查（源码里 0 处读 `CFBundleShortVersionString`），所以旧 dylib 会继续注入，
崩溃点又在启动路径上，表现就是"X 打不开"。

---

## 2. 现在这版（L1：跟版）

`com.nfb.tweak 7.3.0-2` 的 dylib 取自 **X 12.39 的 NFB730 IPA**，与官方 7.3.0 deb 的区别：

- `T1TabView` 改用 `applyTintColor:`，**不再**定义/调用 `applyCurrentThemeToIcon`；
- 不再 hook `_t1_updateTitleLabel`（12.38+ 已删）；
- 保留 12.38 的 Liquid Glass 修复（`installGateWithRedesignEnabled:` 的 `respondsToSelector` 保护）；
- 用 12.39 的 hook 表审计：308 个 hook，**0 个 hook 体内调用 12.39 已删的 selector**；
- 38 个类 / 36 个方法在 12.39 里不存在，但这些 hook 只是不安装（功能失效），不会崩。

安装后：

```sh
dpkg -l | grep -E 'bhtwitter|nfb'   # 只应剩 com.nfb.tweak
killall Twitter 2>/dev/null; killall X 2>/dev/null
```

包内已写 `Conflicts/Replaces: com.bandarhl.bhtwitter`，装的时候会自动移除旧 NFX 7.2，避免双注入。

---

## 3. 每次 X 发版的审计流程（L2）

本仓库已经有工具：`plugins/x-twitter-nfx/tools/objcdump.py`。

```sh
# 1) 解出新 X 的三个大框架
unzip -q X_12.xx.ipa 'Payload/Twitter.app/Frameworks/T1Twitter.framework/T1Twitter' \
                     'Payload/Twitter.app/Frameworks/XAppLibraries.framework/XAppLibraries' \
                     'Payload/Twitter.app/Frameworks/XServiceLibraries.framework/XServiceLibraries'

# 2) 导出 ObjC 元数据
for f in T1Twitter XAppLibraries XServiceLibraries; do
  python3 plugins/x-twitter-nfx/tools/objcdump.py \
    "Payload/Twitter.app/Frameworks/$f.framework/$f" > "/tmp/$f.json"
done

# 3) 比对：与上一版 JSON 做 class/selector/type 差集
#    关键规则：插件 hook 的 class 或 selector 缺失 → 先别推
```

判定规则（建议写进发布检查单）：

- **启动路径**的 hook（`T1AppDelegate`、`T1TabBarViewController`、`T1TabView`、
  `T1AnimatedLaunchScreenView`、`TFNTwitterAccount`）缺失 → **阻塞发布**；
- 普通功能 hook 缺失 → 可以发，但 Description 里写清楚"X xx 下某功能不可用"；
- 方法还在但 `types` 变了 → **阻塞发布**（ABI 不兼容，必崩）。

---

## 4. 根治：fail-open 版本闸门（L3）

### 4.1 原则

> 不认识的 X 版本 → 不装任何 hook → X 正常打开，插件静默失效。

这比"崩了再让用户卸载"好得多，也让源可以大胆跟版。

### 4.2 方案 A：改 NFB 源码（能编译时首选）

在 `Tweak.x` 的 `%ctor` 里，`%init` 之前加：

```objc
static BOOL NFBIsSupportedX(void) {
    NSString *v = [[NSBundle mainBundle]
        objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    static NSSet *supported;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        supported = [NSSet setWithArray:@[ @"12.38", @"12.38.1", @"12.39" ]];
    });
    return v && [supported containsObject:v];
}

%ctor {
    if (!NFBIsSupportedX()) {
        NSLog(@"[NFB] X %@ is not in the tested list, hooks disabled",
              [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]);
        return;              // 注意：直接 return，不执行 %init
    }
    %init;
}
```

每次 X 发版：测完把新版本号加进 `supported` 再发包。
想给高级用户留后门，可以读一个 `forceLoad` 偏好覆盖。

### 4.3 方案 B：不改 NFB，用 guard loader（当前包可直接加）

思路：注入的 `BHTwitter.dylib` 只做版本判断；真正插件改名 `BHTwitter.real.dylib`（没有 filter plist，不会被自动注入）。

```
TweakInject/
  BHTwitter.dylib        ← guard（filter: com.atebits.Tweetie2）
  BHTwitter.plist
  BHTwitter.real.dylib   ← 真正的 NFB，由 guard 在版本匹配时 dlopen
  libbhFLEX.dylib ...
```

guard 源码（arm64，Foundation + dlfcn）：

```objc
#import <Foundation/Foundation.h>
#import <dlfcn.h>

static BOOL NFBAllowed(void) {
    NSString *v = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.nfb.tweak.plist"];
    if ([prefs[@"forceLoad"] boolValue]) return YES;
    static NSSet *ok;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ok = [NSSet setWithArray:@[ @"12.39" ]]; });
    return v && [ok containsObject:v];
}

__attribute__((constructor)) static void nfb_guard(void) {
    if (!NFBAllowed()) {
        NSLog(@"[NFBGuard] X %@ unsupported, skip loading NFB",
              [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]);
        return;
    }
    Dl_info info;
    if (dladdr((void *)nfb_guard, &info) && info.dli_fname) {
        NSString *dir = [[NSString stringWithUTF8String:info.dli_fname] stringByDeletingLastPathComponent];
        NSString *real = [dir stringByAppendingPathComponent:@"BHTwitter.real.dylib"];
        if (!dlopen(real.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL))
            NSLog(@"[NFBGuard] dlopen failed: %s", dlerror());
    }
}
```

编译：

```sh
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
  -dynamiclib -framework Foundation -o BHTwitter.dylib guard.m
codesign -f -s - BHTwitter.dylib
```

打包时把真插件改名为 `BHTwitter.real.dylib`，guard 用 `BHTwitter.dylib` + filter plist。
效果：

- X 12.39 → 正常加载 NFB；
- X 12.40（未测试）→ guard 直接跳过，X 能开，只是没插件；
- 想强制 → 写 `forceLoad = true` 到偏好文件。

### 4.4 防御式写法（新 hook 必须遵守）

- 类：`Class c = objc_getClass("..."); if (!c) return;`
- 方法：`if (!class_getInstanceMethod(c, sel)) return;`
- 实例：`if (![obj respondsToSelector:sel]) return;`
- **不要**用 KVC 读私有 key：`valueForKey:` 找不到就抛异常；
  改用 `class_getInstanceVariable` + `object_getIvar`，或先用 `respondsToSelector`。
- `%orig` 只有在 hook 确实安装后才可能被调用；不要缓存 `%orig` 到全局后在别处盲调。

### 4.5 防双注入

- deb 的 `Conflicts/Replaces` 必须覆盖所有旧的包名（`com.bandarhl.bhtwitter`、
  `xyz.cypwn.bhtwitter` 等）；
- 侧载 IPA 和 deb 只留一个；
- 发版前在设备上 `dpkg -l | grep -i bhtwitter` 确认只剩一个。

---

## 5. 用户侧（L0）

在源更新之前，最简单的是**别让 X 自动升级**：

- 关闭 App Store 的「App 自动更新」；
- 或用 AppStore++ / 更新屏蔽类插件把 X 锁在当前版本；
- 已经升到新版本且闪退：装本源的 `com.nfb.tweak`（会自动移除旧 NFX），或临时卸载插件让 X 先能开。

---

## 6. 每次发版检查单

- [ ] 解包新 X IPA，确认 `CFBundleShortVersionString`
- [ ] `objcdump` 导出 T1Twitter / XAppLibraries / XServiceLibraries
- [ ] 对比上一版：启动路径 hook 的 class/selector 是否存在、types 是否变化
- [ ] 若关键 hook 缺失：先改 hook / 加 guard，再发
- [ ] 设备冷启动 3 次 + 设置项逐项点一遍
- [ ] `dpkg -l` 确认没有旧包并存
- [ ] deb `Version` 递增，Description/Name 写清支持的 X 版本
- [ ] 推源后先用 `http://<mac>:8090/` 本机源验证，再发公网

---

## 7. 本次产物的审计数据

`X_Twitter_12.39_NFB730_秋名山.ipa` 里的 dylib：

- 308 uniqued hook（`class::selector`）
- 12.39 中不存在的 hook 类：38 个（多为 iPad 分栏、旧 Tab Bar、部分账号开关）
- 12.39 中不存在的 hook 方法：36 个（hook 不安装，功能失效）
- hook 体内调用"12.39 已删 selector"的数量：**0**
- `T1TabView` hooks：`_t1_updateImageViewAnimated:`、`applyTintColor:`、`didMoveToWindow`、
  `layoutSubviews`、`setSelected:`（不再有 `_t1_updateTitleLabel` / `applyCurrentThemeToIcon`）

结论：这版在 12.39 上**启动路径没有已知崩溃点**；未测试的 12.40 仍需要 guard 才能保证 fail-open。
