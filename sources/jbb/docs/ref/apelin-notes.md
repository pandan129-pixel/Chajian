# Apelin 阅读笔记（2026-10-25）

仓库：`https://github.com/owngoal-dev/Apelin`（MIT，0.1.x，Swift/ObjC，iOS 16+ roothide/rootless）
本地副本：`/private/var/folders/.../opencode/apelin`（只读参考，勿当生产依赖）
配套交接：`ref/apelin-tweak-rules-handoff-2026-10-25.md`（规则 → 我们所有插件的检查单）

定位：**在设备上完成「编辑 → 编译 → 签名 → 打 deb → 安装 → respring → 验证」的 IDE + agent**。
不是 Theos，不是 Mac 工具，不解决业务逻辑（SMB 那部分它一点忙也帮不上）。

---

## 1. 构建链路（源码 → 已安装 deb）

顺序由 schema 强制（`Packages/ApelinKit/Sources/ApelinBuild/Pipeline/BuildPipeline.swift`）：

```
compile → link → lipo → dsym → strip → sign
```
- `sign` 必须是最后一步；sign 之后再动文件，签名即失效（`ApelinCodeSign/CodeSigner.swift` 注释）。
- `dsym` 必须在 `strip` 之前、且 `.o` 要保留（一步编译+链接会丢调试信息）。
- 每个 arch 单独 `.o` → 链接 → `lipo -create` → `dsymutil` → `strip` → 签名。
- `strip -S`（debug）或 `-x`（non-global，默认）。

固定编译基线（`BuildPipeline.swift:262-288`）：
```
-isysroot <已注册 SDK 物理路径> -arch <arch> -mios-version-min=<deploymentTarget>
-O<opt> -Wall -Wextra -Werror=unguarded-availability-new
-fvisibility=hidden -ffile-prefix-map=<projectRoot>=.
[-g] [-fobjc-arc] [-D...] [-I...] -c src -o obj.o
```
链接：`-dynamiclib -install_name @rpath/<name>.dylib`（dylib）/ `-bundle`（bundle），
`-L/-F` 支持目录、`-Wl,-rpath,<p>`、`-framework/-weak_framework/-l`。

编译期宏（`BuildPipeline.swift:152-170`）：
`APELIN_BUILD_ID`（= taskID，也是 mark ID）、`APELIN_PACKAGE_ID`、`APELIN_VERSION`、
`APELIN_BOOTSTRAP_ROOTHIDE|ROOTLESS=1`、`APELIN_CONFIGURATION_DEBUG|RELEASE=1`、
每产品再追加 `APELIN_PRODUCT_NAME`。**Swift 只拿后两个**。

与 Theos 对照（`Documents/Schemas/README.md`、`Extensions/Development/`）：

| Theos | Apelin |
|---|---|
| `%hook` Logos / `.xm` | **没有**，纯 ObjC + `MSHookMessageEx`（模板 `Sources/Tweak.m`） |
| `Makefile` + `ARCHS` | `apelin-project.json` 的 `architectures` / `deploymentTarget` |
| `TWEAK_NAME` + install 路径 | `products[].name` + `package.layout[].path` |
| `TWEAK.plist` filter | `package.tweakFilter`（自动生成，跟 dylib 同目录，`Foo.dylib` → `Foo.plist`） |
| `ldid -S` | 进程内 `ApelinCodeSign`（等价 `ldid -Hsha256 -S`，无 CMS） |
| `dpkg-deb` / `layout/` | 进程内 `DebPackageWriter`（control.tar.gz + data.tar.zst） |

现状：Theos 明确“不支持”，`agent` 被要求把 Logos 改写成 ObjC。
**但** workspace（导入的仓库）可跑自己的 `external.script`，只要求最终在 `APELIN_PACKAGE_DIR` 里产出一个 deb；
设备上没有 `xcrun`，通常也没有 `make`/`python3` —— 所以 Theos 工程搬不上去（`ApelinAgent/Skills/BuiltIn/ExternalBuild.swift`）。

安装只走 **deb → irisind**，不允许 apt/dpkg（`AGENTS.md:1962-1967`）。

---

## 2. 七个真正的硬坑

1. **arm64e + `-undefined dynamic_lookup` 会丢指针签名**（`AGENTS.md:2231-2241`）
   CLT 15.0 的 ld 在这种链接下写出普通 dyld opcode：槽位里的签名被 dyld 用裸指针覆盖，
   第一条发给 `@"…"` 常量的消息就崩。CLT 14.2 / 15.3 / 16.4 / 27.0 正常；Xcode 27 的 ld 自动走 chained fixups。
   留在加载期绑定的符号必须写成 `-Wl,-U,_symbol`。
   → 我们的 tweak 若用 arm64e + 动态查找，构建完**必须检查 fixups 是否 chained/threaded**，否则“能装不崩”是运气。

