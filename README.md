# Pandan 自用插件源

源地址：<https://pandan129-pixel.github.io/Chajian/>

插件源码：`sources/`（jbb / 闲鱼助手+存图 / AI 日志分析 / 高德 NoAds）

把 `plugins/*/dist`、`jbb/dist`、`jb-bypass/dist`、`debs-in/` 里的 `.deb`
汇总成一个 Sileo / Cydia 可直接添加的 apt 源。模仿的是 opa334、roothide 这种
**GitHub Pages 平铺源**（`Suites: ./`）的做法，不依赖 reprepro 或数据库。

## 1. 插件源的本质

一个源就是一个静态 HTTP 目录，越狱端的 apt 只会拉这几样东西：

```
<源地址>/Release              源元信息（域名、架构、索引校验和）
<源地址>/Packages             所有 deb 的 control 信息 + 文件路径 + 大小 + 哈希
<源地址>/Packages.gz / .bz2 / .xz   上面文件的压缩版（apt 优先下压缩版）
<源地址>/debs/xxx.deb         真正的安装包
<源地址>/CydiaIcon.png        源图标（可选，但 Sileo 喜欢）
```

`Packages` 就是一个个 deb 的 control 段落拼接，最后补上：

```
Filename: ./debs/com.pandan.jbb_6.22.7_iphoneos-arm64e.deb
Size: 1234567
MD5sum: ...
SHA1: ...
SHA256: ...
```

`Release` 里再记录每个索引文件的哈希和大小。Sileo 添加源时先取 `Release`，
再按架构取 `Packages.gz`，所以只要这三个文件和 deb 对得上，源就能用。

两种布局：

| 布局 | 源条目的写法 | 目录 |
| --- | --- | --- |
| 平铺（本仓库，opa334/roothide 同款） | `Suites: ./` | 所有文件在根目录 |
| 标准 dists（Havoc 等大源） | `Suites: stable` | `dists/stable/main/binary-iphoneos-arm64/Packages` |

自用源没必要上 `dists`，平铺最简单。

## 2. 目录结构

```
repo/
├── repo.conf                 源名、架构、扫描路径、公网 base_url
├── scripts/repo.py           生成索引（本仓库核心）
├── scripts/serve.sh          局域网测试服务器
├── docs/                     生成结果，也是 GitHub Pages 的发布目录
│   ├── Packages / *.gz / *.bz2 / *.xz
│   ├── Release
│   ├── CydiaIcon.png
│   ├── index.html            给浏览器看的落地页
│   ├── icons/                可选，单包图标 <包名>.png
│   └── debs/
└── README.md
```

## 3. 生成 & 本机测试

```sh
cd /Users/dan/Desktop/iphone/repo

# 生成：默认每个包 × 每个架构只保留最新版本
python3 scripts/repo.py

# 想留历史版本（源会明显变大）
python3 scripts/repo.py --keep-all
```

脚本会做这些事：

- 扫描 `../plugins/*/dist`、`../jbb/dist`、`../jb-bypass/dist`、`debs-in/`
- 从 deb 的 `control.tar.*` 里读 `Package / Version / Architecture`（不依赖 `dpkg-deb`）
- 按 dpkg 版本规则比较大小，只留最新版
- 把 deb 复制到 `docs/debs/`，自动算出 MD5/SHA1/SHA256/Size 写进索引
- 生成 `Release`（含索引哈希）、三种压缩索引、`index.html`、`CydiaIcon.png`
- 清掉 `docs/debs/` 里已经不用的旧 deb（`--no-prune` 可关闭）

默认会把扫描到的第三方包（如 `com.bandarhl.bhtwitter`）也收进去。
`repo.conf` 里已经预置了排除名单：

```
exclude_packages = com.bandarhl.bhtwitter com.pandan.xianyu322
```

当前收录：`jbb`、`闲鱼助手+存图`、`AI 日志分析 Pro`、`高德 NoAds`、
`WCLite`、`小红薯(去公告)`、`WATrans`。其中后三个是放在 `debs-in/`
里的现成 deb，构建其他项目时不会丢。

局域网测试：

```sh
sh scripts/serve.sh 8080
# 输出类似：
# 手机: http://192.168.1.23:8080/
```

手机和 Mac 连同一个 Wi-Fi，在 Sileo 里添加 `http://192.168.1.23:8080/`。
第一次可能提示"不安全的源/未签名"，允许即可（自用源没必要签名）。

> macOS 防火墙如果拦了 8080，去「系统设置 → 网络 → 防火墙」放行 python3。
> 也可以用 `http://<Mac 的 .local 名>:8080/`，但 IP 更稳。

## 4. 发布到 GitHub Pages

`docs/` 就是最终要发布的目录，所以用 GitHub 的
「Deploy from a branch → main → /docs」最省事，不需要 Actions。

```sh
cd /Users/dan/Desktop/iphone/repo
git init
git add .
git commit -m "pandan repo: initial"
git branch -M main
git remote add origin git@github.com:<你的用户名>/<仓库名>.git
git push -u origin main
```

然后网页上操作：

1. 仓库 **Settings → Pages**
2. Source 选 **Deploy from a branch**
3. Branch 选 **main**，目录选 **/docs**，保存
4. 等 1–2 分钟，地址是 `https://<用户名>.github.io/<仓库名>/`

最后把 `repo.conf` 里的

```
base_url = https://<用户名>.github.io/<仓库名>
```

填上再跑一次 `python3 scripts/repo.py` 并提交。这一步只影响落地页和
单包 `Icon:` 字段，不影响 apt 能不能装。

