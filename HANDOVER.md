# 91Download Mobile 交接文档

> 生成时间：2026-11-11　对应版本：**v1.7.1（1.7.1+25）**　仓库：https://github.com/BiliNico-com/91Download-Mobile
> 用途：接手维护时快速建立全貌 —— 这个项目做过什么、代码在哪、为什么这么写、还有哪些坑。

---

## 一、项目概览

Flutter 安卓应用。抓取多个视频站点的列表与详情，提供在线播放、批量下载（HLS 切片 / 直链 MP4）、关注作者、下载管理、运行日志。

| 项 | 值 |
| --- | --- |
| 应用名 / 包名 | 91Download / `com.bilinico.download_91` |
| 技术栈 | Flutter 3.22.0 · Dart · Provider · Dio 5.4 · sqflite · shared_preferences · video_player |
| 当前版本 | `pubspec.yaml:5` = `1.7.1+25` |
| 代码规模 | lib 下 **46 个 .dart，26703 行** |
| 提交总数 | **116** 条（`1723302` 2026-05-07 起） |
| 版本 tag | **19** 个（v1.0.7 → v1.7.1） |
| 编译 SDK | compileSdk 34 / minSdk 21 / targetSdk 34 |

### 支持的站点

| 站点系（family） | 域名 | 解析器 |
| --- | --- | --- |
| `porn91` | 91porn.com | `lib/crawler/sites/porn91_site.dart` |
| `jiuse` | 91porny.com、jiuse.icu | `lib/crawler/sites/jiuse_site.dart` |
| `hifuli` | hifuli.com、hiporn.net | `lib/crawler/sites/hifuli_site.dart` |
| `original` | ml0987.xyz、hsex.icu、hsex.men | `lib/crawler/sites/original_site.dart` |

站点系定义在 `lib/crawler/config.dart:40 siteTypes` / `:54 siteFamilies`。用户还可以手动添加自定义站点并指定归属站点系（见 `lib/pages/settings_page.dart` 的站点选择页）。

---

## 二、版本体系与 tag 谱系大坑（**必读**）

### 2.1 版本号规则

版本号唯一来源是 `pubspec.yaml:5` 的 `version: X.Y.Z+BUILD`。规则写在仓库根目录 `VERSIONING.md`（101 行，五节）：

1. **每次更新都要动版本号**。CI 只覆写 `+BUILD`（用 `github.run_number`），`X.Y.Z` 由人决定。
2. **Conventional Commits**：`feat:` / `fix:` / `chore:` / `refactor:` / `docs:` / `test:` / `ci:`。CI 取提交首行做 Release 说明。
3. **一次更新 = 一串功能提交 + 一个 `chore(release): 发布 X.Y.Z` + `git tag -a vX.Y.Z`**。
4. 发布前自检：`flutter analyze` 必须 0 error；单元测试用例目录已从仓库移除（不进版本库、不参与 CI）。
5. 分支：`main` 为发布线，功能走 `feat/*` 再合并。

递增速查：修 bug → PATCH+1；新功能 → MINOR+1 且 PATCH 归零；不兼容变更 → MAJOR+1。`+BUILD` 每次同步 +1。

### 2.2 ⚠️ v1.0.7 ~ v1.2.1 的 tag 不在 main 谱系上

仓库历史在 2026-11-07 被 **rebase 过一次**（新基线提交 `d25fb88 chore: 导入 91Download-Mobile 1.0.6 原始基线`），于是出现两套 tag：

| tag | 指向（rebase 前，已游离） | main 上的对应提交 |
| --- | --- | --- |
| v1.0.7 | `bc28f6d` | `38e3d57` |
| v1.1.0 | `efc33e6` | `d583dea` |
| v1.2.0 | `64f51ef` | `c498981` |
| v1.2.1 | `73ba2cd` | `4e6fb4f` |

这 4 个旧 tag 全挂在遗留分支 `backup-pre-rebase` 上（该分支 tip 是 `73ba2cd`，本地有、远端没有，**别删** —— 它是 v1.2.1 旧 tag 的唯一锚点）。**从 v1.3.0（`3163cd6`）起 tag 才是 main 的祖先。**

已核对：旧 tag 与 main 上对应提交的**文件树完全等价**（`git diff --raw` 只有 `100644 => 100755` 的文件权限位差异，内容 blob 哈希一致）。所以，**看到 `git merge-base --is-ancestor v1.0.7 HEAD` 返回 1，不代表代码丢了**，不要试图去修复它。

副作用：`git diff --shortstat v1.0.7 v1.1.0` 这类跨谱系比较会把整个 rebase 的量算进去（多算成 32 files）。**要统计某个版本改了多少，用 main 上的提交哈希**，见下面的表。

---

## 三、版本演进总表（v1.0.7 → v1.7.1）

变更规模均以 main 谱系上「上一版提交 → 本版提交」计算。**唯一的例外是 v1.0.7 那一行**：它统计的是 release 提交 `38e3d57` 本身（README + VERSIONING.md），而它之前从 rebase 基线算起还有 48 files +2581/−83，分散在 76 条提交里，见第五章。

