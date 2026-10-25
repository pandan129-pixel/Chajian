# Pandan 插件源码

这里是 Chajian 源里几个插件对应的源码快照，和 `docs/` 里的 deb 源放在同一个仓库。

| 目录 | 包名 | 目标 App | 说明 |
| --- | --- | --- | --- |
| `jbb/` | `com.pandan.jbb` | 多 App（微信 / 支付宝 / 大麦 / 高德等） | 越狱环境检测屏蔽，含 PreferenceLoader 设置界面 |
| `xianyu-duo/` | `com.pandan.xianyuduo` | 闲鱼 | 开屏/信息流广告、我的页净化、原图/视频存图 |
| `crash-analyzer-pro/` | `com.pandan.crashanalyzerpro` | 设置 / 日志 | 日志批量删除 + DeepSeek 直连分析 |
| `amap-splash/` | `com.pandan.amapsplash` | 高德地图 | 开屏/实时广告与启动弹窗 |

## 构建

- Xcode + iPhoneOS SDK（`xcrun --sdk iphoneos --show-sdk-path`）
- 签名都是 ad-hoc（`codesign -f -s -`），装到真机由越狱环境接管
- `jbb/prefs` 的设置界面需要 **Theos + ldid**（`THEOS` 指向你的 theos 目录）
- 目标架构：roothide 用 `iphoneos-arm64e`，rootless 用 `iphoneos-arm64`

每个目录的 `README.md` 里有各自的构建、打包、安装命令。

## 设备安装脚本

`xianyu-duo/scripts/install.sh` 通过环境变量取设备信息，仓库里**不包含**任何设备密码：

```sh
DEVICE_HOST=192.168.1.10 DEVICE_PASSWORD='your-password' sh scripts/install.sh
```

## 未包含

- 第三方二进制/参考源码：WCLite、小红薯、WATrans、BHTwitter、WKK 高德原包等
- `build/`、`dist/` 等编译产物和签名后的 dylib/deb
- 部分内部 handoff 文档和设备日志

## 说明

源码只用于个人越狱环境下的学习与研究。插件会 hook 第三方 App，
使用前请自行确认目标 App 的服务条款和当地法律；不要用于绕过付费、
传播恶意功能或侵犯他人账号数据。
