# AI 日志分析 Pro

`com.pandan.crashanalyzerpro` 1.2.0-2 · arm64e · 基于 `com.mowang.crashanalyzer` 1.1.6（CrashAnalyzer 1.2.0）反编译改进。

## 做了什么

1. **批量删除日志**
   - 在「分析日志」根页和每个分类页右上角加「管理」。
   - 列表支持多选、全选/取消全选，删除前二次确认。
   - 删除 `.ips` 时同时删除同名 `.ips.synced`；只处理 CrashReporter 目录下的普通文件。
   - 删除后刷新 `CALogStore` 并广播 `CALogStoreDidRefreshNotification`。
2. **DeepSeek 直连分析**
   - 每条日志详情页右上角加「DeepSeek」。
   - 直接复用原插件的 `CAAIService`：`prepareReport:includeSource:error:` 预检 → 确认框显示模型/接口/payload 字节数 → `runPrepared:report:fresh:completion:` 发起请求。
   - 结果页支持复制、停止请求；请求中显示转圈和状态。
   - 不再需要先进「诊断工作台」再找 AI 入口。
3. **DeepSeek 默认值**
   - 默认接口 `https://api.deepseek.com/v1/chat/completions`，默认模型 `deepseek-v4.1-flash`。
   - 首次启动会把旧的 OpenAI / `deepseek-ai/DeepSeek-V4-Pro` 默认值迁移到 DeepSeek；不会覆盖用户自定义的接口。
   - 仍然可以在「AI 分析配置」里改接口、模型、Key、Prompt、是否发送完整源文件。

## 安装

产物：

| 文件 | 适用 |
| --- | --- |
| `dist/com.pandan.crashanalyzerpro_1.2.0-2_iphoneos-arm64e.deb` | roothide（`.20`） |
| `dist/com.pandan.crashanalyzerpro_1.2.0-2_iphoneos-arm64.deb` | rootless（`.28` / Relaxin） |

安装（会 `Conflicts/Replaces` 原 `com.mowang.crashanalyzer`）：

```sh
# roothide
scp dist/com.pandan.crashanalyzerpro_1.2.0-2_iphoneos-arm64e.deb mobile@DEVICE_IP:/var/mobile/
ssh mobile@DEVICE_IP 'sudo dpkg -i /var/mobile/com.pandan.crashanalyzerpro_1.2.0-2_iphoneos-arm64e.deb'

# rootless
scp dist/com.pandan.crashanalyzerpro_1.2.0-2_iphoneos-arm64.deb mobile@DEVICE_IP:/var/mobile/
ssh mobile@DEVICE_IP 'sudo dpkg -i /var/mobile/com.pandan.crashanalyzerpro_1.2.0-2_iphoneos-arm64.deb'
```

装完杀掉 Settings 再打开（`killall -9 Preferences; uiopen -b com.apple.Preferences`）。

卸载：

```sh
sudo dpkg -r com.pandan.crashanalyzerpro
```

## 使用

- 设置 → 分析日志 → 右上角「管理」→ 勾选 → 「删除」。
- 设置 → 分析日志 → 任一分类 → 点一条日志 → 右上角「DeepSeek」。
- 首次使用先在「AI 分析配置」填 API Key（只保存在本机 NSUserDefaults）。

DeepSeek 配置示例：

| 项 | 值 |
| --- | --- |
| 接口地址 | `https://api.deepseek.com/v1/chat/completions` |
| 模型 | `deepseek-v4.1-flash`（或 `deepseek-chat` / `deepseek-reasoner`） |
| API Key | 你的 key |
| 发送完整源文件 | 默认关闭；开启后才发 `.ips` 原文 |

接口地址也支持只填 `https://api.deepseek.com` 或 `https://api.deepseek.com/v1`，原插件会自动补 `/chat/completions`。

> 注意：原插件的 `request:body:` 只允许 HTTPS，且不允许 URL 里带用户名/密码/查询参数/片段。如果「我们的 DeepSeek」是内网 HTTP 网关，需要再改这一处（见 `docs/REVERSE-NOTES.md`）。

## 图标

`packaging/icons/` 下是新图标（深色玻璃日志卡片 + 青色 AI 星芒），
`pack-deb.py` 会把 `icon.png` / `icon@2x.png` / `icon@3x.png` 覆盖进
`CrashAnalyzerPrefs.bundle`，替换原作者的头像。

## 构建

```sh
./scripts/build.sh          # build/CrashAnalyzerPro.dylib (arm64 + arm64e)
python3 scripts/pack-deb.py # dist/*.deb
```

`pack-deb.py` 会：

1. 从 `vendor/com.mowang.crashanalyzer-1.1.6-roothide.deb` 解出原 PreferenceBundle；
2. 把 `CrashAnalyzerPro.dylib` 安装到 `/usr/lib/TweakInject/`；
3. 给 bundle 主二进制加 `LC_LOAD_DYLIB /usr/lib/TweakInject/CrashAnalyzerPro.dylib`；
4. 在 bundle 外签名（`ldid -S`），保持 `Sealed Resources=none`，避免资源签名失效；
5. 打包 deb。

## 当前验证状态

- 二进制/打包/签名静态检查通过；roothide + rootless 两个 deb 都已生成。
- `.20`（14 Pro / 16.3.1 / roothide 3.x）已安装 1.2.0-2。
- 用 Frida（`DEVICE_IP:27042`）现场确认：
  - `CrashAnalyzerPro.dylib` 已加载，`CAPRootListController` / `CAReportViewController` / `CAReportDetailController` / `CAAIService` 等类都在；
  - 三个 hook 都已安装（`ca_openBatchDelete:` × 2、`ca_deepSeek:`）；
  - 根页导航栏已出现「管理」；
  - 默认模型已是 `deepseek-v4.1-flash`。
- 批量删除已用 Frida 实际打开验证：列表 2 条（`userspace-panic-*.ips`、`launchd-*.ips`），
  点「全选」后按钮变成「删除 (2)」。
- 还差手动点一遍「删除」确认和详情页「DeepSeek」（DeepSeek 需要先填 API Key）。

### 解析失败的日志（launchd / userspace-panic）

像 `userspace-panic-*.ips` 这种 **纯文本 panic 日志**，原插件解析器会返回
`bug_type: unknown`，默认 `structured` 范围只发送
`{"bug_type":"unknown","faultEvidence":[...]}`，DeepSeek 只能回答“文件不完整”。

本次改进：

- 点「DeepSeek」时，如果 report 带 `parseError` 或 `bug_type` 为 `unknown`，
  **自动改为发送完整源文件**（确认框会提示），AI 才能读到 panic 正文；
- `CAWorkbench payload:` 的 `max_tokens` 从 2048 提到 **8192**，
  避免 `deepseek-flash` 把预算全花在 `reasoning_content` 上、`content` 为空。

### 1.2.0-2 修复记录

- 批量删除扫描时，item 原本是不可变 `NSDictionary`，后面给 `category` 赋值
  `item[@"category"] = cat` 会走 `setObject:forKeyedSubscript:`，直接
  `unrecognized selector` 闪退。已改为 `mutableCopy`。
- 同时把按钮补齐改成：hook 安装后遍历当前 VC 层级补按钮，避免
  dylib 晚于 `viewDidLoad` 加载时首屏没有「管理」。

详见 `HANDOFF.md` 和 `docs/REVERSE-NOTES.md`。