| 版本 | 日期 | 提交 | 规模 | 主要内容 |
| --- | --- | --- | --- | --- |
| v1.0.7 | 11-07 | `38e3d57` | 3 files +115/−1 | 补 README、新增 VERSIONING.md 版本规范。这是本次集中维护的起点 |
| v1.1.0 | 11-07 | `d583dea` | 3 files +421/−59 | **站点选择 UI 改版**：收起态一行 + 展开按家族分组 + 并发 HEAD 测速（3s 超时，相对分档配色） |
| v1.2.0 | 11-07 | `c498981` | 7 files +552/−42 | 自定义站点可**手动归类**到站点系、可删除；添加弹窗直接选系 |
| v1.2.1 | 11-07 | `4e6fb4f` | 5 files +458/−20 | 修 jiuse 系：丢卡片、封面错、无限翻页、作者功能失效 |
| v1.3.0 | 11-07 | `3163cd6` | 9 files +337/−27 | 补全 jiuse 分区（3→17 个分类）、路径式分页、`/video/viewhd/` 链接；同窗口把 CI 的 Flutter 升到 3.22.0、JDK 固定 17 |
| v1.3.1 | 11-07 | `27526a9` | 5 files +171/−7 | 修 jiuse 协议相对地址 `//cdn...` 导致 Dio 抛 Unsupported scheme |
| v1.3.2 | 11-07 | `edb774a` | 7 files +408/−14 | 九色系播放节点独立生效；样片地址改走 `/apiDownloadUrl` |
| v1.4.0 | 11-08 | `52d89e6` | 28 files +1000/−2400 | 新增**嗨碰(hifuli)**站点；屏蔽九色系高清分区；修 91porn 下载五处缺陷；仓库清理（删 11 个测试用例 + 4 份内部笔记）。同窗口的 `770b081 chore(ci)` 让 **CI 改用仓库 android 源码**，删掉 8 处 heredoc 重写 —— 此前 CI 里的 `MainActivity.kt` 与仓库版分叉，导致 v1.0.6~v1.3.2 的 Release 都缺「亮度调节」与「打开目录」两个原生通道 |
| v1.5.0 | 11-08 | `16b63f2` | 19 files +5540/−4167 | **全站 UI 重构**：新增 `lib/theme/app_tokens.dart` + `lib/components/app_shell.dart`，重写 15 个页面与组件，删除 `video_card.dart`；仅换观感不改业务 |
| v1.5.1 | 11-08 | `33416c7` | 3 files +10/−2 | **搜索框去掉色块底，只留描边**（`batch_page.dart` + `search_page.dart` 显式 `filled: false`） |
| v1.5.2 | 11-08 | `2b55c52` | 2 files +11/−12 | 设置页**去掉顶栏重复的「关于」图标**，返回键外框恢复正方形 |
| v1.5.3 | 11-08 | `c6e3766` | 2 files +87/−78 | 搜索页「视频/作者」分段控件移回搜索框下方，修复整行空白 |
| v1.5.4 | 11-09 | `d3a51e2` | 5 files +161/−2 | **重启后未完成任务自动续跑**；九色系降级片源提前拦截（`#EXTINF` 合计时长与站点标注差 30% 以上判降级） |
| v1.5.5 | 11-09 | `e425c55` | 6 files +265/−41 | 嗨碰系列表补**上传日期与作者**，支持作者主页与作者搜索；「关于」改页脚版本号；顶栏返回键统一 34x34 |
| v1.5.6 | 11-11 | `db19d8e` | 5 files +330/−134 | **直链下载断线自动重连续传**，修复 91porn 卡在 70%；关注按钮补命中区与失败反馈；已关注页卡片溢出 9.2px |
| v1.6.0 | 11-11 | `ababf1d` | 10 files +914/−136 | **运行日志系统**：会话头、环境块、崩溃捕获、15 个用户操作点、网络请求拦截、下载全流程；支持一键提交日志 |
| v1.6.1 | 11-11 | `8899d90` | 2 files +232/−158 | **直链改分段 Range 下载**（4MB/段），修复真机 91porn 下载零字节 |
| v1.7.0 | 11-11 | `167b2a0` | 7 files +1471/−1255 | **爬虫核心按站点拆分**：`crawler_core.dart` 3616→2468 行，`_siteType` 分支 33→6 处 |
| v1.7.1 | 11-11 | `6e1a687` | 7 files +786/−3 | **日志记录网络环境**：出口 IP / 归属地 / 运营商 / 内网 IP / 系统代理，自动判定直连还是代理 |

补充：v1.0.7 之前还有 76 条提交，见第五章。

---

## 四、最近几个版本的详细改动（接手重点）

### 4.1 v1.7.0 爬虫核心按站点拆分（架构核心，先看这个）

**动机**：`crawler_core.dart` 涨到 3616 行，四个站点的解析逻辑全挤在一个文件里，加一个站点要动十几处 `if (_siteType == ...)`，无法独立维护。

**拆分原则（重要，改动前必须理解）**：

> 只把「**URL 构造 + HTML 解析**」下沉到站点类。这部分只依赖 `baseUrl`，不碰 `_dio` / `_db` / 实例状态，因此可以脱离网络独立读改测。
> **发 HTTP 请求、维护分页状态、下载链路，一律留在 `CrawlerCore`。**

**新增文件**（`lib/crawler/sites/`）：

| 文件 | 行数 | 内容 |
| --- | --- | --- |
| `site_handler.dart` | 100 | `SiteHandler` 抽象基类 + `SiteDetail` / `SitePagination` 数据类 |
| `porn91_site.dart` | 368 | 91porn 列表/详情/作者 URL 与解析 |
| `jiuse_site.dart` | 253 | 九色系 |
| `hifuli_site.dart` | 329 | 嗨碰 |
| `original_site.dart` | 314 | 原创系（ml0987 / hsex） |

`SiteHandler` 的 API：

- `String get siteType`
- `bool get addCacheBuster => false`（只有 `Porn91Site` 覆写为 true，因为 91porn 有缓存）
- `String buildListUrl(baseUrl, urlPattern, page)`
- `String buildAuthorUrl(baseUrl, authorId, page)`
- `String buildAuthorSearchUrl(baseUrl, keyword)`
- `List<VideoInfo> parseVideoList(html, baseUrl)`
- `Future<SiteDetail> extractDetail(html, video, baseUrl)`
- `List<AuthorInfo>? parseAuthors(html, baseUrl) => null`
- `SitePagination? decidePagination({html, page, itemCount, signature, lastSignature}) => null`

`CrawlerCore` 持有 `SiteHandler _handler`，在 `_detectSiteType()`（`crawler_core.dart:252`）里通过 `_resolveHandler(_siteType)` 换实例。

**刻意留在 Core 的东西**（不要硬塞进站点类）：

- porn91 的两步 GET+POST（带 `session_language=cn_CN`，会写 `_dio.options.headers['Cookie']`，属会话级全局状态）
- 九色系的 `_fetchJiuseRealUrl` / `_fetchJiuseEmbedUrl`（要发 HTTP）
- 分页状态机（`_lastRequestHasMore` / `_lastPaginationParsed` / `_lastJiuseSignature`）
- porn91 解密、作者/时长兜底、`applyCdnHost`、完整下载链路

