# debs-in（外部 deb 池）

`scripts/repo.py` 会把这里的 `.deb` 一起收进索引。没有源码的第三方插件放在这里，
方便重建仓库时保留。

| 包 | 版本 | 架构 | 来源 | 原始文件 |
| --- | --- | --- | --- | --- |
| `com.wkk.wfhook`（威锋NoAds） | 1.0-3 | arm64 / arm64e | <https://Wkkyy00.github.io/>（wkk's 🏠） | `debs/com.wkk.wfhook_1.0-3_iphoneos-arm64{,e}.deb` |
| `qqantirecall.x`（NTQQ_AntiRecall QQ图层） | 1.6.2 | arm64 / arm64e | <https://huayuarc.github.io/>（Huayuarc） | `debs/qqantirecall.x-1.6.2-{rootless,roothide}.deb` |

下载日期：2026-10-25。下载后已按上游 `Packages` 里的 `Size` / `SHA256` 校验。

```
d72efb04bc5437e8ccfc959ec2967b8ed6c053f0575ca5a49a0f3a7e3caccda3  com.wkk.wfhook_1.0-3_iphoneos-arm64.deb
6600687a49aa6c793541785f288186f734f3a70db584dba7e1babbfff8f4448e  com.wkk.wfhook_1.0-3_iphoneos-arm64e.deb
d3591d5e86721014333392e049d3e11e91f9a4d681cdd8dfa3ac815025254605  qqantirecall.x-1.6.2-roothide.deb
c0653e5ab4ddb50b418dcc8a7a37914406555500f38c77030e18ac6f65bd1edf  qqantirecall.x-1.6.2-rootless.deb
```

这两个包是第三方作品，版权归原作者；这里只做个人源的分发备份。
更新时重新从上游下载，覆盖同名文件后运行 `python3 scripts/repo.py`。