> 免费账号的 Pages 要求仓库是 public。私有仓库要 Pro/Team 才有 Pages。
> 不想公开源码就只放 `docs/` 也行：单独建一个 public 仓库，只提交 `docs/` 内容。

> 想用「仓库根目录就是源」的布局（很多教程的写法）：把生成命令改成
> `python3 scripts/repo.py --out .`，Pages 目录选 `/(root)`。两种布局对
> Sileo 完全等价，`docs/` 只是把索引和脚本分开放，干净一点。

国内访问 GitHub Pages 慢的话，`docs/` 整目录原样传到 Cloudflare Pages
（Framework preset 选 None，输出目录 `docs`）或用自己域名反代即可，
目录结构完全不用改。

## 5. 在 Sileo 里添加

- roothide 设备：直接添加 `https://<用户名>.github.io/<仓库名>/`
- rootless 设备（Dopamine 等）：同一个源也能用，索引里同时声明了
  `iphoneos-arm64` 和 `iphoneos-arm64e`，Sileo 会按设备架构过滤

添加后下拉刷新，插件会出现在「分类 / 全部」里。装完如果没生效，
先 respring；PreferenceLoader 的设置项要等一次 respring 才出现。

## 6. 日常发版流程

```sh
cd /Users/dan/Desktop/iphone
sh jbb/scripts/pack-deb.sh iphoneos-arm64e      # 或你的插件构建脚本

cd repo
python3 scripts/repo.py                          # 重新生成索引
git add docs
git commit -m "jbb 6.22.8"
git push
```

推送后 Pages 会自动重新发布。设备端 Sileo 下拉刷新就能看到新版本；
如果还是旧的，检查：

- `Version:` 是否真的比已装版本大（dpkg 版本比较很严格）
- Pages 是否部署完成（仓库 Actions/Pages 页看最后一次部署）
- Sileo 是否有缓存（换源地址加个 `?v=2` 不推荐，直接等一两分钟或重开 Sileo）

### 可选：GitHub Actions 自动重建索引

仓库里已经带了 `.github/workflows/update-index.yml`。它只在
`docs/debs/**` 变化时触发，用 `repo.py --source docs/debs` 重建索引并提交。
前提是 deb 本身已经提交进仓库（Actions 不负责编译插件）。

首次使用确认 **Settings → Actions → General → Workflow permissions**
允许 read and write（workflow 文件里已经声明 `permissions: contents: write`）。

## 7. 版本与架构规则（最容易踩）

1. **版本号必须递增**，`1.0.10 > 1.0.9`，`1.0.10-1 > 1.0.10`。
   直接用构建时间做版本也可以，但别回退。
2. **Architecture 必须和设备匹配**：
   - roothide 3.x：`iphoneos-arm64e`
   - rootless（Dopamine/unc0ver 等）：`iphoneos-arm64`
   - 老 checkra1n 设备：`iphoneos-arm`
   一个包同时发两个架构时，两个 deb 的 `Package` / `Version` 要一致，
   只有 `Architecture` 不同，索引里会并列两条，Sileo 自动挑对的。
3. 依赖写清楚（`mobilesubstrate`、`preferenceloader`、`firmware (>= 15.0)`），
   否则装完不加载会被当成"插件没效果"。
4. `Name:` 用中文没问题，`Package:` 保持反向域名小写。
5. 别把别人重打包的付费/闭源插件放进公开源（比如 BHTwitter 这类），
   自用局域网源无所谓，公开前先确认授权。脚本不会替你判断。

## 8. 常见问题

**Sileo 提示 "Failed to fetch / 未能获取"**
先浏览器打开源地址看 `Packages` 是否能下载；404 多半是 Pages 没部署好，
或者 `Filename` 路径大小写和实际文件不一致。

**源里能看到包，但点安装提示找不到文件**
`docs/debs/` 里的 deb 被 `--no-prune` 之外的操作删了，或者手动改名了。
重新跑 `python3 scripts/repo.py` 让索引和文件对齐。

**装了旧版本，刷新也不提示更新**
设备上 `dpkg -l | grep com.pandan` 看实际版本；确认新 deb 的 `Version`
更大，且架构和设备的 `uname -m`/越狱类型一致。

**GitHub Pages 单文件 100 MB / 仓库 1 GB 限制**
默认只留最新版一般只有几十 MB。真的很大就把 deb 放 release 附件或
对象存储，`Filename:` 写绝对 URL（apt 支持 `Filename: https://...`）。

**想给源签名**
自用不需要。要签名就在生成后：

```sh
gpg --default-key <KEYID> --clearsign -o docs/InRelease docs/Release
```

并把公钥给设备导入。注意：一旦存在 `InRelease`，apt 会强制校验，
签名或密钥不对会直接导致整个源不可用。不确定就先别加。

**添加 `SileoDepiction` / 截图**
在包的 control 里加 `SileoDepiction: https://.../depiction.json`，
或在 `repo.conf` 生成后手动补到 `docs/Packages`（不推荐，会被覆盖）。
更省事的做法是直接给包加 `Icon:` 和 `Depiction:`，脚本会原样保留
control 里的这两个字段。

## 9. 和现成工具的关系

- `reprepro`（`brew install reprepro`）：功能全，会生成 `dists/` + pool，
  适合几十个包、多 suite、要签名的场景；本脚本胜在零依赖、直接产平铺源。
- `dpkg-scanpackages`：Linux 上的经典做法，macOS 默认没有；
  本脚本的 control 解析就是它的最小替代。
- 不要用 XRepo/AptRepo 这类在线生成器做长期源：它们通常要求把 deb 传给它，
  版本历史、域名和可用性都不在自己手里。

改完 `repo.conf` 随时重跑 `python3 scripts/repo.py`，`docs/` 就是完整可发布的源。