2. **roothide 的 `NSHomeDirectory()` 是骗人的**（`AGENTS.md:1742-1746`）
   返回系统的 `/var/mobile`，不是 `<jbroot>/var/mobile`。要从自己 bundle 路径推 jbroot
   （`RoothideRoot`，libroothide 的命名规则），不要 `dlopen` 走 `.jbroot` 链接，也不要靠“有没有 /var/jb”判断。

3. **shell 路径 ≠ 编译器路径**（`AGENTS.md:2477-2482`）
   roothide 下 shell 看到 bootstrap 是 `/`、真根是 `/rootfs`；`pwd -P`/`realpath` 打出来的是 `/var/mobile/...`，
   对 Apple 编译器指向系统目录。`-isysroot` 要用 jbroot 物理路径；脚本里传相对路径。

4. **架构是“按 bootstrap”决定，不是按设备 CPU**
   模板 manifest：`roothide → ["arm64e"]`，`rootless → ["arm64","arm64e"]`
   （`Extensions/Development/wiki.qaq.apelin.dev.tweak/manifest.json:18-21`）。
   deb 的 `Architecture` 只由 bootstrap 决定（`PackageLayout.swift:57-62`），与 arch 列表无关。
   → 我们实测“单 arm64e 注入不了微信”，所以 roothide 默认产物**不够**，必须手改 `architectures` 并自备 lipo。

5. **签名要带对 entitlement，且签名是最后一步**
   签名器拒绝：`.o`/dSYM/非 MH_DYLIB|BUNDLE|EXECUTE、32 位、非小端、
   会丢进 DER 的 entitlement（binary plist、date/real、非十进制整数、CF$UID 根等）（`LdidEntitlements.swift`）。
   exec-segment flags 由 entitlement 推出来（`get-task-allow`/`run-unsigned-code`/`debugger`/`dynamic-codesigning`/`skip-library-validation`）。

6. **filter plist 的命名**
   跟 dylib 同目录、去掉扩展名再加 `.plist`：`Library/MobileSubstrate/DynamicLibraries/Foo.dylib` → `Foo.plist`；
   内容是 `{ Filter = { Bundles / Executables / Classes } }`，只写存在的键，0644。
   空 filter 直接是项目错误。

7. **`-fvisibility=hidden` 是默认值，不是可选项**
   模板/基线都带它；目的就是跟别的 tweak 共存（hook 链、`static` 名字、给新增方法/类加前缀）。

---

## 3. roothide vs rootless（可直接抄的差异表）

| 项 | roothide | rootless |
|---|---|---|
| deb `Architecture` | `iphoneos-arm64e` | `iphoneos-arm64` |
| 安装前缀 | 空（boot 时选 jbroot） | `/var/jb` |
| dylib 架构 | `arm64e`（模板默认） | `arm64` + `arm64e` |
| substrate 链接 | `@loader_path/.jbroot/usr/lib/libsubstrate.dylib` | `@rpath/CydiaSubstrate.framework/CydiaSubstrate` |
| rpath | 无 | `@PREFIX@/Library/Frameworks`, `@PREFIX@/usr/lib` |
| launchd plist 路径 | 需以 `/rootfs/...` 开头（launchctl 会补 bootstrap 根） | 直接写 `/var/jb/...` |

打包约定：逻辑路径写 `/X`，由 packager 映射；**项目里不许出现具体设备的 jbroot 路径**；
`@PREFIX@` / `@ROOTFS@` 由打包时替换；重复加前缀会被拒（`PackageLayout.swift:77-79`）。

roothide 侧两个运行期坑：
- 卸载包后目录和 `.jbroot` 链接都留着 → “看起来还在”，删除被拒（`ToolchainService.exists`）。
- `launchctl bootstrap system <plist>` 可能落到前台域，`bootout <label>` 撤不掉；
  正解是 `bootout system <plist>`（路径形式），再清 system / user/501 / gui/501 三个 label，
  等消失后重试，最后用 `launchctl print` 验证（`AGENTS.md:1219-1231`）。

---

## 4. 运行期架构：两个值得抄的模式

### 4.1 特权 helper（SMB 真挂载要用）
- 一个 binary 两模式：无参 = launchd proxy；`--session` + fd 3 socketpair = session host。
  启动先检查 `proc_pidpath` 后缀（`Apelind/main.swift:4-21`）。
