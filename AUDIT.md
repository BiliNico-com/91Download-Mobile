# 91Download-Mobile 全量源码勘察报告

范围：37 个 Dart 文件（17031 行）+ 3 个 Kotlin 文件（1115 行），全部逐文件读完。
每条结论均带行号证据；标注 **[已复核]** 的条目由我本人二次 grep/读码确认，不是单个 agent 的判断。

---

## 一、P0：确定性缺陷（用户可感知的假功能与崩溃）

这一档的共同点：**功能表面存在、实际不工作**，或**会崩溃/泄漏**。改动小、风险低、收益立竿见影。

### P0-1 亮度调节是纯 UI 幻影 **[已复核]**
- `lib/services/brightness_service.dart:5` 用 `MethodChannel('com.example.download_91/brightness')`。
- 全仓库 Kotlin 只有 3 个文件，**没有任何 brightness 通道注册**。已注册的只有：
  `MainActivity.kt:23` OPEN_DIR_CHANNEL、`MainActivity.kt:34` FLOATING_CHANNEL、`PipPlugin.kt:21` pip。
- 不是包名不匹配（`android/app/build.gradle:54` applicationId 确为 `com.example.download_91`），是**原生端从未实现**。
- 触发：播放器左半屏上下滑动（`download_page.dart:1749-1766`）。
- 症状：指示条（`download_page.dart:2258-2260`）随手指正常增减，**画面亮度完全不变**。异常被 `download_page.dart:1766` 的 `catch (_) {}` 静默吞掉，连日志都没有。
- 连带：右侧音量用 volume_controller（真实生效），左侧亮度是死代码 —— 三大手势（左亮度/右音量/横滑进度）三分之一是假的。
- **已确认实现方式：仅改本 App 窗口亮度**（用户选定 A 方案）
  `activity.window.attributes.screenBrightness = value` → 免 `WRITE_SETTINGS` 权限、退出 App 自动还原、绝不影响系统设置。
  （对比：`Settings.System` 全局改需特殊权限且退出后不还原，已排除。）
- 顺带修：`brightness_service.dart:18-53` 五个方法全部空吞异常，至少应 `debugPrint`；`download_page.dart:1343/1573` 的 `_savedBrightness` 赋值后**从未被读取**，是死状态。

### P0-2 Android 12+ 后台调用会闪退 **[已复核]**
- `MainActivity.kt:133`（stopNativeFloating）、`:145`（switchFloatingVideo）、`:155`（sendCommandToService）三处用 **`startService(intent)`**。
- 只有 `:119`（startNativeFloating）正确用了 `startForegroundService`。
- 该 Service 在 `onCreate` 调 `startForeground`，`AndroidManifest.xml:70` 声明 `foregroundServiceType="mediaPlayback"`，targetSdk 34。
- 触发：App 在后台时调用停止悬浮窗 / 暂停 / 播放 / seek / 切视频任一。
- 症状：`ForegroundServiceStartNotAllowedException` → 闪退。
- **`switchVideo` 尤其危险**：`batch_page.dart:296` 会调用它。
- 修法：三处同样改走 `startForegroundService`。

### P0-3 音量监听器每次进出播放页泄漏一个订阅 **[已复核]**
- `download_page.dart:1375` `VolumeController().listener(...)` 在 initState 注册；`dispose()`（`:1872`）**没有 `removeListener()`**。
- volume_controller 2.0.8 是**单例 + 单订阅**（`listener()` 直接覆盖旧的 `_volumeListener`）。
- 后果：每次进出播放页新建 State 并注册，旧订阅既不取消又立即失去引用 → EventChannel 订阅 + 原生监听器永久累积。反复进出 N 次泄漏 N 个。
- 修法：dispose 中调用 `VolumeController().removeListener()`。**一行修复。**

