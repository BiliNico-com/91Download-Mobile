# 待修复清单

按可验证性分组：**确定性缺陷**（能复现/能证明写错）→ **数据正确性**（产出坏文件或丢数据）→ **功能缺口** → **一致性与健壮性**。
每项都带根因位置与修法，括号里是复核状态。

---

## 一、确定性缺陷（7 项）

功能表面存在、实际不工作，或会崩溃/泄漏。全部改动小、风险低。

- [x] **1. 亮度调节是纯 UI 幻影** —— `lib/services/brightness_service.dart:5`
  channel 名 `com.example.download_91/brightness`，但 native 只注册了 3 个通道（`MainActivity.kt:23` OPEN_DIR、`:34` FLOATING、`PipPlugin.kt:21` pip），**亮度处理器从未实现**。左半屏滑动时指示条（`download_page.dart:2258-2260`）正常动、画面亮度纹丝不动，异常被 `:1766` `catch (_) {}` 吞掉。
  **修法**：新建原生 brightness channel，用 `activity.window.attributes.screenBrightness`（仅本 App 窗口，免权限、退出自动还原）。顺带把 `brightness_service.dart:18-53` 五处空吞异常改成 `debugPrint`；`download_page.dart:1343/1573` 的 `_savedBrightness` 赋值后从未被读取，是死状态。**[已复核]**

- [x] **2. Android 12+ 后台调用会闪退** —— `MainActivity.kt:133` / `:145` / `:155`
  `stopNativeFloating` / `switchFloatingVideo` / `sendCommandToService` 三处用 `startService`，只有 `:119` 用了 `startForegroundService`。Service 在 `onCreate` 调 `startForeground`，manifest `:70` 声明 `mediaPlayback`，targetSdk 34 → 后台调用抛 `ForegroundServiceStartNotAllowedException`。
  **修法**：三处改走 `startForegroundService`。注意 `batch_page.dart:296` 会调 `switchVideo`，风险最高。**[已复核]**

- [x] **3. 音量监听器每次进出播放页泄漏一个订阅** —— `download_page.dart:1375`
  initState 注册 `VolumeController().listener(...)`，`dispose()`（`:1872`）没有 `removeListener()`。volume_controller 2.0.8 是单例 + 单订阅，`listener()` 直接覆盖旧的 → 反复进出 N 次泄漏 N 个 EventChannel 订阅。
  **修法**：dispose 补 `VolumeController().removeListener()`。**一行。** **[已复核]**

- [x] **4. 「暂停」按钮是彻底的空操作** —— `crawler_core.dart:1877-1879`
  `pause()` 只写 `_pauseFlag`，而全文件该字段**只有写入、没有任何读取**（`:22` 声明、`:1878` true、`:1882`/`:1887` false）。主循环只检查 `_stopFlag`（`:1418`/`:1421`/`:1438`/`:1503`/`:1506`/`:1522`）。
  症状：UI 显示「已暂停」，后台 32 个分片继续跑完、文件继续长 —— 移动数据下一直在烧流量。
  **修法**：主循环加 `_pauseFlag` 检查并真正挂起。修好之前 UI 上先把按钮改成「停止」走 `cancelTask`，别再撒谎。**[已复核]**

- [x] **5. 并发任务进度回调互相覆盖** —— `crawler_core.dart:37-38`
  `onProgress`/`onOverallProgress` 是共享 CrawlerCore 上的单槽字段，`download_manager.dart:457`/`:469` 直接赋值、`:501`/`:502` 置 null。而 `maxConcurrentTasks` **默认就是 2**（`app_state.dart:41`）。
  症状：任务 A 的进度条显示任务 B 的数据；任务结束时置 null 会让仍在跑的任务卡在某个百分比。
  **修法**：改成按 taskId 分发的 map。**[已复核]**