- 客户端认证（`Apelind/PeerAuthenticator.swift`）：audit token → euid ∈ {0,501} → pid>1 →
  `xpc_copy_entitlement_for_token` 要求三个 entitlement 为 true →
  `proc_pidpath` 必须精确等于安装根下的可执行文件 → 该文件 root 所有、`u+x`、组/其他不可写。
  **没有 SecCode/requirement 字符串校验**，靠“内核给的 entitlement + 路径 + 属主”绑定。
- 操作面是**封闭的 typed 枚举**，明确“没有 exec(path, argv)”（`AppProtocol.swift:1-2`）。
- 降权：`posix_spawnattr_set_uid/gid/groups_np` 在 exec 前设好，exec 后读 `PROC_PIDTBSDINFO` 复核六个 id，
  不符直接 SIGKILL（`Apelind/Spawn.swift:44-78`）。
- **特权进程必须 `DISABLE_TWEAKS=1`**：launchd plist、session host 环境、每个 worker 都带它
  （“Nothing may inject into the process that does privileged work”）。我们写 root helper 时照做，
  否则 ElleKit 会往里注（尤其你装了 jbb）。
- entitlement 是**按进程**的：root + `no-sandbox` 不等于能读别的 App 容器，
  要 `com.apple.private.security.storage.<Class>` 加在**这个进程**的二进制上（`Packaging/Apelind.entitlements` 注释）。

### 4.2 长任务（SMB 大文件/后台同步要用）
- 任务 = `taskID` + `kind`；事件 1..n 连续编号；`attach{taskID, afterSeq, waitMs}` 是长轮询，
  可重放、可续读（`Apelind/Session/Tasks.swift`）。
- 落盘：`<state>/tasks/<id>.json` + `<id>.events.jsonl`（逐事件 append，再原子重写记录）。
  加载时以事件日志为准，只截断撕裂的尾行，缺最终 `state` 就补 `unreadable`，保证编号不断。
- 可恢复的只有白名单（build/setup/sdkImport/gitClone/transferExport），**最多 2 次**，
  带凭据的 URL、descriptor、agent 会话一律不恢复，直接 `interrupted`。
- App 死/respring 不影响任务：客户端只需 `taskID + afterSeq` 重连。
- 无服务端超时；超时是客户端每步自己带。

---

## 5. 诊断手法（比现有手工 ssh 强的地方）

- **marker 加载验证**：`os_log` 用 package id 作 subsystem，打
  `ApelinLoaded <buildID> in <progname>`（`%{public}`）。
  `confirmLoaded` 是**宿主进程持有的 task**（respring 也丢不掉答案），
  先开 live log 流 → 0.5s 稳定 → 触发 respring → 按
  `process == 目标可执行文件` + `messageContains == marker` 过滤（最多 20 条）。
  **实时日志在 iOS 上没有历史**，所以必须先开流再触发（`DiagnosticsService+ConfirmLoaded.swift:128-165`）。
- **不要读别的进程的 image list**：iOS 27.0.1（roothide）上读 SpringBoard 的 image list
  三次把内核打 panic（`vm_entry_lock.c:168`），两种读法都已删除，证据永远 `notRead`。
- **crash 符号化只认本地 dSYM**：按 `LC_UUID` 在 `Builds/<projectID>/` 和工程目录里索引；
  报告里写的路径一律不打开（防越权）。
- 日志降级链：mobile 用 icli 读，1s 内 0 命中视为“被拒” → 同一个请求转给 root 的
  `apelin-log-reader`（`LoggingSupport.framework` 的 `OSLogEventLiveStream`，不用 icli）。
- LaunchServices 会保留旧 build 的 Info.plist：`uicache "Unable to register"` 不一定是失败，
  用 `uicache -i <id>` 确认，并先看 `CFBundleVersion` 是否更新。

---

## 6. 对 jbb / 现有工程的即时改进项

1. 每个 build 打 `os_log(package-id, "… <buildID> …")`，respring 后回读日志确认“这个 build 真的进了目标进程”，
   替换现在“看功能有没有生效”的间接判断。
2. 保留每个 build 的 dSYM，按 UUID 索引；崩溃先 `dwarfdump --uuid` 匹配再 `atos`，
   不要用“猜 + 试”。