### P0-4 「暂停」按钮是彻底的空操作 **[已复核]**
- `crawler_core.dart:1877-1879` 的 `pause()` 只设置 `_pauseFlag`。
- 全文件 grep `_pauseFlag`：只有 3 处出现，**全部是写入**（`:22` 声明、`:1878` 赋值 true、`:1882`/`:1887` 赋值 false），**没有任何一处读取**。
- 下载主循环只检查 `_stopFlag`（`:1418`、`:1421`、`:1438`、`:1503`、`:1506`、`:1522`）。
- `download_manager.dart:568-577` 的 `pauseTask` 把状态改成 paused 后调用 `_crawler?.pause()`。
- 症状：UI 立刻显示「已暂停」，但后台 32 个分片请求**继续跑完**、文件继续增长、速度条继续刷新。用户以为停住了，实际流量一直在烧 —— 移动数据下尤其致命。
- **这不是「没做暂停」，是做了个撒谎的按钮**，最伤用户信任。
- 修法：主循环加 `_pauseFlag` 检查并真正挂起；在修好之前，UI 上应先把按钮改成「停止」走 `cancelTask`。

### P0-5 并发任务进度回调互相覆盖 **[已复核]**
- `onProgress` / `onOverallProgress` 是共享 `CrawlerCore` 实例上的**单槽字段**（`crawler_core.dart:37-38`）。
- `download_manager.dart:457` / `:469` 在 `_startDownload` 里直接赋值，`finally` 中 `:501` / `:502` 置 null。
- 而 `maxConcurrentTasks` **默认就是 2**、可上调到 5（`app_state.dart:41`、`settings_page.dart:483-497`）。
- 症状：任务 A 的进度条/速度显示的是任务 B 的数据，两个列表项进度来回跳；任务结束时把回调置 null，可能让仍在跑的任务「停止更新进度」（卡在某个百分比）。
- **默认配置下就会发生**，不是边缘场景。
- 修法：回调改成按 taskId 分发的 map。

---

## 二、数据正确性（会产出坏文件 / 丢数据）

### D-1 合并切片时下标错位 → 产出内容错乱的视频 **[已复核]**
- `crawler_core.dart:1752`：`if (downloaded != null && i < downloaded.length && !downloaded[i])`
- `i` 来自 `dir.list().toList()` 排序后的**列表位置**（`:1738-1741`），**不是从文件名解析出的分片序号**。
- `:1741` 按 path 字符串排序，配合 `seg_00000.ts` 零填充命名，正常情况恰好等于数字序；但只要 `_temp` 里存在任何非 `seg_<n>.ts` 的残留文件、或分片存在缺口，后续**每一个**下标都会错位 → 把失败切片的标记套用到错误的文件上。
- 症状：合并时跳过错误切片或漏掉切片，产出时长/内容错乱的视频，而进度显示「下载完成」。用户要在播放时才发现画面跳段。
- 修法：按文件名解析出的 segment index 匹配，而不是用列表下标。

### D-1b 同作者 + 同标题的视频互相覆盖 **[已复核，用户报告]**

用户报告：同一作者上传两个同名视频，先后下载，**后下载的会覆盖先下载的**。

根因 —— `lib/services/download_manager.dart:441-449`：
```dart
final author = task.video.author ?? task.video.authorId;
if (author != null && author.isNotEmpty) {
  final safeAuthor = author.replaceAll(_invalidFileNameChars, '_');
  fileName = '${safeTitle}_$safeAuthor.mp4';        // ← 同作者+同标题 = 同一路径
} else {
  fileName = '${safeTitle}_${task.video.id}.mp4';   // ← 只有无作者时才带 id
}
final savePath = '$_downloadDir/$fileName';
```
- `:440` 的注释写着「构建文件名：视频名称 + 作者信息（**避免同名覆盖**）」—— 作者后缀本意就是防撞名，但对「**同作者 + 同标题**」这个情形完全无效，正是用户遇到的情况。
- **去重检查救不了它**：`addTask` 的去重键是 `video.id`（`:305`、`:308`），而 `id` 就是 viewkey（`crawler_core.dart:549`），两个不同视频 → ID 不同 → 两个任务都正常入队，都完整下载，只是写到磁盘同一份字节上。
- 症状：先下的文件被静默覆盖；「已完成」里出现**两条记录指向同一个文件**；删除其中任意一条（`deleteFilesForTask`）会把另一条的片子一起删掉。
- 修法：文件名带上唯一 ID，即 `'${safeTitle}_$safeAuthor_${task.video.id}.mp4'`；或撞名时追加 ` (2)` 序号。
- 已确认安全：没有任何逻辑依赖当前命名格式，只有 `_temp` 后缀约定被用到（`crawler_core.dart:1319`、`download_manager.dart:710`、`cache_service.dart:113`）；`_invalidFileNameChars`（`:120`）过滤逻辑照常复用。
- **用户决定：列入待修复清单，暂不实施**；且旧文件不处理 —— 已完成记录的路径是存库的（`download_manager.dart:479` 写 `file_path`），改名只对新下载生效，不影响存量。