**残留的 6 处 `_siteType` 分支（合理，不必再拆）**：`crawler_core.dart:456`（仅日志文案）、`:560`（porn91 两步 GET+POST）、`:940/:953/:970`（详情收尾的 porn91 解密与兜底）、`:1267`（jiuse 下载前三道假片源拦截）。

**回归验证方式**：`test/_tmp_refactor_baseline_test.dart`（golden 快照，本地用例不进仓库）+ `D:/91/_golden_diff.py` 递归比对，忽略 `_t=<数字>` 时间戳。拆分前后 `diffs: 0`。

### 4.2 v1.6.1 直链改分段 Range 下载（真机下载零字节的根因）

**现象**：真机（Xiaomi 24031PN0DC / Android 16）上下载 91porn 视频，媒体请求每条都在 20s / 45s 处 `失败(cancel)`，**零字节**。页面链路却正常（`GET 91porn.com/v.php?...` → 200）。

**探针结论**：

- 设备上**短 Range 请求稳定成功，长连接大流量 GET 会被挂死**（拿不到数据流），旧实现首轮不带 Range → 每次必败。
- `HEAD` 的 `content-length` 不可信（同一条 URL 报过 16.00MB 和 3.24MB）。**`Content-Range` 里的总长才是可靠的**。

**实现（`crawler_core.dart:1810 _downloadDirectMp4`）**：

- 4MB 一段的 Range 循环；常量在 `:1849-1852`：`stallTimeout = 20s`、`maxChunkRetries = 5`、`maxAttempts = 1000`（4MB×1000≈4GB）、`maxIdleRounds = 24`。
- 206 用 `_contentRangeTotal()`（`:2224`）取总长；416 用 `Content-Range` 校正偏移；非 206 就删 `.part` 重来。
- 20s 收不到数据 → 换连接继续（不是失败退出）。
- 暂停时**先 `stallTimer?.cancel()` 再 `awaitIfPaused()`**，否则暂停会误触发停滞看门狗。

**独立媒体 Dio `_mediaDio`（`:1769`）** 的三个理由：

1. 不复用页面 `_dio` —— 页面 Dio 带文档导航头，概率性被服务端在 1 秒内掐断。
2. `Accept-Encoding: identity` **必须** —— 若 gzip，按偏移续传会错位。
3. 独立超时：`connectTimeout 15s` / `receiveTimeout 10min`，`receiveDataWhenStatusError: false`。

文档注释 `:1795-1810` 里写了「为什么不用 `dio.download`」的三条历史原因，改动前先读。

### 4.3 v1.6.0 / v1.7.1 日志系统

**入口**：`lib/utils/logger.dart`（610 行）。启动时 `app_state.dart:223` 调 `unawaited(logger.logNetworkEnvironment(reason: '启动应用'))`，`:232` 之后才读版本号（`VersionService.init()` 必须在前，否则日志写 `v0.0.0` —— 这个 bug 在 v1.6.0 修过）。

**记录内容**：

- **会话头**：时区、App 名+版本+build、包名、设备厂商型号、Android 版本与 SDK、真机/模拟器。
- **环境块**：站点、站点类型、下载目录、主题、并发任务数、并发分片数、保存 HTML。
- **崩溃**：`FlutterError.onError` + `PlatformDispatcher.instance.onError`，立即落盘。
- **用户操作（15 个点）**：切页面、搜索、进入作者主页、关注/取关、切分类、开始/完成/暂停/继续/重试下载、提交日志、启动应用、开关 Debug、开关保存 HTML。
- **网络请求**：`lib/utils/network_log_interceptor.dart`（100 行），格式 `方法 host路径?query前60 -> 状态码 耗时ms 字节数`；切片 `.ts/.m4s/.m4a/.aac` 前 3 个各记一条、之后每 50 条采样一次（避免刷爆）。
- **下载全流程**：入队、开始、取详情、取地址、保存路径、每 10% 里程碑、完成耗时、暂停、失败（`failureReason` + 进度）、异常栈、结束状态。
- **网络环境（v1.7.1）**：`lib/services/network_info_service.dart`（427 行）→ 通过 MethodChannel `com.bilinico.download_91/network_info` 拿系统侧信息（WiFi/蜂窝/以太网/VPN、validated、metered、系统代理、内网 IPv4），再探测 4 个公网 IP 接口（`ip-api.com` → `myip.ipip.net` → `ipwho.is` → `ipinfo.io`；**ip-api 免费版只允许 http**）拿出口 IP、归属地、ISP、是否被标记 proxy/hosting。判定「疑似走代理 / 疑似直连 / 未知」并列出证据行。

> 注意：`logger.rebindSessionContext()`（`logger.dart:133`）定义但**全仓零调用** —— 改站点后不会重建会话头，这是已知缺口。

### 4.4 v1.5.6 下载断线续传（70% 卡死的修复）

现象：91porn 直链下载到 70% 附近彻底不动。

修复要点（`_downloadDirectMp4` 的前一版实现）：外层 `while(true)` 重连循环 + 45s 停滞看门狗（`Timer` + `CancelToken`）+ **只有 206 才 append，否则删 `.part` 从头写** + 4xx 不重连直接报错 + 分块写盘 5 次退避重试。

同一提交还修了：关注按钮缺 `HitTestBehavior.opaque`（点不动）、已关注页作者卡 `OVERFLOWED BY 9.2 PIXELS`（`childAspectRatio: 1.55` 改 `mainAxisExtent: 122`）。

### 4.5 v1.5.0 全站 UI 重构（视觉规范的来源）

新增两套基础设施，**新页面必须用它们，不要自己写颜色**：

- `lib/theme/app_tokens.dart`（74 行）：`AppTokens.of(context)` 取当前主题色。主色 `blue 0xFF1565C0`；`surface` 深 `0xFF171C24` / 浅 white；`surface2` 深 `0xFF1E242E` / 浅 `0xFFF1F4F9`；`surface3`；`text1/2/3`；`line` 深 `0xFF2A323E` / 浅 `0xFFE4E9F2`；语义色 `success/warning/danger` 各带 soft 变体；`AppRadius` sm 8 / md 11 / lg 13 / xl 15 / xxl 18 / pill 999。
- `lib/components/app_shell.dart`（395 行）：`AppIconBtn`（34x34，圆角 `AppRadius.md`，图标 19）等共享组件。

