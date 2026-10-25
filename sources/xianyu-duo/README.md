# 闲鱼助手 + 存图（融合版）

单 dylib、纯 ObjC、无 Logos、无 SQLite、无常驻定时器。目标 `com.taobao.fleamarket`，
按 Apelin 的约束构建（clang → link → sign 最后一步）。

- 去广告：开屏/热启动、信息流广告 cell、我的页营销位（保守规则）
- 入口：我的页“存图设置”胶囊 + 详情页悬浮球
- 存图：原图 / 视频收集，面板选择，一键写入相册；MTOP 原图列表 + 已解码字节两条来源
- 适配：闲鱼 7.28.70（类名/方法已在真机二进制中核对，见 `docs/RE-COMPARE.md` §7）
- 设置：面板内“设置”页，或长按悬浮球

> 逆向对比报告见 [`docs/RE-COMPARE.md`](docs/RE-COMPARE.md)。

## 构建

```sh
cd plugins/xianyu-duo
./scripts/build.sh          # build/XianyuDuo.dylib (arm64 + arm64e)
python3 scripts/pack-deb.py # dist/com.pandan.xianyuduo_1.0.6_iphoneos-arm64e.deb
```

要求：Xcode + iPhoneOS SDK（`xcrun --sdk iphoneos --show-sdk-path`）。
签名是构建脚本最后一步，签名后不要再改文件。

## 安装（roothide）

```sh
scp dist/com.pandan.xianyuduo_1.0.6_iphoneos-arm64e.deb mobile@<device>:/var/mobile/
ssh mobile@<device> 'dpkg -i /var/mobile/com.pandan.xianyuduo_1.0.6_iphoneos-arm64e.deb; killall -9 SpringBoard'
```

文件安装到 `/var/jb/usr/lib/TweakInject/`：

```
XianyuDuo.dylib
XianyuDuo.plist   # Filter: com.taobao.fleamarket
```

卸载：

```sh
ssh mobile@<device> 'dpkg -r com.pandan.xianyuduo; killall -9 SpringBoard'
```

## 使用

1. 打开闲鱼；进入任意商品详情页，右侧出现悬浮球。
2. 点悬浮球 → 面板：媒体网格 / 全选 / 保存。
3. 长按悬浮球 → 设置；或在“我的”页点“存图设置”。
4. 设置 → 诊断信息：可查看各 hook 目标是否存在、命中的信息流 cell 类、MTOP token 与相册权限。
5. 设置项：
   - 拦截开屏/热启动广告
   - 隐藏信息流广告
   - 我的页净化
   - 自动收集图片（阈值：最小 KB / 最小边长）
   - 收集视频地址
   - 详情页悬浮球 / 我的页入口
   - 调试日志

## 调试

调试开关打开后，日志在 App 沙盒：

```
<闲鱼容器>/tmp/xianyuduo.log
```

可用 `ls -t /var/mobile/Containers/Data/Application/*/tmp/xianyuduo.log` 找到。
日志会记录每个 hook 是否命中（类/方法不存在会明确写 `not found`）。

## 目录

```
src/XYDCommon.h      公共声明
src/XYDPrefs.m       CFPreferences、hook 助手、URL/ID 解析
src/XYDAdBlock.m     开屏/热启动/信息流/我的页
src/XYDMedia.m       媒体模型、采集 hook、详情页上下文
src/XYDItemAPI.m     MTOP H5 请求与 JSON 解析
src/XYDSaver.m       Photos 写入
src/XYDPanel.m       面板/设置/缩略图
src/XYDEntry.m       悬浮球、我的页入口
src/XYDMain.m        构造函数
```

## 限制

- 不含 3.2.2 的自动发货/评分/IM 自动回复/邀请。
- 我的页净化为保守识别（广告类名 + “广告/赞助”文案），可能漏行。
- MTOP 接口需要闲鱼已登录；无票据时只显示已捕获媒体。