### D-2 合并阶段把整个视频读进内存 → 长视频 OOM **[已复核]**
- `crawler_core.dart:1759` `await file.readAsBytes()` 逐文件全量读入；`:1773` `sink.add(bytes)`。
- 一个 1GB 的片子会产生同等量级内存峰值 → 合并阶段 App 卡死或被系统 OOM 杀掉，而分片其实已经下完，用户看到的是「下载完成前突然闪退」。
- 另：`:1744` 的 sink 无 try/finally，异常路径下 `close()` 不执行。
- 修法：`openRead()` 流式拷贝。

### D-3 直链 MP4 不支持断点续传，失败后残留半截文件
- `crawler_core.dart:1670-1732` `_downloadDirectMp4` 用 `_dio.download(...)` 一次拉完，**无 Range 头、无 start 偏移**，失败时不删半成品。
- 对比 HLS 路径（`:1595-1667` 有 `len >= 188 && bytes[0] == 0x47` 的续传校验）。
- 注意：**「断点续传」已实现的前提只对 HLS 成立**，直链这条路径是缺口。
- 症状：大文件重试从 0 开始白下；下载目录里堆着看起来正常、实际播到一半就断的 `.mp4`，用户分不清哪个能用。

### D-4 M3U8 加密流（AES-128）不解密，静默产出坏文件
- `config.dart:249-251` 定义了 `aesKeyPattern = #EXT-X-KEY:METHOD=AES-128,URI="([^"]+)"`，但 `crawler_core.dart` **全文无任何引用**。
- `_parseM3u8`（`:1571-1589`）明确跳过所有 `#` 开头行，因此 `#EXT-X-KEY` 与 `#EXT-BYTERANGE` 都被丢弃。分片按密文原样落盘，`_mergeTsFiles` 直接拼接。
- 症状：进度 100%、显示「下载完成」，点开黑屏/花屏/时长异常。
- **当前是静默产出垃圾文件，最坏的一种**。至少要检测到 `EXT-X-KEY` 时明确失败并提示「此视频受加密保护，暂不支持」；完整修复需 dio 拉 key + 解密每个分片。

### D-5 已完成任务的 `endTime` 被写成 `startTime`
- `download_manager.dart:814-816`。而排序键是 `(endTime ?? startTime)`（`:241-251`）。
- 后果：重启后「下载于 …」显示的是**创建**时间而非完成时间，倒序也会错位 —— 直接削弱刚做完的「已完成倒序 + 年月日时分」的观感。

### D-6 分片进度不落盘，杀进程后进度从 0 重爬
- `download_manager.dart:145-188` 建表 `download_tasks` 只有 `status/file_path/error/download_time`，**无 progress/downloaded_bytes/total_bytes 列**，且只有 `onCreate`、**无 `onUpgrade`**。
- `_saveTaskToDb`（`:736-764`）从不写进度。
- 症状：下载中强杀 App 再打开，进度条跳回 0%（实际靠 `crawler_core.dart:1351-1361` 的预扫描兜底能接着下，但用户看到的就是「白下了」）。

