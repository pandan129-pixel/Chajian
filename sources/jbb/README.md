# JBB — 越狱检测绕过（tweak + 设置界面）

适用于 roothide 系越狱（Dopamine 3.x / Relaxin）的 App 级越狱检测绕过插件。
当前版本 **6.16**，产物是一个 deb：tweak + 设置界面 + 注入名单。

## 快速开始

```sh
# 1) 构建 dylib（arm64 + arm64e）
sh scripts/build-jbb.sh                 # -> build/jbb.dylib

# 2) 构建设置界面（需要 Theos + ldid）
sh scripts/build-prefs.sh

# 3) 打包（一个 deb 含全部）
sh scripts/pack-deb.sh iphoneos-arm64e  # -> dist/com.pandan.jbb_6.16_*.deb
```

安装 / 卸载：

```sh
dpkg -i com.pandan.jbb_6.16_iphoneos-arm64e.deb
dpkg -r com.pandan.jbb
```

配置：`/var/mobile/Library/Preferences/com.pandan.jbb.plist`
（设置 → JBB 检测绕过；改完杀掉目标 App 重开才生效）

## 目录

```
src/          jbb 源码（jbb_v616.c 为当前；v610/613/614/615/69 为历史对照）
prefs/        设置界面源码（Theos bundle，PreferenceLoader）
packaging/    注入名单 jbb.plist（91 个 App）
scripts/      build-jbb / build-prefs / pack-deb
tests/        探针与基准（jbtest9 / jbprobe / jbbcost / jbbtokens / jbbench）
tools/        remotemods（读目标进程 image list）
docs/         S15 / S16 / S17 交接，ref/（Apelin 规则），rd-research/（roothide 分析）
references/   Choicy 源码（门禁设计参考）
dist/         已打好的 deb
```

## 必读

- `docs/S17-2026-10-25-handoff-jbb616.md` —— 源码/构建/打包/验证/检测结果/性能/教训
- `docs/S16-...-choicy.md` —— 性能优化过程与基准方法
- `docs/ref/apelin-tweak-rules-handoff-2026-10-25.md` —— R1–R18 工程规则
- `references/choicy/` —— 上游 `opa334/Choicy` 源码

## 关键约束（踩过的坑）

1. **必须 arm64 + arm64e**：App Store 的 App 是 arm64 进程，单 arm64e 注入不进去。
2. **签名最后一步**：`codesign` 之后不要再改文件。
3. **设置入口 plist 必须 binary + `isController=true` + icon**，否则 Settings 不显示。
4. **`jbctl` / `opainject` 要传 jbroot 前缀的真实路径**（roothide），传 `/var/jb/...` 会被 vroot 重定向。
5. **不要走 basebin 集成**：全量 rebind 会改到 dyld/shared cache 的符号指针，App 大面积闪退。
6. **配置文件在进程启动时读取**，改完要重启目标 App。