### 4.6 站点选择页（v1.1.0 → v1.2.0，交互最复杂的一页）

`lib/pages/settings_page.dart` 的 `_buildSiteSection`（`:528`）：

- **收起态**：一行（头像方块 + 域名 + 站点系标签 + 延迟徽标 + 「切换」按钮）。
- **展开态**：按 `_siteFamilyOrder`（`porn91` / `jiuse` / `hifuli` / `original`，`:81`；中文名在 `:89`）分组，每组第一项标「主站」其余标「备用」；自定义站点沉到最后的「自定义」组，带「手动归类」标签和 ⋮ 菜单（归类 / 删除）。
- **测速**：`_testSiteLatency()`（`:1125`）并发 HEAD 各站根路径，`Dio(connectTimeout/receiveTimeout 各 3s)`，`DioException` 但有 response 也算通。
- **相关方法**：`_buildSiteGroups`（`:661`）、`_buildSiteOption`（`:721`）、`_showSiteFamilyDialog`（`:848`）、`_confirmRemoveCustomSite`（`:956`）、`_showAddCustomSiteDialog`（`:1171`）。
- **配色是相对分档**，不是绝对阈值：`ms <= 最快*1.5` 绿、`<= 最快*3` 橙、更慢红、超时红。**理由**：绝对阈值在不同网络下没有可比性（模拟器普遍 2s+，真机常见 100~500ms）。

> 踩过的坑：`RadioListTile<String?>` 用 `value: null` 表示「自动」时无法与「未选择」区分 —— 改用哨兵字符串 `__auto__`。

---

## 五、v1.0.7 之前的 76 条提交（历史沿革）

这些是项目在被集中维护之前就有的积累，按月分组只列代表性的。完整列表用 `git log --reverse 1723302..38e3d57` 查看。

### 2026-05-07（10 条，初始整理）

基线 `1723302 optimization: 91Download Mobile v1.0.5.409 代码优化` → `b561670` UI/UX 优化（路由/滑动删除/防抖搜索/主题/公共组件）→ `c6af5f8` 编译错误（PopScope 兼容 / ImageFilter）→ `d7e89db` 相对时间正则支持「X月前/X周前」→ `9f824b4` 真机关注按钮点不动 → `8f13f4c` 搜索栏与翻页器样式 → `cdc8346` 版本号 1.0.6+6 与检查更新 → `29cf03d` 作者页关注按钮改 `GestureDetector` 增大触摸区 → `7293793` 下载失效（setup 调用 / 数据库回退 / 失败任务显示）→ `25188d0` 五问题（关注按钮 / 页码胶囊 / AppBar 颜色 / porn91 / 手势退出）。

### 2026-08-15 ~ 08-20（7 条）

`d9ccc40` 手动输入网址 → `fba4ff4` 升级后关注数据丢失（`followed_db` + version 3 兼容）→ `3fb984c` 切站后搜索失效与页码胶囊不同步 → `62363ad` 作者更新检查 + 作者主页增强 → `dad4443` / `11705a9` / `e79922e` original 系搜索 URL 模板与去 `_t` 时间戳。

### 2026-10-13 ~ 10-19（48 条，最密集的一轮）

起点 `2e1fa3d` 修复页码不同步 / 无限滚动失效 / 恢复在线播放，终点 `9857c04` 恢复被底部导航栏遮挡的页码胶囊。中间的关键提交：

| 提交 | 内容 |
| --- | --- |
| `c821b0f` | 进度条抽动 + 并发滑动窗口 |
| `34e3a3d` | 检查更新永远检测不到（版本号体系冲突） |
| `59f6953` | 已删内容复活 + 缓存管理 + 设置备份 |
| `b7f1528` | PIN 解锁无反应 |
| `59f2e7f` | 播放器玻璃拟态（移除 chewie） |
| `201b44b` / `85eae62` / `449b693` / `6a44335` | 悬浮窗系列（进度打通 / 遮罩残留 / 进度丢失） |
| `4b6f961` | 倍速选择 |
| `10d7309` | 图片磁盘缓存（移除不兼容 CI 的依赖） |
| `a9a3581` / `9e82f98` | 失败任务分组 |
| `1adbf72` | 作者主页折叠头 |
| `77c03c5` | 消除异步后使用 context 闪退 + 断点续传 + 抽公共列表 |
| `cf10164` | 暗色 / 圆角 / 尺寸规范 |
| `0a39849` | 批量页分类横滑标签 |
| `cc8bc15` | 搜索页分段控件 |
| `7d26093` | 搜索历史 + 作者更新提醒 |
| `6d2aa92` | 直链不显示速度 |
| `ba498ac` | 取消下载无效 |
| `586abb3` | 47 项（权限 / PIN / 应用锁） |
| `21a688b` | 检测更新弹窗重做 |
| `cf8f785` | 搜索栏点击穿透 |
| `d554828` | 底栏毛玻璃 |
| `a89105e` | SliverAppBar 折叠栏 |
| `a2d9894` | 人机验证识别 |

### 2026-11-07（38e3d57 之前紧邻的一批）

`8148a6d chore(build): 补齐 Android 构建配置，修复本地 flutter build 失败`（gradle wrapper / gradle.properties / styles.xml / ic_launcher.xml，9 files +307/−4）→ `68fe2d5` 放宽直链与切片下载超时 → `f316f6f fix(download): 修复下载进度条不动 / 暂停无效`（3 files +92/−27，每个任务独占 `DownloadControl` 句柄，这是下载管理器的基础设计）→ `922b6c9` 支持 jiuse → `0f7cf1a` 解密 91porn 隐藏标题/作者/时长 → `3b64a85` 剔除隐形字符 → `8f16916` 播放线路 CDN 选择 → `852aeaa` 修设置页自定义站点红屏 → `acdc5f9 chore(git): 整理 .gitignore` → `eeddd59 test:`（TASK_ARCHIVE.md 137 行 + 5 个测试文件）→ `38e3d57` 发布 1.0.7。