### D-7 恢复已完成记录时丢失封面/作者/时长
- `download_manager.dart:842-908` `_restoreCompletedFromHistory` 只用 `id/url/title` 构造 `VideoInfo`，而界面会渲染封面（`download_page.dart:1002`/`1105`）。
- 另：`_saveToHistory`（`crawler_core.dart:1792-1807`）**从不写 `upload_date`**（表里有这一列，`:230` 建表）。
- 症状：历史恢复的列表项封面空白、作者/时长缺失，上传日期永远为空。

### D-8 `restorePendingTasks` 按整数下标取枚举，越界即崩
- `download_manager.dart:808` `DownloadStatus.values[map['status'] as int]`；DB 版本固定 1 且无 `onUpgrade`。
- 将来枚举增删成员 → 旧库整数越界抛 `RangeError` → 升级 App 后首次打开下载页直接崩溃，且用户无法自救（需清数据）。

---

## 三、下载目录持久化（最高优先级的功能缺口）

### G-1 切换下载目录后不持久化、不迁移数据库 **[已复核]** —— 唯一会让用户以为「数据全丢了」的缺口
三重问题：
1. **不持久化**：`app_state.dart:584-587`
   ```dart
   void setDownloadDir(String dir) {
     downloadDir = dir;
     notifyListeners();
   }
   ```
   没有 `_saveSettings()`。对比：`setMaxConcurrentTasks`（`:621-630`）、`setExternalPlayer`（`:614`）都会调。
   `downloadDir` 出现在 `_loadSettings`（`:322`）和 `_saveSettings`（`:347`）的键列表里 —— **两处都没有**。
2. **每次启动硬编码回退**：`initDownloadDir()`（`:428-477`）回退到 `/storage/emulated/0/Download/91Download`（`:434`）。
3. **缓存字段不失效**：`crawler` getter（`:145-167`）的 `_crawler` 是懒建缓存，`setDownloadDir` 不置 null；`_downloadManager.externalDbPath` 只在 `init()`（`:180`）设过一次。
- 触发：选非默认目录 → 正常使用（爬虫/历史库写在新目录 `.db/`）→ 杀进程重启。
- 症状：设置页显示旧路径；下载继续写默认目录；最严重的是**旧目录 `.db/` 下的下载历史与关注作者库「整个消失」**（新目录下是空的），用户会认为下载记录全丢。
- 附带：`_restoreSettingsFromExternal()`（`:221-246`）只在 `prefs.getString('currentSite')` 为空时才恢复（`:228-229`）—— 已选站点的正常用户**永远不会**从新目录备份恢复任何设置。
- 修法：`setDownloadDir` 加 `_saveSettings()` + `_crawler = null`；把 `downloadDir` 纳入持久化与备份 JSON；改目录时提供「迁移旧数据 / 保留原位」选择。

### G-2 `AppState.init()` 无幂等守卫 **[已复核]**
- `settings_page.dart:32-36` `initState` 里 `Future.microtask(() => context.read<AppState>().init())`。
- `AppState.init()`（`:170`）内部**无 `if (initialized) return;` 守卫**（`initialized` 字段 `:50` 只在末尾置位）。
- 触发：从其它路由 push/pop 回设置页（`AutomaticKeepAliveClientMixin` `:25`/`:29` 只保证 Tab 内保活）。
- 症状：重复执行 `requestPermissions()`（反复弹权限框）、`_restoreSettingsFromExternal()`（再次覆盖内存设置）、**`_downloadManager.restorePendingTasks()`（`:188`）**（可能重复恢复已完成任务/状态回退）。
- 修法：`init()` 首行加守卫。**一行修复。**

---

## 四、功能缺口（后端已有，只缺 UI 接线）

这三项**投入产出比最高** —— 服务层完整，只差一个开关。

### F-1 搜索历史服务完全没有 UI 入口（就是本轮刚做的那个服务）
- `lib/services/search_history_service.dart:8-82` 提供 `add/remove/clear/entries`，`maxEntries=20`；`app_state.dart:124` 实例化、`:170` 加载。
- 但 `settings_page.dart` 全文无引用，也无独立页面。
- 症状：历史到达 20 条上限后无法查看/单删/清空，只能靠「清空应用数据」（顺带丢设置）。
- 附带 bug **[已复核]**：`search_history_service.dart:54` `add()` 用 `toLowerCase()` 去重，`:68` `remove()` 用 `e == keyword` **精确匹配** → 历史里有 "Abc"，删 "abc" 删不掉，条目永久残留。