- [x] **6. 悬浮窗进度条暂停后永久冻死** —— `FloatingWindowService.kt:575-590`
  Handler 是局部变量无法取消；`:587` 的 `postDelayed` 在 `isPlaying` 为 false 时不再执行 → 暂停后时间与进度定格，恢复播放也不自动重启（只有切视频/重新 prepare 才恢复）。`setOnPreparedListener`（`:554`/`:708`）每次都会再调一次，切 N 次视频就有 N 个 Runnable 同时在跑。
  **修法**：Handler 提为成员字段、onDestroy 里 `removeCallbacksAndMessages(null)`、暂停时也用 `currentPosition` 继续刷新。

- [x] **7. `releaseMediaPlayer` 漏掉 `release()`** —— `FloatingWindowService.kt:768-774`
  `stop()` 对未 prepare 的 MediaPlayer 抛 `IllegalStateException`，被外层 `catch(Exception){}` 吞掉 → **`release()` 不执行**，解码器/音频轨道泄漏，多次开关后播放无声。
  **修法**：`stop()` 单独 try 包住，`release()` 放 finally 保证执行。

---

## 二、数据正确性（8 项）

共同特征：**文件已经下完了，但落盘结果不可信，且不报错、都显示「下载完成」**，用户要播放时才发现。

- [x] **8. 同作者 + 同标题的视频互相覆盖**（你报告的）—— `lib/services/download_manager.dart:441-449`
  ```dart
  fileName = '${safeTitle}_$safeAuthor.mp4';   // ← 同作者+同标题 = 同一路径
  ```
  `:440` 注释写「避免同名覆盖」，作者后缀本意就是防撞名，但对**同作者 + 同标题**完全无效。去重键是 `video.id`（`:305`/`:308`），而 id 就是 viewkey（`crawler_core.dart:549`）→ 两个不同视频 ID 不同、都正常入队、都完整下载，只是写同一份字节。
  症状：先下的被静默覆盖；「已完成」出现**两条记录指向同一文件**；删任一条会把另一条一起删。
  **修法**：文件名带上唯一 ID（`标题_作者_viewkey.mp4`），或撞名追加 ` (2)`。已确认无逻辑依赖当前命名格式，只有 `_temp` 后缀约定被用到。**存量文件不处理**（路径存库，改名只对新下载生效）。**[已复核]**

- [x] **9. 合并切片时下标错位 → 产出内容错乱的视频** —— `crawler_core.dart:1752`
  `downloaded[i]` 的 `i` 来自 `dir.list()` 排序后的**列表位置**（`:1738-1741`），不是文件名里的分片序号。零填充命名让它平时侥幸正确，但 `_temp` 里只要有一个非 `seg_*` 残留文件或分片缺口，后续每个下标都错位 → 把失败切片的标记套到错误的文件上。
  **修法**：按文件名解析出的 segment index 匹配。**[已复核]**

- [x] **10. 合并阶段把整个视频读进内存 → 长视频 OOM** —— `crawler_core.dart:1759`
  `await file.readAsBytes()` 逐文件全量读入（`:1773` `sink.add(bytes)`），1GB 片子产生同等内存峰值 → 合并阶段被 OOM 杀掉，而分片其实已下完。另 `:1744` 的 sink 无 try/finally。
  **修法**：`openRead()` 流式拷贝。

- [x] **11. 直链 MP4 不支持断点续传，失败后残留半截文件** —— `crawler_core.dart:1670-1732`
  `_downloadDirectMp4` 用 `_dio.download(...)` 一次拉完，**无 Range 头、无 start 偏移**，失败不删半成品。对比 HLS 路径（`:1595-1667`）有续传校验。即「断点续传」只对 HLS 成立。

