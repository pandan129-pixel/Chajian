# 逆向笔记：CrashAnalyzer 1.2.0 → AI 日志分析 Pro

原包：`com.mowang.crashanalyzer` 1.1.6（Huayuarc 源）
- 包内 PreferenceBundle：`CrashAnalyzerPrefs.bundle`
- `Info.plist` 版本：`CFBundleShortVersionString 1.2.0`，`CFBundleVersion 14`
- 主二进制：thin arm64e，`LC_BUILD_VERSION minos 15.0 sdk 17.5`
- 原 deb：`vendor/com.mowang.crashanalyzer-1.1.6-roothide.deb`
  - SHA256 `ad9658097107da222d1eb4fab92b59fbd6f5950429f798a696ffb7544d471f62`

## 1. 类与方法（节选）

| 类 | 作用 |
| --- | --- |
| `CAPRootListController` | 根列表（崩溃/内存/重启/资源/其他、工具与设置） |
| `CAReportViewController` + 5 个子类 | 分类日志列表，数据来自 `[[CALogStore sharedStore] reportsForCategory:]` |
| `CAReportDetailController` | 单条日志详情，ivar `_report` 为字典；`analyzeWithAI:` 实际是 push `CAWorkbenchController` |
| `CALogStore` | 扫描 `/var/mobile/Library/Logs/CrashReporter`、解析 `.ips`、分类、缓存、本地诊断 |
| `CAAIConfigController` | AI 配置 UI；Key：`CAAIEndpoint`、`CAAIMode`（模型）、`CAAIKey`、`CAAIPrompt`、`CAAIIncludeSource` |
| `CAAIService` | OpenAI 兼容请求；`+shared`、`prepareReport:includeSource:error:`、`runPrepared:report:fresh:completion:` |
| `CAWorkbench` | payload 组装、响应解析、历史/案例写入 |
| `CACaseStore` | 本地案例库（`Library/Preferences/CrashAnalyzer/Cases`） |

关键点：

- `-[CAAIService analyzeReport:includeSource:completion:]`（0xecfc）**只是一个错误桩**，直接回调
  “请使用诊断工作台预检并确认请求。”，不会发网络请求。
- 真正流程：
  1. `-prepareReport:includeSource:error:`（0xe02c）
     - 读 `CAAIMode` / `CAAIEndpoint` / `CAAIPrompt`
     - 归一化 endpoint（0xe398）：去空白、去尾部 `/`；已以 `/chat/completions` 结尾则原样；
       以 `/v1` 结尾则补 `/chat/completions`；否则补 `/v1/chat/completions`
     - `CAWorkbench payload:source:model:prompt:` 组 JSON
     - 校验 JSON ≤ 900000 字节；完整源文件 ≤ 640039 字节且必须是 UTF-8
     - 返回 `{data, bytes, key, model, endpoint, scope}`
  2. `-runPrepared:report:fresh:completion:`（0xe50c）
     - 先查 `ai-history-v1.json` 精确缓存（`fresh=NO` 时）
     - `-request:body:` 建请求：只允许 HTTPS、host 非空、无 user/password/query/fragment
     - Header：`Authorization: Bearer <CAAIKey>`、`Content-Type: application/json`
     - 完成后 `CAWorkbench responseText:status:error:` 解析 `choices[0].message.content`
     - 写历史、案例库，回调 `(NSString *text, NSError *error)`
- Payload 结构（`CAWorkbench payload:source:model:prompt:`）：
  ```json
  {
    "model": "...",
    "messages": [
      {"role": "system", "content": "..."},
      {"role": "user", "content": "..."}
    ],
    "temperature": ...,
    "max_tokens": ...
  }
  ```
  没有 `response_format` / `json_schema`，DeepSeek 直接兼容。

## 2. 本次改动

### 2.1 批量删除

新增 `CABatchDeleteController`（dylib 内）：

- 扫描 `/var/mobile/Library/Logs/CrashReporter`，匹配 `.ips` / `.ips.synced`；
- 用 `CALogStore reports` 的 `path → category` 映射显示分类；
- 多选 + 全选，删除前 `UIAlertController` 二次确认；
- 删除 `.ips` 时同时删同名 `.ips.synced`（反之亦然）；
- 删除后 `[CALogStore refreshReports]` + 广播 `CALogStoreDidRefreshNotification`。