### F-2 隐私模式已实现但设置页无开关
- `app_state.dart:99` 字段、`:676 togglePrivacyMode()`、`:355` 已持久化、`:306` 备份里也存。
- 但 `settings_page.dart` **无任何开关**，用户只能被动接受默认值。

### F-3 自动检查更新已实现但不可配置
- `followed_authors_service.dart:386` `_prefLastAutoCheck`、`:389 autoCheckInterval = Duration(hours: 6)` **硬编码**，`:392 shouldAutoCheck()`、`:419 autoCheckForUpdates()`。
- 设置页无「自动检查更新」开关，也无间隔选择。移动数据用户无法关闭。

---

## 五、其余代码质量问题

| # | 问题 | 位置 | 后果 |
|---|---|---|---|
| Q-1 | `_receivedBytes` 在验证前累加 | `crawler_core.dart:1634`（校验在 `:1638-1650`） | 显示速度虚高于实际；重试不删坏文件 |
| Q-2 | `_extractBalancedDivContents` 循环内反复全量小写化 HTML | `crawler_core.dart:578` | 列表页卡顿掉帧、低端机 ANR |
| Q-3 | `_parseVideoListPorn91` 每个容器都重跑 `allMatches(html)` | `crawler_core.dart:413-423` | 同上 |
| Q-4 | `releaseMediaPlayer` 对未 prepare 的 MediaPlayer 调 `stop()` | `FloatingWindowService.kt:768-774` | 抛异常被吞 → **`release()` 不执行**，解码资源耗尽后播放无声 |
| Q-5 | 悬浮窗进度条暂停后永久冻死 | `FloatingWindowService.kt:575-590`，Handler 是局部变量无法取消；`:587` `postDelayed` 在 `isPlaying` 为 false 时不再执行 | 暂停后时间与进度定格，恢复播放也不自动重启 |
| Q-6 | `getScreenWidth/Height` 用 `coerceAtLeast` 硬编码最小值 | `FloatingWindowService.kt:810-816` | 小屏/分屏下返回尺寸**大于真实屏幕** → 悬浮窗初始化到屏幕外、吸附位置错误 |
| Q-7 | 悬浮窗双击关闭路径不重置 `lastTapTime` | `FloatingWindowService.kt:359-377` | 残留时间戳导致后续单击误判；且单击/双击语义与播放器（双击=播放暂停）不一致 |
| Q-8 | 悬浮窗 seekBar `max=100`，拖动时算出 `pos` 却丢弃 | `FloatingWindowService.kt:481-510` | 拖动全程无反馈，松手才跳转；3 小时视频粒度误差 108 秒 |
| Q-9 | `stopFloating`/`cleanup` View 移除判断不一致 | `:757` `windowToken != null` vs `:783` `isAttachedToWindow` | `windowToken` 为 null 时跳过 `removeView` → **遮罩残留根因之一** |
| Q-10 | `SurfaceHolder.Callback` 匿名类注册后从不 `removeCallback` | `FloatingWindowService.kt:266-274` | Service 泄漏 |
| Q-11 | `onErrorListener` 返回 false 且无提示 | `FloatingWindowService.kt:563-565`/`:715-717` | 源损坏时悬浮窗保持黑屏，用户以为卡死 |
| Q-12 | `init()` 无幂等（同 G-2） | `app_state.dart:170` | 见 G-2 |
| Q-13 | `checkForUpdates` 遍历期间列表可能被修改 | `followed_authors_service.dart:308-383` | `ConcurrentModificationError` 或跳过作者；修法：开头做快照 |
| Q-14 | 关注作者所有写失败静默吞掉 | `followed_authors_service.dart:437-459`/`:473-496`/`:119-123` | 内存已 `notifyListeners` 显示小红点，重启后**全消失**（用户以为没更新） |
| Q-15 | `_markAutoChecked()` 在检查**开始前**落盘 | `followed_authors_service.dart:419-434`（`:423-424`） | 一次断网 → 时间戳已写 → **6 小时内不再自动检查** |
| Q-16 | `VersionService.checkUpdate()` 并发时静默返回 null | `version_service.dart:130-131` → `settings_page.dart:1177-1189` | 连点两次弹「检查更新失败：请检查网络连接」，完全误报 |
| Q-17 | 改 PIN 失败无任何提示 | `settings_page.dart:954-979`（`:973` `if (saved && mounted)` 无 else） | 用户以为改成功，下次解锁用新 PIN 直接失败 |
| Q-18 | 关闭应用锁失败时不 reset 开关 | `settings_page.dart:937`（unmounted 时直接 return） | UI 开关停在打开位置但实际未启用 |
| Q-19 | PIN 固定盐 + 单次 sha256 + 非常量时间比较 + 无失败锁定 | `pin_service.dart:47-50`/`:32` | 4 位 PIN 离线空间仅 10⁴，真机可无限次尝试 |
| Q-20 | 缓存清理口径不一致 + 清完不刷新 | `cache_service.dart:28` totalCount 不计封面缓存，`:32` totalBytes 却计入；`cache_manager_page.dart:76` 用 `totalCount == 0` 提前 return | 只有封面缓存待清时点「清理选中项」**什么都不做** |
| Q-21 | 安装包校验过弱 + 临时目录永不清理 | `version_service.dart:597`/`:610-611`（仅校验 `length < 100*1024`），函数结束（`:641`）不删 tempDir | 截断 APK（>100KB）直接交给安装器；`systemTemp` 累积 `update_*` 目录 |
| Q-22 | 「删除已完成视频」从不删文件 | `download_page.dart:885` `cancelTask(task.id)` 无 `deleteFile` 参数，但对话框 `:907` 文案是「确定要删除已下载的视频吗？」 | **记录消失、文件仍在**，磁盘空间不释放。最易引发投诉的一类不一致 |
| Q-23 | 滑动删除已完成项弹两次确认框 | `download_page.dart:900-914` `confirmDismiss` + `:915` `onDismissed` 再弹 | 两次对话框，第二个确认后无任何反馈 |
| Q-24 | 取消任务会连续传数据一起删 | `download_manager.dart:616-663` → `deleteFilesForTask`（`:687-704`）→ `deleteTempDirFor`（`:707-718`），而 `download_page.dart:584` 调 `cancelTask` 不传 `deleteFile` | 不勾「同时删除文件」，`<filePath>_temp` 仍被删 → 想重下只能从第 0 个分片开始 |
| Q-25 | `_batchStart` 用 `firstWhere` | `download_page.dart:267-274` | 列表在异步间隙变化时抛 `StateError` |
| Q-26 | `dispose` 不关数据库 | `download_manager.dart:780-783` | 只 `_crawler?.reset()`，无 `_db?.close()` |
| Q-27 | `getVideoDetail` 吞掉所有异常且不留日志 | `crawler_core.dart:1270-1272` 直接 `return null`，连 `onLog` 都不调 | 站点改版后表现为「列表空了/全部下载失败」，日志里什么都没有 |
| Q-28 | 外部备份 JSON 含明文 `appLockEnabled` | `app_state.dart:213-214`/`:306` | 位于 `/Download/91Download/.db/settings_backup.json`，**可被其它 App 读取/篡改**（置 false 即绕过应用锁） |
| Q-29 | `toggleNomedia` 失败但开关照翻 | `app_state.dart:690-708` `catch (_) {}` | 用户以为已生效 |
| Q-30 | 权限分组在 `permanentlyDenied` 时按钮无效 | `app_state.dart:388-414` 不处理该状态 | 点「去授权」无反应；应引导 `openAppSettings()` |

