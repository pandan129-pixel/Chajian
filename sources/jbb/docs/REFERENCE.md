# 参考索引

## 本目录内

| 文件 | 内容 |
|---|---|
| `S15-2026-10-25-handoff.md` | jbb 6.6 时代：设备环境、QQ/大麦结论、工具清单 |
| `S16-2026-10-25-jbb614-choicy.md` | 性能优化过程、Choicy 研究、基准方法修正 |
| `S17-2026-10-25-handoff-jbb616.md` | **主交接**：源码/构建/打包/验证/检测结果/教训 |
| `ref/apelin-notes.md` | Apelin（设备内 IDE）的构建链、坑、运行期架构 |
| `ref/apelin-tweak-rules-handoff-2026-10-25.md` | R1–R18 工程规则清单，可直接当检查单 |
| `rd-research/01-roothider-core.md` | roothide jbroot 随机化、路径揭示、注入链 |
| `rd-research/02-dyld-hiding.md` | dyld 层能藏什么、藏不了什么（jbb 的能力边界来源） |
| `rd-research/03-process-fs-hiding.md` | 进程/文件系统/launchd 隐藏实现 |
| `rd-research/04-compat-14pro-16.3.1.md` | 14 Pro / 16.3.1 安装兼容性 |
| `rd-research/05-roothide-vs-relaxin.md` | 两套越狱能力矩阵 |

## 外部

- Choicy（门禁设计参考，开源）：https://github.com/opa334/Choicy
  本地副本：`references/choicy/`
- roothide Dopamine 3.x 源码：https://github.com/roothide/Dopamine-roothide
- Apelin：https://github.com/owngoal-dev/Apelin（本地笔记见 `ref/`）
- ElleKit / litehook / ChOma：各自由 opa334 维护，构建依赖

## 关键结论出处

| 结论 | 出处 |
|---|---|
| jbroot 随机命名 `.jbroot-%016llX` | `rd-research/01`（`DOBootstrapper.m`） |
| 3.x 不做 path hook，靠 namecache 假文件 | `rd-research/01/02` |
| jbb 注入在 TweakLoader 之后 | `rd-research/01` + 本仓库 `systemhook` 源码 |
| `dyld_all_image_infos` 直读是盲区 | `rd-research/02` + `tests/jbprobe.m` 实测 |
| basebin 全量 rebind 会闪退 | `S17` §8 |