- [x] **12. 加密流（AES-128）不解密，静默产出坏文件** —— `config.dart:249-251` 定义了 `aesKeyPattern` 但 `crawler_core.dart` 全文无引用
  `_parseM3u8`（`:1571-1589`）跳过所有 `#` 开头行，`#EXT-X-KEY` 被丢弃，分片按密文落盘后直接拼接 → 进度 100%、显示完成、点开黑屏花屏。
  **修法**：至少检测到 `EXT-X-KEY` 时明确失败提示「受加密保护，暂不支持」；完整修复需拉 key + 解密分片。**当前静默产出垃圾文件是最坏的一种。**

- [x] **13. 已完成任务的 `endTime` 被写成 `startTime`** —— `download_manager.dart:814-816`
  排序键是 `(endTime ?? startTime)`（`:241-251`）→ 重启后「下载于…」显示的是**创建**时间不是完成时间，倒序也错位。直接削弱刚做完的「已完成倒序 + 年月日时分」。

- [x] **14. 恢复已完成记录时丢失封面/作者/时长** —— `download_manager.dart:842-908`
  `_restoreCompletedFromHistory` 只用 `id/url/title` 构造 `VideoInfo`，界面却渲染封面（`download_page.dart:1002`/`1105`）。另 `_saveToHistory`（`crawler_core.dart:1792-1807`）**从不写 `upload_date`**（表里有这列，`:230`）。

- [x] **15. `DownloadStatus` 越界即崩** —— `download_manager.dart:808`
  `DownloadStatus.values[map['status'] as int]`，DB 版本固定 1 且**无 `onUpgrade`**（`:145-188`）。将来枚举增删成员 → 旧库整数越界抛 `RangeError` → 升级后首次打开下载页崩溃，用户只能清数据自救。

---

## 三、功能缺口（4 项）

前三项**投入产出比最高**：服务层完整，只差一个入口/开关。

- [x] **16. 切换下载目录后不持久化、不迁移数据库** —— `app_state.dart:584-587`
  ```dart
  void setDownloadDir(String dir) { downloadDir = dir; notifyListeners(); }  // 没有 _saveSettings()
  ```
  隔壁每个 setter 都有；且 `downloadDir` 在 `_loadSettings`（`:322`）/`_saveSettings`（`:347`）的键列表里**都不存在**。`initDownloadDir()`（`:428-477`）每次启动硬编码回退（`:434`）；`_crawler` 懒建缓存不失效（`:145-167`）。
  症状：重启后路径回退、下载仍写默认目录，且**旧目录 `.db/` 下的下载历史与关注作者「整个消失」** —— 用户会认为记录全丢。
  **修法**：加 `_saveSettings()` + `_crawler = null`，把 `downloadDir` 纳入持久化与备份，改目录时给「迁移 / 保留原位」选择。**[已复核]**

- [x] **17. `AppState.init()` 无幂等守卫** —— `app_state.dart:170`
  `settings_page.dart:32-36` 每次挂载都 `Future.microtask(() => init())`，而 `init()` 首行无 `if (initialized) return;`（`initialized` 字段 `:50` 只在末尾置位）。
  症状：从其它路由 push/pop 回设置页会重复 `requestPermissions()`（反复弹权限框）、`_restoreSettingsFromExternal()`（再覆盖内存设置）、`restorePendingTasks()`（`:188`，可能重复恢复已完成任务）。
  **修法**：首行加守卫。**一行。** **[已复核]**

- [x] **18. 搜索历史服务完全没有 UI 入口** —— `lib/services/search_history_service.dart:8-82`
  服务完整（`add/remove/clear/entries`，上限 20），`app_state.dart:124` 实例化、`:170` 加载，但 `settings_page.dart` 全文无引用、也无独立页面 → 到 20 条上限后无法查看/单删/清空。
  **附带 bug**：`:54` `add()` 用 `toLowerCase()` 去重，`:68` `remove()` 用 `e == keyword` 精确匹配 → 历史里有 "Abc" 时删 "abc" 删不掉。**[已复核]**