---

## 六、UI 建议

### 播放器 / 悬浮窗
1. **悬浮窗控制栏补齐**（`FloatingWindowService.kt:436-509`）—— 现在只有 后退10秒/播放暂停/前进10秒 三个按钮，全部用 `android.R.drawable.*` 系统图标（`:446`/`:458`/`:467`/`:415`），在深色视频上辨识度差且风格陈旧。
   - 加倍速按钮（复用 `kPlayerSpeedOptions`，`player_glass.dart:7`）—— 内置播放器支持 0.5-2.0x，切到悬浮窗倍速丢失、回来又恢复，状态不连续
   - 加「回到 App」按钮 —— `closeAndReturnToApp()`（`:741-749`）只发广播无 `startActivity`，且 `MainActivity.kt:274-278` 的 `onUserLeaveHint()` 是空实现，双击只是「关闭」，App 仍停在后台
   - 时间文字（`:513-523`）textSize 仅 11f、纯白无阴影，亮画面上几乎不可读
2. **进度条支持拖动预览**（`FloatingWindowService.kt:481-510`）—— `pos` 已算出却丢弃，把 `timeText` 更新放进去即可；`max` 从 100 提到毫秒级
3. **屏幕常亮** —— 内置播放器与悬浮窗均未设 `FLAG_KEEP_SCREEN_ON` / `keepScreenOn`，看长视频时屏幕会按系统超时熄灭。**工程量极小、体感提升明显**
4. **统一两个播放页的手势语言** —— `streaming_page.dart` 只有单击/双击（`:236-237`），而 `download_page.dart` 有单击/双击/横滑/竖滑/长按/锁定（`:1667`/`:1679`/`:1701`/`:1742`/`:1780`/`:1646`）。建议抽成公共 widget 复用 `player_glass.dart` 的 tokens
5. **中央播放键播放中不淡出**（`streaming_page.dart:266-286`，`GlassIconButton(filled: true, size: 52)` 恒定显示）—— 挡住画面主体。建议播放中 1.5 秒后淡出，仅暂停时保留
6. **控件自动隐藏时长不一致** —— `player_glass.dart:30` `autoHideDelay = 4s` vs `download_page.dart:1639` 硬编码 `Duration(seconds: 3)`，统一引用 tokens
7. **悬浮窗缩放无视觉反馈、无保存**（`:283-322`）—— 用户不知道这个手势存在；缩放后尺寸不持久化，下次重置。另 `:305` `newHeight = (newWidth * 9 / 16)` **硬编码 16:9**，竖屏视频会被拉成横条
8. **悬浮窗控件初始常驻** —— `:118` `controlsVisible = true`，但 `showFloatingWindow` 末尾**从未**调 `resetHideControlsTimer()`（`:658`），只有点击（`:366`→`:624`）或 `showControls()`（`:647`）才启动定时器 → 刚出现时控件永久常驻，与「4 秒自动隐藏」设计不符
9. **PiP 能力闲置** —— `updatePipParams` 全仓库无人调用（`pip_service.dart:43`）；`PipPlugin.kt:36-38` enterPip 未设 `setActions`（无播放/暂停/关闭按钮），也未 `setSourceRectHint` → PiP 窗口只能看不能操作