3. 打包后回读签名里的 entitlement、检查二进制里没有构建路径/占位符（照 `Scripts/package-deb.sh` 的做法）。
4. arm64e 产物检查 fixups（chained/threaded）；动态查找的符号全部 `-Wl,-U,_symbol`。
5. filter plist 命名/位置与 `Foo.dylib` 对齐；空 filter 视为错误。
6. 如果以后加 root helper：`DISABLE_TWEAKS=1` + fd3 通道 + 封闭 op 枚举 + exec 后复核 uid。

---

## 7. 对 SMB 插件的结论（本项目）

- Apelin 提供的能力边界：**它只让“编译/装机/看日志”在设备上完成**，
  SMB 协议、路径语义、挂载权限一件都不解决。
- 注入的 dylib **继承宿主 App 的沙箱**（`AGENTS.md:2409-2411`）：
  网络通常可用，但局域网/Bonjour 权限与 `NSBonjourServices` / `NSLocalNetworkUsageDescription`
  属于宿主 App 的 Info.plist，注入改不了 → 要么改包重签，要么先用固定 IP。
- 真挂载 = root helper（NetFS/mount_smbfs）+ 前端插件；helper 可直接抄 4.1 的骨架。
  纯 dylib 在 App 沙箱里做 mount 不可行。
- 大文件/后台同步 = 抄 4.2 的任务模型（taskID + seq + 落盘 + 有限恢复）。
- 若走用户态 SMB2（libsmb2）：baseline 里没有 pkg-config/autotools，得自己把源文件塞进
  `products[].sources` 或用 workspace 脚本；Mac 上交叉编译更省事。

---

## 8. Apelin 自身的已知边界（别当生产依赖）

- 作者实测设备只有：iPhone 15 Pro / **iOS 17.3.1** / roothide、A12Z iPad 26.0.1、
  vphone 26.4 / 26.6.2 / 27.0.1。**rootless 真机、iOS 16 物理机都没端到端跑过**（`Documents/Research/Device-Validation.md:36-37,203-209`）。
- arm64e 只验证了“编译+链接+合成 loader dlopen”，**真实注入下 arm64e 指针签名 ABI 未验证**（`Documents/Plan/Milestone-1.md:495-496`）。
- 加载验证只有 marker，不验证 hook 是否真的执行（`ApelinHook` 不在证据里）。
- 没有 xcodebuild、没有 clangd/补全/跳转、MCP 只支持 HTTP。
- 0.1.x，7 star，首个公开版本；装它还多一个 root 守护（apelind）+ Irisin 依赖。

---

## 9. 可以直接复用的代码资产

| 资产 | 路径 | 价值 |
|---|---|---|
| ldid 等价签名器 | `Packages/ApelinFormats/Sources/ApelinCodeSign/` | 纯 Swift，无外部依赖；可做 Mac 端 `apelin-sign -S ents.plist x.dylib` |
| Mach-O 解析 | `Packages/ApelinFormats/Sources/ApelinMachO/` | arch/load commands/rpath/install name/签名检查，替代手工 otool |
| 构建/打包 | `Packages/ApelinKit/Sources/ApelinBuild/`、`Packages/ApelinFormats/Sources/ApelinDeb*` | 声明式构建与 deb 写入的完整参考实现 |
| 打包校验 | `Scripts/package-deb.sh` | entitlement 回读、构建路径检查、双布局差异 |
| 设备端驱动 | `Scripts/device.py` + `Documents/Console.md` | JSONL 协议 + ssh 驱动，可照抄做回归 |
| 设计决策记录 | `AGENTS.md`（2700 行） | 每条“为什么这样写”都有据；踩坑清单 |

注意：`ApelinCodeSign` 是 MIT（含 Irisin 的 slice 处理，见其 LICENSE），复用要保留 notice。

**已落地**：`tools/machocheck/` —— 把上面那条 arm64e 指针签名规则抽成了独立构建闸门
（同时校验签名、entitlements（XML/DER）、架构、filter plist）。15 个测试全过，
用法见该目录 `README.md`。

---

## 10. 如果要在 .20/.28 上试 Apelin（验证顺序）

1. 先确认 `irisind`（Irisin ≥ 4.7.3）能装、能起；`apelind` 能被 launchd bootstrap 起来
   （`launchctl print system/wiki.qaq.apelind`）。
2. 建 tweak 模板工程 → build → install → respring → `confirmLoaded` 看到 marker。
   **这一步不通过，后面免谈**（尤其 .20 是作者没测过的 iOS 16 组合）。
3. 再检查产物：`lipo -info`（架构是否符合预期）、`codesign -d --entitlements`/签名是否存在、filter plist 路径。
4. 最后才考虑把 SMB 项目搬过去；搬之前先确认 `architectures` 已改成 `arm64+arm64e`。