- [x] **19. 隐私模式 / 自动检查更新已实现但无开关**
  隐私模式：`app_state.dart:99` 字段、`:676 togglePrivacyMode()`、`:355` 已持久化，**设置页无开关**。
  自动检查更新：`followed_authors_service.dart:386`/`:389 autoCheckInterval = Duration(hours: 6)` **硬编码**，移动数据用户无法关闭。

---

## 四、一致性与健壮性（17 项）

单条影响小于上面，但累计起来是「这 App 有点糙」的观感来源。多数是低成本修复。

### 删除语义（投诉高发）
- [x] **20. 「删除已完成视频」从不删文件** —— `download_page.dart:885` `cancelTask(task.id)` 没传 `deleteFile`，但对话框 `:907` 文案写着「确定要删除已下载的视频吗？」→ **记录消失、文件仍在**，磁盘不释放。
- [x] **21. 滑动删除已完成项弹两次确认框** —— `:900-914` `confirmDismiss` + `:915` `onDismissed` 再弹一次；第二个确认后无任何反馈。
- [x] **22. 取消任务会连续传数据一起删** —— `download_manager.dart:616-663` → `deleteFilesForTask`（`:687-704`）→ `deleteTempDirFor`（`:707-718`）；`download_page.dart:584` 调 `cancelTask` 不传 `deleteFile`，但 `<filePath>_temp` 仍被删 → 想重下只能从第 0 个分片开始。
- [x] **23. 批量删除结果不分文件与记录** —— `download_page.dart:597` 永远说「已删除 N 个记录」。

### 进度与状态
- [x] **24. `_receivedBytes` 在验证前累加** —— `crawler_core.dart:1634`（校验在 `:1638-1650`）→ 显示速度虚高于实际；重试不删坏文件。
- [x] **25. 分片进度不落盘，杀进程后从 0 重爬** —— `download_manager.dart:145-188` 表里无 progress/bytes 列，`_saveTaskToDb`（`:736-764`）从不写进度。
- [x] **26. `_batchStart` 用 `firstWhere` 可能抛 `StateError`** —— `download_page.dart:267-274`。
- [x] **27. `dispose` 不关数据库** —— `download_manager.dart:780-783`。

### 悬浮窗
- [x] **28. `getScreenWidth/Height` 用 `coerceAtLeast` 硬编码最小值** —— `FloatingWindowService.kt:810-816`。小屏/分屏下返回尺寸**大于真实屏幕** → 悬浮窗初始化到屏幕外、吸附位置错误。
- [x] **29. View 移除判断不一致 → 遮罩残留根因之一** —— `:757` `windowToken != null` vs `:783` `isAttachedToWindow`；`windowToken` 为 null 时跳过 `removeView`。
- [x] **30. `SurfaceHolder.Callback` 注册后从不 `removeCallback`** —— `:266-274` → Service 泄漏。
- [x] **31. 双击关闭路径不重置 `lastTapTime`** —— `:359-377` → 残留时间戳导致后续单击误判；且单击/双击语义与播放器（双击=播放暂停）不一致。
- [x] **32. `onErrorListener` 返回 false 且无提示** —— `:563-565`/`:715-717` → 源损坏时保持黑屏，用户以为卡死。
- [x] **33. seekBar `max=100`，拖动时算出 `pos` 却丢弃** —— `:481-510` → 拖动全程无反馈；3 小时视频误差 108 秒。