### 下载页
10. **下载中列表项显示封面缩略图**（`download_page.dart:686-696` 目前只有纯文字标题）
11. **进度行补「已下载/总量/预计剩余」**（`:706-742`）—— `task.downloadedBytes`/`totalBytes` 已在维护，`FormatUtils.formatBytes`（`download_manager.dart:21-26`）已存在却在本页完全没用上
12. **错误文案要人话**（`:745-751` 显示 `e.toString()` 原文）—— 换分类文案 + 「详情」展开 + 「复制错误」按钮
13. **删除确认框区分「删记录」和「删文件」**（`:865-887`）—— 「仅移除记录（文件保留）」/「同时删除文件（释放 xxx MB）」
14. **批量删除结果区分文件与记录**（`:597` 永远说「已删除 N 个记录」）
15. **「下载失败 (N)」组头加批量操作**（`:763-791` 目前只有标题）—— 「全部重试」「全部删除」
16. **等待队列可视化** —— `waitingCount`（`download_manager.dart:263`）已存在但界面无体现；`maxConcurrentTasks = 2` 而用户加 10 个任务时，后 8 个停在「等待中」看不到排队序位，易被误认为卡死。建议显示「队列第 N 位」
17. **下载中任务的状态语义先在 UI 上对齐**（承接 P0-4）—— 修好 `_pauseFlag` 之前建议先改成「停止」

