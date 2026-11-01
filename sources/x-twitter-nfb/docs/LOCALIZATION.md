# NeoFreeBird 7.3.0 中文化研究报告

日期：2026-11-01  
源码：`src/NeoFreeBird-7.3.0/`（来自 github.com/NeoFreeBird/app v7.3.0，GPL-3.0）  
参考：`com.sini.neofreebird.bht 5.3-1`（NFB-BHTwitter 中文版，刀刀）

---

## 0. 结论

1. **中文翻译本身不是问题**：上游 7.3.0 已经带 `zh_CN.lproj`，314/318 条；
   真正导致界面显示 `NFB_SETTINGS_TITLE` 的是 **资源包没被找到**。
2. **`zh_CN` 能被 `zh-Hans` / `zh-Hans-CN` 命中**（CFBundle 会做旧语言码归一化），
   `zh-Hans.lproj` 不是必须，但建议补上作为规范名。
3. **中文版（com.sini.neofreebird.bht）不是靠“强制中文”**：
   它只是把 `BHTBundle` 的路径换成了 `libroot_dyn_jbrootpath()`，
   在 rootless 上能定位到 `<jbroot>/Library/Application Support/BHT/BHTwitter.bundle`；
   界面语言仍然是系统/App 语言。
4. **7.3.0 最稳的中文化办法**：
   - 资源：补 `zh-Hans.lproj` + 完成 `zh_CN.lproj`（318/318）；
   - 路径：用 dylib 自身位置解析 bundle（`dladdr`），不要写死 `/Library`、`/var/jb`；
   - 术语：`RenameWords.strings` 用中文 key，并给正则加
     `NSRegularExpressionUseUnicodeWordBoundaries`（否则中文词在句子中间永远不匹配）；
   - 语言：默认跟随 X 的 App 语言；需要强制中文时再加快关。

---

## 1. 三份样本的对比

| 项 | 官方 7.3.0 | 中文版 5.3-1 | 我们的 7.3.0-7 |
|---|---|---|---|
| Package | `com.nfb.tweak` | `com.sini.neofreebird.bht` | `com.nfb.tweak` |
| 版本 | 7.3.0 | 5.3-1（旧 5.x 代码线） | 7.3.0（12.39 构建） |
| en 条数 | 318 | 327 | 341 |
| zh_CN 条数 | 314 | 281 | 341 |
| zh-Hans | 无 | 无 | **有** |
| 资源包路径 | 写死 `/Library`、`/var/jb` | `libroot_dyn_jbrootpath()` | dylib 相对 + `0NFBBundleFix.dylib` |
| 强制语言 | 无 | 无 | 无（跟随 App） |
| 中文来源 | `zh_CN` | `zh_CN` | `zh-Hans` + `zh_CN` |

> 中文版是 5.x 老代码线，key 和 7.3.0 只有 59 个重合，不能直接拿它的
> `Localizable.strings` 覆盖 7.3.0；它的中文覆盖（281/327）也比上游（314/318）差。

---

## 2. 机制：NSBundle 怎么选语言

`src/Core/BHTBundle.m`：

```objc
- (NSString*)localizedStringForKey:(NSString*)key {
    return [self.mainBundle localizedStringForKey:key value:key table:nil];
}
```

- `table:nil` → `Localizable.strings`；
- `value:key` → 找不到 key 时返回 key 本身（所以界面会显示 `NFB_SETTINGS_TITLE`）；
- 如果 key 在 `zh_CN` 缺失、但 `en` 有，会**回退到英文**（不是 key）。

CFBundle 实测（真实 bundle）：

| App 语言 | preferredLocalizations | `NFB_SETTINGS_TITLE` |
|---|---|---|
| `zh-Hans-CN` | `zh_CN` | 中文 |
| `zh-Hans` | `zh_CN` | 中文 |
| `en-US` | `en` | 英文 |

所以：

- **显示 key** = 资源包没找到；
- **显示英文** = 资源包找到了，但 X 的 App 语言是英文。

---

## 3. 中文版是怎么做到的

`com.sini.neofreebird.bht` 的 dylib 里有一个本地 `jbroot(NSString*)`：