---

## 六、代码地图

### 6.1 文件规模（行数降序，共 46 个 .dart / 26703 行）

```
3696  pages/settings_page.dart          设置页 + 所有二级页（站点选择/下载目录/调试/关于…）
2506  pages/download_page.dart          下载列表页（任务卡片、进度、多选、历史）
2468  crawler/crawler_core.dart         爬虫核心（HTTP、分页状态机、下载链路）
1580  pages/search_page.dart            搜索页（视频/作者两段、关注按钮）
1447  pages/batch_page.dart             批量爬取页（分类、列表、作者模式、多选）
1435  crawler/config.dart               站点表、列表类型、常量、HTML 工具函数
1275  services/download_manager.dart    下载任务调度（队列、并发、续跑、DB）
1155  services/app_state.dart           全局状态（Provider），启动流程、站点切换、偏好
 826  pages/streaming_page.dart         播放页（video_player + 玻璃拟态顶栏）
 746  services/version_service.dart     检查更新、下载安装、prune 旧安装包
 671  pages/author_detail_page.dart     作者主页
 610  utils/logger.dart                 日志系统
 573  services/followed_authors_service.dart
 565  pages/cache_manager_page.dart     缓存管理
 443  components/video_list_items.dart  列表/网格两种模式的卡片渲染
 427  services/network_info_service.dart 网络环境探测
 421  main.dart
 395  components/app_shell.dart         共享外壳与 AppIconBtn
 371  pages/followed_page.dart
 369  components/cover_image.dart       封面图（磁盘缓存）
 368  crawler/sites/porn91_site.dart
 329  crawler/sites/hifuli_site.dart
 328  services/cache_service.dart
 314  crawler/sites/original_site.dart
 292  pages/main_page.dart             底部 5 tab 容器
 285  services/floating_video_service.dart
 253  crawler/sites/jiuse_site.dart
 234  components/skeleton_card.dart
 223  components/player_glass.dart
 219  theme/app_theme.dart
 219  pages/pin_input_dialog.dart
 218  pages/search_history_page.dart
 213  theme/ui_style.dart
 168  components/category_chips.dart
 162  services/pin_service.dart
 145  components/empty_state.dart
 116  models/video_info.dart
 100  utils/network_log_interceptor.dart
 100  crawler/sites/site_handler.dart
  87  services/search_history_service.dart
  85  routes/app_routes.dart
  79  services/brightness_service.dart
  74  theme/app_tokens.dart
  53  services/pip_service.dart
  31  utils/open_directory.dart
  29  utils/debouncer.dart
```

### 6.2 `crawler_core.dart` 关键锚点（v1.7.1 实测行号）

| 行 | 内容 |
| --- | --- |
| `:18-95` | `DownloadControl`（`stop/pause/resume/reset/awaitIfPaused`，`onProgress/onOverallProgress/onLog`，`receivedBytes`、`failureReason`、`retryable`） |
| `:173` | `createControl()` |
| `:182` | `get control` |
| `:195` | `beginDownload()` |
| `:206` | `runWithControl<T>` |
| `:252` | `_detectSiteType()`（选 `SiteHandler`） |
| `:285` / `:291` | `lastRequestHasMore` / `lastPaginationParsed` |
| `:309` / `:373` | `_detectHasNextPage` / `_applyPagination` |
| `:432` | `_initDio()`（BaseOptions、Referer、`Cookie: language=cn_CN`） |
| `:650/655/660/665/670` | 测试钩子 `parseJiuseListForTest` / `parseHifuliListForTest` / `parseHifuliAuthorsForTest` / `applyPaginationForTest` / `parseM3u8ForTest` |
| `:807` | `getVideoDetail` |
| `:1064` / `:1108` | `_fetchJiuseRealUrl` / `_fetchJiuseEmbedUrl` |
| `:1140` / `:1147` | `lastDetailBlockedByChallenge` / `lastDetailSampleOnly` |
| `:1199` | `downloadVideo(video, savePath, {ctrl})` |
| `:1208` | `_downloadVideoInner` |
| `:1626` | `_parseM3u8` |
| `:1664` | `_downloadTs`（切片下载） |
| `:1769` | `Dio get _mediaDio` |
| `:1810` | `_downloadDirectMp4`（分段 Range 下载） |
| `:2224` | `_contentRangeTotal` |
| `:2232` | `_describeDirectDownloadError` |
| `:2257` | `_mergeTsFiles` |
| `:2351` | `_saveToHistory` |

### 6.3 `download_manager.dart` 方法索引

| 行 | 方法 |
| --- | --- |
| `:395` | `addTask(VideoInfo, {forceRestart})` |
| `:466` | `_tryStartNext([newTask])`（调用点 `:270/:460/:728/:793`） |
| `:516` | `_startDownload(DownloadTask)` |
| `:801` / `:817` / `:831` / `:864` | `pauseTask` / `resumeTask` / `retryTask` / `cancelTask` |
| `:1075` | `restorePendingTasks()`（启动时把 pending/downloading 降级回队列） |
| `:1198` | `_restoreCompletedFromHistory()` |

**核心设计（v1.0.7 之前那个「进度条不动」bug 的产物，别改回去）**：每个任务有**独立的 `DownloadControl` 句柄**，存在 `_taskControls`（`:510`）里。`_startDownload` 里 `createControl()` 注册（`:541-542`），下载时 `final ctrl = taskCtrl ??= _crawler!.createControl();`（`:595-596`），finally 移除（`:721`）。`pauseTask` 用 `_taskControls[taskId]?.pause()`（`:807`）。**若改回用 `_crawler.control` 这个兜底句柄，进度会完全不走、暂停也打不到真实任务。**

### 6.4 五个原生 MethodChannel

