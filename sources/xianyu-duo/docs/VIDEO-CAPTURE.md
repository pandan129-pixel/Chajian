# 视频（商品主图视频）抓取记录

## 结论

商品视频真实地址不在 `mtop.taobao.idle.item.info` 的返回里，也不在
`mtop.idle.cloud.video.query`（该接口对这类商品固定返回
`FAIL_BIZ_VIDEO_CONTENT_EMPTY`）。

App 进入详情页后，原生播放器会通过

```
+[AVURLAsset URLAssetWithURL:options:]
```

预加载视频，URL 形如：

```
https://video.goofish.com/<hash>/<hash>/<date>_<hash>_published_mp4_265_fs_0_xianyu_taobao.mp4
  ?auth_key=...&biz=...&e=hd_265&b=xianyu&p=xianyu_app_xianyu&...
```

`auth_key` 有效期约 16 小时，进入页面时会重新签发。抓到后直接带
`Referer: https://h5.m.goofish.com/` + Safari UA 下载即可（已验证
HTTP 200 / video/mp4）。

## 旧版为什么抓不到

`XYDHookOnce` 内部只走 `class_getInstanceMethod`，对 **类方法**
（`+[AVURLAsset ...]`、`+[AVPlayerItem ...]`）完全无效，所以日志里
从来没有 `hook +[AVURLAsset ...] ok`，视频自然进不了面板。

修复：这两处改用 `XYDHookClass`（走 metaclass 的 `method_setImplementation`），
并在 `XYDInstallPlayerHooks` 里加了一次性安装标记，避免重复包装。

## 去重

同一路径的 URL 每次进入页面都会换 `auth_key`。现在用
`scheme://host/path`（去掉 query）作为 key；命中已存在条目时只刷新
`remoteURL`，不会在面板里出现多条重复视频。

## 实测

商品 `1092893899498`（DJI Mini 2）：

- 面板条目：9 张图 + 1 个视频 = 10
- 全选保存：`save done ok=10 failed=0`
- 视频单独保存：`save done ok=3 failed=0`（去重前）
- 保存后相册可见 mp4

## 设备端 Frida（.20）

```
# 二进制
/var/jb/usr/sbin/frida-server          # 17.24.3, arm64+arm64e
/var/jb/usr/lib/frida-1.0/frida-agent.dylib

# 启动（root）
nohup /var/jb/usr/sbin/frida-server -l 0.0.0.0 >/var/mobile/frida.log 2>&1 &

# Mac 端
python3 -c "import frida; print(frida.__version__)"   # 17.24.3
```

`tools/xyd-frida.js` + `tools/xyd-frida-run.py`：列出播放器方法、hook
`loadWithVideoUrl:` / `loadWithVideoId:from:priority:` / `setUrl:` /
`setPlayUrl:` / `AVURLAsset` / `AVPlayerItem`，并把命中写进
`/tmp/xyd-frida.log`。

注意：Frida 17 不再内置 `ObjC` 全局对象，脚本必须用
`frida-compile` 打包 `frida-objc-bridge`；设备端单脚本大小上限约
120 KB，编译时加 `-S -c`（去 sourcemap + 压缩）。

```
cd /tmp/fridabuild
npx frida-compile tools/xyd-frida.js -S -c -o tools/xyd-frida.bundle.js
python3 tools/xyd-frida-run.py Runner /tmp/xyd-frida.log 900
```

## 面板空白 / 假视频 / 状态栏消失（1.0.26）

1. **假视频**：`XYDParseItemJSON` 原来会把 JSON 里任何 `.mp4/.mov` 字符串当视频，
   商品的 `videoUrl` 其实是 `img.alicdn.com/...jpg` 封面，被误判成视频且缩略图必然空白。
   现在只接受 `video.goofish.com` 与 `cloud.video.taobao.com/vod/`，并按
   `scheme://host/path` 去重；真视频封面取首图。

2. **首屏空白**：面板改成 `viewDidAppear` 后再加载（避免 sheet 动画期间
   `reloadData` 造成格子错位/空白），加载后 `prefetchThumbs` + `layoutIfNeeded`，
   缩略图失败自动重试一次，完成时无条件刷新对应 cell。

3. **状态栏消失**：根因是开屏广告生命周期被拦。
   `FMSplashModule` 在 `loadAd / showSplashView / fishSplashAdDidFinish`
   里维护状态栏，拦掉任一步都会让首页状态栏一直隐藏（TBSafeMode 也会被触发）。
   现在这些方法全部放行，只通过 `FishSplashAdWindow` 的
   `didMoveToWindow/layoutSubviews/addSubview:` 把广告窗口视觉隐藏（hidden+alpha=0），
   同时保留热启动广告拦截。

验证：首页 / 详情页 / 面板打开 / 关闭后四个状态
`isStatusBarHidden=false`，面板 10 项（9 图 + 1 视频，视频有封面），
可见 9 个 cell 全部有缩略图。