```
jbroot(path) -> libroot_dyn_jbrootpath(path, buf)
             -> dlopen("@rpath/libroot.dylib")
             -> dlsym("libroot_jbrootpath")
             -> fallback: prefix "/var/jb"
```

`+[BHTBundle sharedBundle]` 把写死的
`/Library/Application Support/BHT/BHTwitter.bundle`
先过 `jbroot()`，于是 rootless 下变成
`/var/jb/Library/Application Support/BHT/BHTwitter.bundle`，就能找到。

它**没有**读 `AppleLanguages`，也**没有**把中文写死；中文只是
`zh_CN.lproj` + 系统/App 语言自然命中的结果。

---

## 4. 7.3.0 的正确中文化方案

### 4.1 资源层（已实现）

`layout/.../BHTwitter.bundle/` 下：

```
zh-Hans.lproj/Localizable.strings     ← 318/318
zh-Hans.lproj/RenameWords.strings
zh_CN.lproj/Localizable.strings       ← 与 zh-Hans 完全一致
zh_CN.lproj/RenameWords.strings
```

两个目录保持一致（`diff -r` 只差头部注释），避免 `zh-Hans-CN` 和 `zh-Hans`
命中不同文件时文案不一致。

验证：

```sh
cd src/NeoFreeBird-7.3.0
./check_localization.py zh-Hans zh_CN
# zh-Hans — 318/318 translated (100.0%)
# zh_CN  — 318/318 translated (100.0%)
```

> 掌上包（12.39 构建）是 341 条，另有 23 个新 key（FLEX/Liquid Glass 等），
> 已在 `l10n/` 和 7.3.0-7 的 bundle 里补齐。

### 4.2 路径层：不要写死绝对路径

源码里已把 `BHTBundle.m` 改成从 dylib 自身位置找：

```objc
static NSString* BHTResolveBundlePath(void) {
    NSFileManager* fm = [NSFileManager defaultManager];
    Dl_info info;
    if (dladdr((void*)BHTResolveBundlePath, &info) && info.dli_fname) {
        NSString* d = [[NSString stringWithUTF8String:info.dli_fname]
                       stringByDeletingLastPathComponent];
        for (int i = 0; i < 6 && d.length > 1; i++) {
            NSString* p = [[d stringByAppendingPathComponent:@"BHTwitter.bundle"]
                           stringByStandardizingPath];
            if ([fm fileExistsAtPath:p]) return p;
            p = [[d stringByAppendingPathComponent:
                  @"Library/Application Support/BHT/BHTwitter.bundle"]
                 stringByStandardizingPath];
            if ([fm fileExistsAtPath:p]) return p;
            d = [d stringByDeletingLastPathComponent];
        }
    }
    for (NSString* p in @[
             @"/Library/Application Support/BHT/BHTwitter.bundle",
             @"/var/jb/Library/Application Support/BHT/BHTwitter.bundle"]) {
        if ([fm fileExistsAtPath:p]) return p;
    }
    return [[NSBundle mainBundle] URLForResource:@"BHTwitter"
                                   withExtension:@"bundle"].path;
}
```

覆盖：

| 环境 | dylib 所在 | 找到的 bundle |
|---|---|---|
| rootful | `/Library/MobileSubstrate/DynamicLibraries` | `/Library/Application Support/BHT/...` |
| rootless | `/var/jb/Library/MobileSubstrate/DynamicLibraries` | `/var/jb/Library/Application Support/BHT/...` |
| roothide | `<jbroot>/Library/MobileSubstrate/DynamicLibraries` | `<jbroot>/Library/Application Support/BHT/...` |
| 侧载 | `X.app/Frameworks` | `X.app/BHTwitter.bundle`（fallback） |

如果不重编译，直接用 `fix/NFBBundleFix.m` 编译出的
`0NFBBundleFix.dylib`（7.3.0-7 已内置），原理相同：从自己位置找 bundle，
再精确重定向 `+[NSBundle bundleWithPath:]` / `-[NSFileManager fileExistsAtPath:]`。

### 4.3 术语层：中文 RenameWords 必须用 Unicode 词边界

`Branding.x` 原来用：

```objc
\\b(转帖|帖子|…)\\b
```