| Dart 侧 | Channel 名 | Kotlin 侧注册处 |
| --- | --- | --- |
| `services/brightness_service.dart:10` | `com.bilinico.download_91/brightness` | `MainActivity.kt:35` |
| `services/floating_video_service.dart:10` | `.../floating_video` | `MainActivity.kt:90` |
| `services/network_info_service.dart:197` | `.../network_info` | `MainActivity.kt:71` |
| `services/pip_service.dart:6` | `.../pip` | `PipPlugin.kt:18`（由 `MainActivity.kt:32 registerWith` 注册） |
| `utils/open_directory.dart:11` | `.../open_directory` | `MainActivity.kt:79` |

`FloatingWindowService.kt` 不是通道注册处，它是悬浮窗的 Service 本体（通知渠道、窗口管理与播放控制）。

### 6.5 路由（`lib/routes/app_routes.dart`，85 行）

`/` → MainPage、`/search`、`/batch`、`/download`、`/followed`、`/settings`；`/author` 走 `_buildFadeRoute`（fade 0→1 + scale 0.97→1，进 250ms / 退 200ms）。

`main_page.dart:30` 底部 5 个 tab：批量爬取 / 搜索 / 已关注 / 下载 / 设置。`PageController` 切页；`_handlePopInvoked` 先问 `appState.onWillPopCallback`（作者模式用），非首页回首页，首页双击退出（2s 窗口）。

### 6.6 设置页结构（`lib/pages/settings_page.dart:126-253`）

三组：`抓取与下载`（站点与线路 `:143` / 下载目录 `:151` / 并发与限速 `:162`）、`外观与浏览`（主题模式 `:174` / 浏览设置 `:183` / 应用锁 `:193`）、`权限与其他`（权限状态 `:206` / 调试设置 `:216`）。列表末尾不是「关于」行，而是页脚小字 `91Download 移动端 · 版本号`（`:232-247`，点击进关于页）。

---

## 七、构建与发布

### 7.1 本地构建（Windows）

前置：`android/local.properties`（**不入库**）必须有两行：

```properties
sdk.dir=D:\\Android\\Sdk
flutter.sdk=C:\\flutter\\flutter
```

实际跑过 `flutter build` 之后这文件会多出三行（`flutter.buildMode` / `flutter.versionName` / `flutter.versionCode`），是 Flutter 自己写的，不用管。

`android/gradle.properties` **必须存在**（首次构建报 AndroidX 错误就是这个）：

```properties
org.gradle.jvmargs=-Xmx4G -XX:MaxMetaspaceSize=2G -XX:+HeapDumpOnOutOfMemoryError
android.useAndroidX=true
android.enableJetifier=true
```

构建命令（PowerShell）：

```powershell
$env:JAVA_HOME='D:\Android\jdk'
$env:ANDROID_HOME='D:\Android\Sdk'
$env:ANDROID_SDK_ROOT='D:\Android\Sdk'
cd D:\91\91Download-Mobile-1.0.6.505
C:\flutter\flutter\bin\flutter.bat build apk --debug
```

安装到模拟器 / 真机（注意 `-r -d`，`-d` 允许降级安装）：

```powershell
D:\Android\Sdk\platform-tools\adb.exe -s emulator-5554 install -r -d build\app\outputs\flutter-apk\app-debug.apk
```

### 7.2 CI（`.github/workflows/build.yml`，138 行）

触发：push 到 `main` / PR 到 `main` / 手动 `workflow_dispatch`。

1. checkout `fetch-depth: 20`（为让 Release 说明能往前找提交）。
2. **JDK 17 temurin** —— ubuntu-latest 默认 JDK 25，Gradle 7.5 会报 `class file major version 69`。
3. Flutter 3.22.0 stable。
4. `flutter create . --platforms android --project-name download_91 --org com.bilinico`（补生成缺失的 android 脚手架）。
5. Verify Android sources：`test -f` 校验 9 个文件（含 `android/app/release.keystore`），防止仓库 android 源被误删。
6. Sync version：`grep '^version:' pubspec.yaml` 取 `BASE_VERSION`，用 `github.run_number` 覆写 `+N`（`sed -i`）。
7. `flutter build apk --release` → 上传 artifact。
8. Extract release notes：`git log -20 --pretty=format:'%s'` 循环，跳过 `chore(release)*`，取第一条，再 sed 去掉 conventional 前缀。
9. `softprops/action-gh-release@v1`：tag `v{BASE_VERSION}.{run_number}`、name `Build {run_number}`、files `app-release.apk`、`draft: false, prerelease: false`。

> Release 的 tag 形如 `v1.7.1.519`（`run_number` 拼在版本号后面），**不是** `v1.7.1`。本地 `v1.7.1` 是另一回事。

### 7.3 推送（**本机必须走代理**）

本机直连 github.com:443 不通。可用代理端口 **7897**（Clash 类）。`git config --local` 里已配好 `http.proxy` / `https.proxy`，正常 `git push` 即可；如果哪次失败，显式带代理：

```powershell
$env:GIT_TERMINAL_PROMPT='0'
git -c http.proxy=http://127.0.0.1:7897 -c https.proxy=http://127.0.0.1:7897 push origin main
git push origin --tags
```

读取 GitHub 页面：`Invoke-WebRequest -Proxy 'http://127.0.0.1:7897' -UseBasicParsing`。最新 Release 用 `releases.atom` 正则解析 `<entry>` 最可靠；资产 sha256 看 `releases/expanded_assets/<tag>`。**`api.github.com` 有 403 限流，不要用**。

### 7.4 发布 checklist（照 VERSIONING.md 执行）

1. 改 `pubspec.yaml:5` 的 `X.Y.Z+BUILD`（两者都要 +1）。
2. `flutter analyze --no-pub` 必须 0 error（v1.7.1 实测基线 **28 个 warning/info**，属正常，别去清零）。
3. `flutter test`（本地用例，不入库）。
4. `flutter build apk --debug` + 装机自测。
5. 功能提交 → `chore(release): 发布 X.Y.Z` 提交 → `git tag -a vX.Y.Z -m "..."`。
6. push main + push --tags → 等 CI。

> 坑：**不要**把 `pubspec.yaml` 和功能文件一起 `git add` 提交，否则 `chore(release)` 会变成 `nothing to commit`，tag 也就打错位置。正确顺序是先提交功能（不含 pubspec），再单独提交 pubspec。tag 打错时 `git tag -d vX.Y.Z` 后重打，并用 `git log --oneline -1 vX.Y.Z` 确认。