### 关注作者 / 更新
- [x] **34. `checkForUpdates` 遍历期间列表可能被修改** —— `followed_authors_service.dart:308-383` 串行 await 中 `unfollow()`（`:259`）会 `removeWhere` → `ConcurrentModificationError` 或跳过作者。修法：开头做快照。
- [x] **35. 关注作者所有写失败静默吞掉** —— `:437-459`/`:473-496`/`:119-123` → 内存已显示小红点，重启后全消失（用户以为没更新）。
- [x] **36. `_markAutoChecked()` 在检查开始前落盘** —— `:419-434`（`:423-424`）→ 一次断网即被节流 **6 小时内不再自动检查**。修法：仅在至少一个作者成功后再落盘。
- [x] **37. `checkUpdate()` 并发时静默返回 null** —— `version_service.dart:130-131` → `settings_page.dart:1177-1189` 把 null 显示成「检查更新失败：请检查网络连接」，连点两次即误报。
- [x] **38. 安装包校验过弱 + 临时目录永不清理** —— `version_service.dart:597`/`:610-611` 仅校验 `length < 100*1024`，`:641` 不删 tempDir → 截断 APK 直接交给安装器；`systemTemp` 累积 `update_*`。

### 应用锁
- [x] **39. 改 PIN 失败无任何提示** —— `settings_page.dart:954-979`（`:973` `if (saved && mounted)` 无 else）→ 用户以为改成功，下次解锁失败。
- [x] **40. 关闭应用锁失败时不 reset 开关** —— `:937` unmounted 时直接 return → 开关停在打开位置但实际未启用。
- [x] **41. PIN 强度与防爆破** —— `pin_service.dart:47-50` 固定盐 `'91download_salt'` + 单次 sha256；`:32` 非常量时间比较；无失败计数/锁定 → 4 位 PIN 离线空间仅 10⁴，真机可无限次尝试。

### 其他
- [x] **42. 缓存清理口径不一致 + 清完不刷新** —— `cache_service.dart:28` `totalCount` 不计封面缓存、`:32` `totalBytes` 却计入；`cache_manager_page.dart:76` 用 `totalCount == 0` 提前 return → 只有封面缓存待清时点「清理选中项」**什么都不做**。
- [x] **43. `getVideoDetail` 吞掉所有异常且不留日志** —— `crawler_core.dart:1270-1272` 直接 `return null`，连 `onLog` 都不调 → 站点改版后表现为「列表空了/全部下载失败」，日志里什么都没有。
- [x] **44. 列表页性能：循环内反复全量小写化 HTML** —— `crawler_core.dart:578` `html.toLowerCase()` 写在 `while` 内；`:413-423` 每个容器都重跑 `allMatches(html)` → 列表页卡顿掉帧、低端机 ANR。
- [x] **45. 外部备份 JSON 含明文 `appLockEnabled`** —— `app_state.dart:213-214`/`:306`，位于 `/Download/91Download/.db/settings_backup.json`，**可被其它 App 读取/篡改**（置 false 即绕过应用锁）。
- [x] **46. `toggleNomedia` 失败但开关照翻** —— `app_state.dart:690-708` `catch (_) {}` → 用户以为已生效。
- [x] **47. 权限分组在 `permanentlyDenied` 时按钮无效** —— `app_state.dart:388-414` 不处理该状态 → 点「去授权」无反应，应引导 `openAppSettings()`。

---

## 汇总

| 分类 | 数量 |
|---|---|
| 一、确定性缺陷 | 7 |
| 二、数据正确性 | 8 |
| 三、功能缺口 | 4 |
| 四、一致性与健壮性 | 17（编号 20–47，其中 26/27 等合并计数） |
| **合计** | **约 47 项** |

**建议动手顺序**（每批可独立编译验证 + 推送）：
1. 第 1 批 = 一、确定性缺陷 1–7（改动小、全是确定 bug）
2. 第 2 批 = 二、数据正确性 8–15（产出坏文件/丢数据）
3. 第 3 批 = 三、功能缺口 16–19
4. 第 4 批 = 四 中删除语义与进度类 20–25
5. 第 5 批 = 其余打磨

---

## 附：已知未解决项（历史遗留，未计入上表）

- **keystore 泄漏**：`android/app/release.keystore` + 明文密码 `123456`。你说「先不动，我再想想」。
- **外部存储 `.db` 目录可被其它 App 读取**：暴露面即上面第 45 项；一直未决定如何处理。