### 设置页
18. **下载目录分组加占用/可用空间 + 换目录时的迁移确认框**（`settings_page.dart:227-310`）—— G-1 的用户侧兜底
19. **新增「数据与隐私」分组**（放在「调试设置」之前）承载：搜索历史管理、关注作者管理、清除数据/重置设置
20. **应用锁分组补失败反馈**（`:842-890`）—— 失败次数提示、锁定时长、忘记 PIN 说明
21. **调试设置收纳日志操作**（`:1040-1125`）—— 4 个日志按钮收进 `_LogManagerDialog`（`:1590`）单一入口；`_manageLogs`（`:1504`）递归重弹（`:1559`）改为刷新列表
22. **站点下拉支持删除自定义站点**（`:99-166`）—— `app_state.dart` 只有 `addCustomSite`（`:487-504`），无 remove
23. **切片并发改 Slider/长按连续步进**（`:515-549`）—— 另 `app_state.dart:38-46` 的 `minConcurrentSegments = 1` 与 UI 下限 4 不一致
24. **主题预览改真实色卡**（`:787-810` 目前只是文字）
25. **「跳过此版本」** —— `_showUpdateDialog`（`:1202-1250`）只有「稍后更新」/「立即更新」，`version_service.dart` 无 ignored-version 存储 → 每次启动都提示同一版本

---

## 七、建议落地顺序

按 **确定性缺陷优先 → 数据正确性 → 接线类功能 → 打磨** 排列，每批都可独立编译验证并推送。

**第 1 批 · P0 缺陷（改动小、风险低、全是确定性 bug）**
1. 亮度原生 channel（仅本 App 窗口亮度）+ 去掉空吞异常
2. `MainActivity.kt:133/145/155` 三处 `startService` → `startForegroundService`
3. `download_page.dart` dispose 补 `VolumeController().removeListener()`
4. `_pauseFlag` 真正生效（主循环加检查）
5. 进度回调改按 taskId 分发

**第 2 批 · 数据正确性**
6. `_mergeTsFiles` 按下标→按文件名序号 + 流式拷贝（D-1、D-2）
7. **同作者同标题覆盖：文件名带唯一 ID（D-1b）**
8. 直链 MP4 断点续传 + 失败清理半成品（D-3）
9. AES-128 明确的失败提示（D-4）
10. `endTime` 修正（D-5）+ 进度落盘（D-6）+ 恢复补齐封面/作者/时长（D-7）
11. `DownloadStatus` 越界防护（D-8）

**第 3 批 · 目录持久化与接线**
12. `setDownloadDir` 持久化 + `_crawler` 失效 + 迁移确认（G-1）
13. `AppState.init()` 幂等守卫（G-2，一行）
14. 设置页补搜索历史 / 隐私模式 / 自动检查更新开关（F-1/F-2/F-3）
15. 搜索历史 `remove` 大小写对齐（F-1 附带 bug）

**第 4 批 · 投诉高发的一致性问题**
16. 删除已完成视频真正删文件 + 文案区分（Q-22）+ 去掉双重确认（Q-23）
17. 取消任务不再误删续传数据（Q-24）

**第 5 批 · 打磨**
18. 悬浮窗进度条冻死（Q-5）+ 倍速/回 App 按钮 + keepScreenOn
19. 其余 UI 项按体感挑选

---

## 八、已知未解决项（历史遗留，未计入上述建议）

- **keystore 泄漏**：`android/app/release.keystore` + 明文密码 `123456`。用户表示「先不动，我再想想」。
- **外部存储 `.db` 目录可被其它 App 读取**：暴露面即 Q-28（`settings_backup.json` 中的 `appLockEnabled` 与 `downloadDir`）；用户一直未回复如何处理。