---

## 八、已知问题与待办（交接重点）

### 8.1 安全

- 🔴 **`android/app/release.keystore` 被 git 跟踪**。`.gitignore` 里写了 `*.keystore` / `*.jks`，但**已跟踪的文件不受忽略规则影响**，所以签名密钥仍在仓库历史里。建议交接后：换新密钥 → `git rm --cached android/app/release.keystore` → 清理历史（`git filter-repo`）→ 强推。当前 `android/app/build.gradle:44-51` 里 `keyAlias 'release'`、`storeFile file('release.keystore')`，storePassword / keyPassword 都是明文 `123456`（debug 与 release 共用同一签名），同样应换。

### 8.2 功能缺口

- `lib/pages/author_detail_page.dart` 与 `lib/pages/followed_page.dart` **没有任何 logger 调用** —— 从这两处点关注/取关不会留日志痕迹（只有批量页作者模式记了）。
- `logger.rebindSessionContext()`（`utils/logger.dart:133`）全仓零调用，切换站点后日志会话头仍是旧的。
- 裸 Dio 未挂日志拦截器：`components/cover_image.dart:48`、`services/network_info_service.dart:277`、`services/version_service.dart:238/428/613`。这些不是下载排查关键路径，但请求失败时无记录。
- 真机 91porn「下载零字节」在小米 Android 16 上由 v1.6.1 修复后，**未再拿到同机型复测确认**。若用户再报，需要：具体设备型号 / Android 版本 / 日志文件 / 卡住时的百分比与已下载字节。
- 批量页的多选操作条（「已选 N 个 / 取消 / 开始下载」）会把页码胶囊整块盖住（截图见过，未修）。

### 8.3 文档

- `README.md` 原先的「项目结构」章节已过时（写的还是 `history_page.dart`，也没有 `lib/crawler/sites/`、`lib/theme/app_tokens.dart`、`lib/components/`）——**本次已一并修正**，并加了「开发文档」小节指向 `VERSIONING.md` 与本文。
- 本文档（`HANDOVER.md`）是唯一完整的历史整理，`git log` 之外没有别的变更记录来源。

### 8.4 技术债

- `pages/settings_page.dart` 3696 行、`pages/download_page.dart` 2506 行，都该拆。
- 全仓无 TODO/FIXME/HACK（搜过，命中的 xxx 都是占位符样例）。

---

## 九、测试与调试资产（都在 `D:/91/`，不在仓库里）

### 9.1 本地测试用例（`test/`，已被 `.gitignore` 排除）

| 文件 | 说明 |
| --- | --- |
| `_tmp_refactor_baseline_test.dart` | 爬虫 golden 快照（拆分前后比对用） |
| `_tmp_direct_test.dart` | 直链下载，**需要 `_mock_porn91.py 8902` 在跑** |
| `_tmp_entity_test.dart` | HTML 实体解码 |
| `_tmp_hifuli_verify_test.dart` | 嗨碰解析 |
| `duration_guard_test.dart` | 时长交叉校验（降级片源拦截） |
| `restore_requeue_test.dart` | 重启后续跑 |

跑法：`flutter test`（非 mock 用例全绿），`flutter test test/_tmp_direct_test.dart`（需先起 mock）。

### 9.2 本地 mock 服务（Python `http.server`）

| 脚本 | 端口 | 用途 |
| --- | --- | --- |
| `_mock_server.py` | 8899 | 九色系：回放 `site_jiuse_icu.html` / `jiuse_search.html` / `jiuse_detail.html` / `_jv.html`（分区页），日志 `_mock_log.txt` |
| `_mock_porn91.py` | 8902 | 91porn：含 `CUT`（6MB 掐在 70%，验证续传）与 `BIG`（24MB，验证分段 Range）两个用例 |
| `_mock_hifuli.py` | 8901 | 嗨碰：`/hot` 列表、`/u/<id>` 作者主页、`/s/<kw>` 搜索、`/video/<id>` 详情 |

启动：`python _mock_porn91.py 8902`（后台 job）。

**模拟器/真机访问宿主机的地址**：`172.16.1.2:<port>` 或 `192.168.0.16:<port>`。**`10.0.2.2` 不通**（雷电是桥接模式不是 NAT），`172.16.1.1` 也不通。

**换站点最快的方式是直接改设备 SharedPreferences**，不用点 UI：

```powershell
D:\Android\Sdk\platform-tools\adb.exe -s emulator-5554 shell "run-as com.bilinico.download_91 cat shared_prefs/FlutterSharedPreferences.xml" > _prefs.xml
# 改 flutter.currentSite 与 flutter.customSiteTypes 两项
D:\Android\Sdk\platform-tools\adb.exe -s emulator-5554 push _prefs.xml /data/local/tmp/_prefs_new.xml
D:\Android\Sdk\platform-tools\adb.exe -s emulator-5554 shell "run-as com.bilinico.download_91 cp /data/local/tmp/_prefs_new.xml shared_prefs/FlutterSharedPreferences.xml"
```

`flutter.customSiteTypes` 是 JSON 字符串（XML 里要做 `&quot;` 转义），例：`{"http://172.16.1.2:8902":"porn91"}`。改完要**杀掉进程重启**才生效。

### 9.3 样本与工具脚本

- HTML 样本：`site_jiuse_icu.html`、`jiuse_search.html`、`jiuse_detail.html`、`_jv.html`（jiuse `/video` 原页 82KB）、`p91_detail.html`。
- `_golden_diff.py`：golden 递归比对，忽略 `_t=<数字>` 时间戳。
- `_ctrl.py`：扫控制字符（见第十章踩坑）。
- `_crop20.py`：Pillow 裁剪缩放截图，`python _crop20.py src dst left top right bottom width`。
- 目录里还有 370 个 `_*.py`、469 张 `_*.png` 截图、148 个数据文件，都是调试残留，可清理。

### 9.4 读设备日志

