# 交接：AI 日志分析 Pro（com.pandan.crashanalyzerpro 1.2.0-1）

日期：2026-10-26
目标设备：`.20` iPhone 14 Pro / iOS 16.3.1 / roothide 3.x（arm64e）
产物：`dist/com.pandan.crashanalyzerpro_1.2.0-2_iphoneos-arm64e.deb`
原包：`vendor/com.mowang.crashanalyzer-1.1.6-roothide.deb`

## 1. 当前状态

- 代码、构建、打包、签名完成；roothide + rootless 两个 deb 已生成。
- `.20` 已安装 1.2.0-2（`dpkg -l` 可见），原 `com.mowang.crashanalyzer` 被 `Conflicts/Replaces` 替换。
- Frida 现场确认（`DEVICE_IP:27042`）：
  - `CrashAnalyzerPro.dylib` 已加载；`CAPRootListController` / `CAReportViewController` /
    `CAReportDetailController` / `CAAIConfigController` / `CAAIService` / `CABatchDeleteController` /
    `CADeepSeekResultController` 都存在；
  - 三个 hook 都已安装：`ca_openBatchDelete:`（root/report）、`ca_deepSeek:`（detail）；
  - 根页导航栏已出现「管理」；
  - `NSUserDefaults` 默认值：endpoint `https://api.deepseek.com/v1/chat/completions`，
    model `deepseek-v4.1-flash`，prompt 已写入。
- 批量删除已实际打开验证：列表 2 条（`userspace-panic-*.ips`、`launchd-*.ips`），
  「全选」后按钮变为「删除 (2)」。
- 还差手动点一遍「删除」确认和详情页「DeepSeek」（DeepSeek 需要先填 API Key）。

### DeepSeek / panic 日志改进（1.2.0-2）

- 用用户的 `deepseek-flash` + 官方 endpoint 实测：
  - 对 `userspace-panic-*.ips`，默认 structured payload 只有 364 字节：
    `{"bug_type":"unknown","faultEvidence":["无可解析的结构化证据…"]}`；
  - 打开完整源文件后 payload 1492 字节，DeepSeek 能给出完整分析
    （SpringBoard 180s 未 check-in、SIGNAL 11、Dopamine 阻止 panic 并 userspace reboot）。
- 改进：
  1. report 有 `parseError` / `bug_type=unknown` 时自动 `includeSource=YES`；
  2. `CAWorkbench payload:` 的 `max_tokens` 2048 → 8192，避免
     `deepseek-flash` 的 reasoning 吃掉全部预算导致 `content` 为空。

### 闪退修复（1.2.0-2）

用户点「管理」直接闪退，根因：

- `scanItems` 里 `[items addObject:@{...}]` 是不可变 `NSDictionary`；
- 后面 `item[@"category"] = cat` 对不可变字典调用 `setObject:forKeyedSubscript:`，
  抛 `unrecognized selector`，进程被终止。
- 已改为 `[@ {...} mutableCopy]`。

同时修复首屏按钮：dylib 加载/安装 hook 可能晚于 `CAPRootListController` 的
`viewDidLoad`，现在 hook 安装后会遍历当前 VC 层级补「管理 / DeepSeek」按钮。

## 2. 下一步（按顺序）

1. **恢复 Settings 的系统插件注入**
   - 先用 RootHide / Dopamine 的方式做一次真正的 respring / 重建；
   - 如果还是不行，重新越狱（或重启后重新越狱）。
   - 验证方法：打开设置，确认原来的第三方插件面板（JBBPrefs、CallAssistSetting 等）是否恢复。
2. 打开 设置 → 分析日志：
   - 根页右上角应有「管理」；
   - 任一分类页右上角应有「管理」；
   - 日志详情页右上角应有「DeepSeek」。
3. 配 DeepSeek：
   - 设置 → 分析日志 → AI 分析配置；
   - 接口：`https://api.deepseek.com/v1/chat/completions`（或只填 `https://api.deepseek.com`）
   - 模型：`deepseek-v4.1-flash`（默认；也可改 `deepseek-chat` / `deepseek-reasoner`）
   - Key：用户自己的 key（设备上还没填）。
4. 验证批量删除：
   - 根页「管理」→ 全选 → 删除 → 确认；
   - 看 CrashReporter 目录 `.ips` / `.ips.synced` 是否同时消失，列表是否刷新。
5. 验证 DeepSeek：
   - 详情页「DeepSeek」→ 确认框显示模型/host/范围/字节数 → 开始分析；
   - 结果页应显示 `choices[0].message.content`；失败时显示 HTTP/解析错误。
6. 如果 Settings 恢复后仍看不到「分析日志」：
   - 检查 `/Library/PreferenceBundles/CrashAnalyzerPrefs.bundle/CrashAnalyzerPrefs` 是否存在；
   - 检查 `/usr/lib/TweakInject/CrashAnalyzerPro.dylib` 是否存在；
   - 用 `otool -l` 确认 bundle 主二进制有 `LC_LOAD_DYLIB /usr/lib/TweakInject/CrashAnalyzerPro.dylib`；
   - 检查 dylib 构造函数日志：`/var/mobile/Library/Preferences/CrashAnalyzerPro.log`
     或 Settings 容器 `tmp/CrashAnalyzerPro.log`。

## 3. 关键文件

```
src/CrashAnalyzerPro.m           dylib 源码（批量删除 + DeepSeek + 默认值 + hook）
scripts/build.sh                 编译 arm64+arm64e，codesign
scripts/pack-deb.py              解原包、注入 LC_LOAD_DYLIB、bundle 外 ldid 签名、打包
scripts/inject_dylib.py          独立 Mach-O LC_LOAD_DYLIB 注入器（调试用）
packaging/control                deb 元数据
packaging/CrashAnalyzerPro.plist TweakInject Filter（com.apple.Preferences）
vendor/                          原 deb（1.1.6 roothide）
docs/REVERSE-NOTES.md            逆向与实现细节
```

## 4. 已知限制

1. 原 `CAAIService` 只允许 HTTPS，且不允许 URL 带 user/password/query/fragment；内网 HTTP 网关需要改这一处。
2. DeepSeek Key 仍沿用原插件的 NSUserDefaults 存储（`CAAIKey`），不是 Keychain。
3. 批量删除只删 `.ips` / `.ips.synced`，不删案例库、AI 历史、分析缓存。
4. `Conflicts/Replaces com.mowang.crashanalyzer`：安装本包会移除原包；回滚需重装原 deb。
5. 本包按 root 路径（`/Library`、`/usr/lib/TweakInject`）打包，和 `xianyu-duo` 一致；`.28`（Relaxin）按同样路径安装。

## 5. 回滚

```sh
sudo dpkg -r com.pandan.crashanalyzerpro
sudo dpkg -i vendor/com.mowang.crashanalyzer-1.1.6-roothide.deb
# respring
```