Hook 点：

- `CAPRootListController`：`viewDidLoad` / `viewWillAppear:` → 右上角「管理」
- `CAReportViewController`：同上，带 `reportCategory` 过滤
- 用 `class_replaceMethod` 保存原 IMP，先调用原实现再补按钮，避免破坏原逻辑。

### 2.2 DeepSeek 直连

- `CAReportDetailController` 的 `viewDidLoad` / `viewWillAppear:` 加「DeepSeek」按钮。
- 点击后：
  1. KVC 取 `_report`；
  2. 读 `CAAIKey` / `CAAIEndpoint` / `CAAIMode` / `CAAIIncludeSource`；
  3. 调 `prepareReport:includeSource:error:`；
  4. 确认框显示模型、host、范围、payload 字节数；
  5. push `CADeepSeekResultController`，调 `runPrepared:report:fresh:completion:`；
  6. 结果页支持复制、停止（`cancelAnalysis`）。

### 2.3 DeepSeek 默认值

`CAInstallDeepSeekDefaults()` 在 dylib 构造时：

- `registerDefaults`：`CAAIEndpoint`、`CAAIMode`、`CAAIPrompt`、`CAAIIncludeSource`
- 只在旧值精确等于原默认值时迁移：
  - `https://api.openai.com/v1/chat/completions` → `https://api.deepseek.com/v1/chat/completions`
  - `deepseek-ai/DeepSeek-V4-Pro` / `deepseek-chat` → `deepseek-v4.1-flash`（默认）

## 3. 注入方式

原包只有 PreferenceBundle，没有 dylib。本次采用**双路径**：

1. 把 `CrashAnalyzerPro.dylib` 安装到 `/usr/lib/TweakInject/CrashAnalyzerPro.dylib`；
2. 给 bundle 主二进制加 `LC_LOAD_DYLIB /usr/lib/TweakInject/CrashAnalyzerPro.dylib`；
3. 同时安装 `/usr/lib/TweakInject/CrashAnalyzerPro.plist`（Filter → `com.apple.Preferences`）。

这样：

- Settings 的 TweakInject 正常时：dylib 在 Settings 启动时加载；
- TweakInject 不注入 Settings、但 PreferenceLoader 正常时：bundle 加载时由 `LC_LOAD_DYLIB` 加载；
- 两条路径使用**同一个绝对路径**，dyld 会按路径去重，不会重复 hook。

签名：

- 原 bundle 没有 `_CodeSignature`，主二进制是 ad-hoc、`Sealed Resources=none`；
- 本次在 **bundle 外**用 `ldid -S` 签名，保持 `Sealed Resources=none`，再放回 bundle；
- dylib 同样在 bundle 外签名。

## 4. 设备验证记录（.20）

- 已安装 `com.pandan.crashanalyzerpro 1.2.0-1`。
- 最小测试 tweak（Filter → `com.apple.Preferences`）和最小测试 PreferenceBundle 在 Settings 中**都不加载**；
  同一个最小 tweak 在闲鱼（`com.taobao.fleamarket`）中正常加载。
- 结论：`.20` 当前的 Settings 系统插件注入状态异常（不是本包代码问题）。
  需要 respring / 重建系统插件注入 / 重新越狱后再验证 UI。
- 测试用的临时 tweak / 测试 bundle / 检查工具已从设备移除，只保留本包。

## 5. 后续可改

- 若「我们的 DeepSeek」是内网 HTTP 网关：放宽 `-[CAAIService request:body:]` 的 HTTPS 限制，或加一个“允许 HTTP”开关。
- 若需要批量删除时同时清分析缓存：在删除前用 `fingerprintForReport:` 计算 fingerprint，再删 `Library/Preferences/CrashAnalyzer/AnalysisCache/<fp>.json`。
- 若要支持“全选后删除所有分类”，可在根页直接打开 `CABatchDeleteController`（当前已支持，category=nil）。