```powershell
D:\Android\Sdk\platform-tools\adb.exe -s emulator-5554 shell "run-as com.bilinico.download_91 ls /data/data/com.bilinico.download_91/app_flutter/logs"
D:\Android\Sdk\platform-tools\adb.exe -s emulator-5554 shell "run-as com.bilinico.download_91 cat /data/data/com.bilinico.download_91/app_flutter/logs/<file>"
```

---

## 十、踩坑清单（都是用时间换来的，别重复踩）

### 10.1 Dart / Flutter

- **写 Dart 正则时 `\b` 容易被上层字符串转义吃掉**，变成 U+0008 退格符，落盘后正则 0 命中，现象是「Python 同款正则命中 8 个，Dart 命中 0 个」。判定办法就是用 `_ctrl.py` 扫控制字符。
- **`RadioListTile<String?>` 的 `value: null`** 无法与「未选择」区分 → 用哨兵字符串 `__auto__`。改成 `<String>` 后 `onChanged: (v) => setDialogState(() => choice = v)` 会报 `String? can't be assigned to String`，必须写块体 `if (v == null) return;`。
- **弹窗里的 `TextEditingController` 不能在外层 Future 返回后 dispose** —— 关闭动画期间会红屏 `Failed assertion: _dependents.isEmpty is not true`。由 State 统一持有并释放。
- **`showDialog` 里 `Navigator.pop` 必须用 `dialogContext`**，用外层 `context` 弹不掉。
- **二级页要重建必须用 `ValueNotifier` + `listenable`**：`_pushSubPage` 推出的是独立路由，父 State 的 `setState` 管不到它。
- **`AppBar` 的 `leading` 会被拉满工具条高度**，直接放 34x34 的 `AppIconBtn` 会变瘦高条，必须外包 `Center`。
- **`unawaited` 要显式 `import 'dart:async';`**，否则 analyze 报 `The method 'unawaited' isn't defined`。
- 全局 `inputDecorationTheme` 是 `filled: true`（`theme/app_theme.dart:162/206`），任何 `TextField` 不显式 `filled: false` 就会带底色。
- 弹窗里局部变量不要和外层作用域重名（曾因重名 `family` 报 `duplicate_definition`）。

### 10.2 网络 / 下载

- **`HEAD` 的 `content-length` 不可信**，总长从 `Content-Range` 取。
- **`Accept-Encoding: identity` 必须**，gzip 会让按偏移续传错位。
- **签名媒体 URL 不能被 CDN 改写**：`config.dart:390 isSignedMediaUrl` 判 query 同时含 `st` 与 `e`；`crawler_core.dart:143`（在 `applyCdnHost` `:127` 内）命中就直接 return 原 URL，否则必然 403。
- 九色系 `/video/viewhd/` 未登录**恒返回 12 秒样片**，所以高清分区入口被移除；样片靠 `/hlsd/` 特征识别后改走 `/apiDownloadUrl/{id}`。
- 广告片固定 ID `358999`（`config.dart:382 knownAdVideoIds`）。
- 宿主机（Windows）对这批站点的直连基本全超时，**但模拟器内的网络路径不同**，宿主机 curl 失败不代表 App 里失败。判定要拿 App 日志。
- 九色系分区页每页条数不固定，分页判据要优先看页脚页码链接（`jiusePaginationHasMore`），条数兜底会误判。

### 10.3 工具 / 环境

- **git 不在 PATH**：`C:/Users/Administrator/AppData/Local/GitHubDesktop/app-3.6.7/resources/app/git/cmd/git.exe`。
- 不要用 `git -c user.name=... commit`（报 `options '-m' and '-c' cannot be used together`）。本地身份已配 `91Download Dev <dev@91download.local>`。
- **adb 必须带 `-s`**：可能同时连着 `127.0.0.1:5555`、`192.168.0.16:5555`、`emulator-5554`（前两个其实是同一台真机 LIO-AN00，第三个是雷电模拟器）。
- `adb shell "... | Select-String"` 不生效（设备端是 toybox，没有 PowerShell cmdlet），过滤要在宿主机侧做。
- 用脚本写 Windows 路径时别写成 `r"D:\91\" + p`（原始字符串以反斜杠结尾会吞掉引号 → `SyntaxError: unterminated string literal`），用 `BASE = "D:/91/"` 再拼。
- 生成 Dart 源码时 `$` 要转义，否则会被上层模板字符串当插值解析。
- 读 GitHub 数据优先 `Invoke-WebRequest -Proxy` + `releases.atom`；`api.github.com` 有 403 限流。

---

## 十一、接手后的第一批动作建议

1. **先读 `VERSIONING.md` + 本文档第二、七章**，把版本与发布流程走一遍（改个错别字发个 PATCH，验证 CI 通不通）。
2. **跑一次完整构建**，确认本地环境（`local.properties`、`gradle.properties`、JDK、Flutter 路径）。
3. **起一次 mock 站点**，用 `test/_tmp_direct_test.dart` 验证下载链路没坏。
4. **处理 8.1 的密钥泄漏**（换密钥 + `git rm --cached` + 清历史）。这是最该优先做的。
5. 按需处理 8.2 的功能缺口。

---

## 附录：常用命令速查

```powershell
# 仓库
cd D:\91\91Download-Mobile-1.0.6.505
git log --oneline -20
git tag --sort=-creatordate
git show <sha> --stat

# 质量门
C:\flutter\flutter\bin\flutter.bat analyze --no-pub   # 必须 0 error
C:\flutter\flutter\bin\flutter.bat test

# 构建 / 装机
C:\flutter\flutter\bin\flutter.bat build apk --debug
D:\Android\Sdk\platform-tools\adb.exe -s emulator-5554 install -r -d build\app\outputs\flutter-apk\app-debug.apk

# 截图 / 剪裁
D:\Android\Sdk\platform-tools\adb.exe -s emulator-5554 exec-out screencap -p > shot.png
python _crop20.py shot.png small.png 0 0 1080 900 540
```

模拟器坐标（1080x1920，雷电）：批量 `(108,1790)`、搜索 `(320,1790)`、已关注 `(535,1790)`、已下载 `(752,1790)`、设置 `(968,1790)`。