ICU 的 `\b` 只区分“词字符/非词字符”，**两个汉字相邻没有边界**，
所以 `你转帖了这条帖子` 里的 `转帖`、`帖子` 都匹配不到。

已改为：

```objc
options:(NSRegularExpressionCaseInsensitive |
         NSRegularExpressionUseUnicodeWordBoundaries)
```

中文表（`zh-Hans/RenameWords.strings`）：

```text
"premium" = "blue";
"Premium" = "Blue";
"X" = "Twitter";
"已发帖" = "已发推";
"已转帖" = "已转推";
"发帖" = "发推";
"帖子" = "推文";
"贴文" = "推文";
"正在发送帖子" = "正在发送推文";
"正在转帖" = "正在转推";
"转帖" = "转推";
```

### 4.4 语言层（可选：强制中文）

默认跟随 X 的 App 语言。如果希望“X 是英文也显示中文”，在
`BHTBundle.m` 的 `localizedStringForKey:` 里优先加载 `zh-Hans.lproj`：

```objc
- (NSString*)localizedStringForKey:(NSString*)key {
    if (self.forceChinese) {
        NSBundle* zh = [NSBundle bundleWithPath:
            [self.mainBundle pathForResource:@"zh-Hans" ofType:@"lproj"]];
        NSString* s = [zh localizedStringForKey:key value:nil table:nil];
        if (s) return s;
        NSBundle* en = [NSBundle bundleWithPath:
            [self.mainBundle pathForResource:@"en" ofType:@"lproj"]];
        s = [en localizedStringForKey:key value:nil table:nil];
        if (s) return s;
        return key;
    }
    return [self.mainBundle localizedStringForKey:key value:key table:nil];
}
```

注意：裸 `.lproj` 作为 bundle 时**没有** development region 回退，
所以要先查 `zh-Hans` 再手动查 `en`，否则缺 key 会显示 key。

---

## 5. 本次已经落地的内容

| 位置 | 内容 |
|---|---|
| `src/NeoFreeBird-7.3.0/layout/.../zh-Hans.lproj` | 318/318 Localizable + RenameWords |
| `src/NeoFreeBird-7.3.0/layout/.../zh_CN.lproj` | 与 zh-Hans 一致 |
| `src/Core/BHTBundle.m` | dladdr 相对路径解析（覆盖 rootful/rootless/roothide/侧载） |
| `src/Hooks/Branding.x` | Unicode 词边界，中文术语可在句中替换 |
| `l10n/build_zh.py` | 341 条打包用汉化（12.39 构建） |
| `fix/NFBBundleFix.m` | 不改二进制的 bundle 路径修复 dylib |
| `dist/com.nfb.tweak_7.3.0-7_*.deb` | 带汉化 + bundle fix 的成品 |

验证：

```sh
cd src/NeoFreeBird-7.3.0
./check_localization.py zh-Hans zh_CN
python3 ~/Desktop/iphone/plugins/x-twitter-nfb/l10n/apply_to_source.py   # 重新生成
```

---

## 6. 开源情况

- **上游 NeoFreeBird**：`https://github.com/NeoFreeBird/app`，**GPL-3.0**
  （源码目录里的 `LICENSE`）。v7.3.0 源码完整，可以自己编译、改汉化、加语言开关。
- **12.39 秋名山定制构建**：基于 7.3.0 源码做了修改（`resolvedBundleURL`、
  `applyTintColor:` 等），这些改动**不在上游公开仓库**，所以那份二进制的源码没有公开。
- **中文版 `com.sini.neofreebird.bht`**：基于旧 5.x BHT/NFB 代码线，
  翻译和 libroot 改动由“刀刀”维护，没有看到公开的完整源码仓库；
  它的中文资源可以直接参考，但 key 集合与 7.3.0 不兼容。

> GPL-3.0 下，二次分发修改版应当提供对应源码；实际中文版/定制版是否遵守，
> 需要看发布者是否给出源码链接。

---

## 7. 一句话

中文化不是“再翻译一遍”那么简单：**先保证 `BHTwitter.bundle` 在 rootless/roothide
上都能被找到，再补 `zh-Hans` + `zh_CN`，最后修中文术语匹配的词边界**。  
这三步做完，X 是中文时 NFB 就是中文；X 是英文时仍然英文（除非加强制语言开关）。
