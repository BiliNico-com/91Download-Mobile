# 任务归档：91Download-Mobile 下载进度条修复

> 归档时间：2026-11-07
> 项目根目录：`D:\91\91Download-Mobile-1.0.6.505`
> 产物：`build\app\outputs\flutter-apk\app-debug.apk`（180,904,115 字节，2026-11-07 14:12:29）
> 说明：本项目**不是 git 仓库**，无提交记录可追溯，故以本文档记录改动。

---

## 一、核心任务与结论

**任务**：修复下载进度条丢失（下载中进度条不实时走动、暂停后整条消失）。

**根因**：下载控制句柄错位。`downloadVideo` 内部自建 `DownloadControl`，而下载管理器取到的是 Zone 外的兜底句柄，两者不是同一对象 → `onProgress` / `onOverallProgress` 回调永远不触发，UI 进度恒为 0；`pause` / `stop` 同样打不到真实任务。

**结果**：已修复，并在雷电模拟器（emulator-5554）上端到端验证通过。

| 验证项 | 结果 | 证据 |
|---|---|---|
| 进度条实时递增 | ✅ | mock 站点 40 切片：截到 `5.0% 下载中 2/40` → 后续 `100.0% 下载中 40/40`，非一次性跳满 |
| 暂停后进度条保留 | ✅ | 暂停显示灰色进度条 + `100.0% 已暂停`（改前整条消失） |
| 完整下载落盘 | ✅ | 真实站点 91lol.im 视频 1257474 → `/sdcard/Download/91Download/[原创] 无广-贵州遵义母狗人妻续集_guizhou9991_1257474.mp4`，15,999,552 字节，已下载列表正常 |

---

## 二、代码改动清单（均已在位，可逐行核对）

### 1. `lib\crawler\crawler_core.dart`

- `:176` `DownloadControl beginDownload()` —— 新建句柄的同时登记为兜底句柄：
  `_zoneControl = ctrl; return ctrl;`（`:178`）
- `:1721` `Future<bool> downloadVideo(VideoInfo video, String savePath, {DownloadControl? ctrl})` —— 新增可选命名参数 `ctrl`；`:1726` `return runWithControl(handle, () => _downloadVideoInner(...))`，外部可注入句柄。
- `:187` `runWithControl<T>(...)` —— 句柄注入辅助方法。

### 2. `lib\services\download_manager.dart`

- `:484` `final Map<String, DownloadControl> _taskControls = {};` —— taskId → 该任务独占句柄。
- `:506` `taskCtrl = _crawler!.createControl();`（`_startDownload` 内、try 之前创建并登记）
- `:556` `final ctrl = taskCtrl ??= _crawler!.createControl();` —— 原 `_crawler!.control` 兜底。
- 调用处改为 `_crawler!.downloadVideo(detail, savePath, ctrl: ctrl)`。
- finally 用 `taskCtrl` 清回调（`onProgress` / `onOverallProgress` / `onLog`），非 paused 时 `reset()`，再 `_taskControls.remove(task.id)`。
- `:710` `pauseTask` → `:716` `_taskControls[taskId]?.pause();`
- `:735` `retryTask` → `:746` `_taskControls[taskId]?.reset();`
- `:783`（cancelTask 内）`_taskControls[taskId]?.stop();` —— 不再误停并发中的其他任务。
- `:959` `dispose()` —— 先 `for (final ctrl in _taskControls.values) ctrl.stop();` 再 `clear()`。

### 3. `lib\pages\download_page.dart`

- `:730` 进度条渲染条件由「仅 downloading」放宽为：downloading，或 (paused | pending) 且 `task.progress > 0`。
- `:738` 非 downloading 时 `valueColor` 用 `AlwaysStoppedAnimation<Color>(Colors.grey.shade400)`。
- 进度文字改为百分比常驻：`'${(task.progress * 100).toStringAsFixed(1)}%' + progressText`。

---

## 三、附带修复：设置页自定义站点崩溃

**症状**：添加自定义站点后，设置页 `DropdownButton` 断言崩溃
`There should be exactly one item with [DropdownButton]'s value: http://127.0.0.1:8099`。

**根因**：`_saveSettings()` 从不写 `customSites` 这个键，重启后 `currentSite` 与站点列表对不上。

**改动**：
- `lib\services\app_state.dart:440` `prefs.setStringList('customSites', customSites)` —— 补写。
- `lib\services\app_state.dart:354` `customSites = prefs.getStringList('customSites') ?? [];` —— `_loadSettings()` 兼容回填。
- `lib\services\app_state.dart:590` `allSites` 改为 Set 去重；`:595` `addCustomSite()` 去重兜底。
- `lib\pages\settings_page.dart:159-160` 下拉 value 做存在性校验。
- `lib\pages\settings_page.dart:39` 弹窗 controller 改由 State 持有（`:207` 局部 controller 已替换），修 `_dependents.isEmpty` 红屏。

---

## 四、构建环境改造（使 APK 可编译）

原始压缩包缺 Android 资源与构建配置，以下为新增/修改项：

| 文件 | 改动 |
|---|---|
| `android\local.properties` | 补 `sdk.dir=D:/Android/Sdk`；`flutter.sdk=C:\\flutter\\flutter` |
| `android\gradle.properties` | **新建**：`org.gradle.jvmargs=-Xmx4G -XX:MaxMetaspaceSize=2G -XX:+HeapDumpOnOutOfMemoryError` / `android.useAndroidX=true` / `android.enableJetifier=true` |
| `android\settings.gradle` | `org.jetbrains.kotlin.android` 由 `1.9.22` → **`1.7.10`**（AGP 7.4.2 自带 D8 无法 dex 化 kotlin-stdlib 1.9.22，报 `ERROR:D8: com.android.tools.r8.kotlin.H`）。备份：`settings.gradle.bak` |
| `android\app\src\main\res\values\styles.xml` | **新建**：LaunchTheme（`@android:style/Theme.Light.NoTitleBar`，windowBackground=white，windowFullscreen=true）+ NormalTheme |
| `android\app\src\main\res\drawable\ic_launcher.xml` | **新建**：纯矢量 vector drawable 图标（避免引入二进制 png） |
| `android\app\src\main\AndroidManifest.xml` | `android:icon` → `@drawable/ic_launcher`；activity/service 改为全限定名 `com.bilinico.download_91.MainActivity` / `com.bilinico.download_91.FloatingWindowService`（namespace 是 com.example.download_91，相对名会解析错） |
| `android\gradlew` / `gradlew.bat` / `gradle\` | 原压缩包缺失，构建时自动生成 |

**构建命令（MSYS2 bash）**：

```bash
export JAVA_HOME=/d/Android/jdk
export PATH="/d/Android/jdk/bin:/c/flutter/flutter/bin:$PATH"
export ANDROID_HOME=/d/Android/Sdk
export ANDROID_SDK_ROOT=/d/Android/Sdk
cd /d/91/91Download-Mobile-1.0.6.505 && flutter build apk --debug
```

耗约 135 秒，产出 `√ Built build\app\outputs\flutter-apk\app-debug.apk`。

---

## 五、安装与测试方法（复现用）

```bash
ADB=/d/Android/Sdk/platform-tools/adb.exe
$ADB -s emulator-5554 install -r -t build/app/outputs/flutter-apk/app-debug.apk
# applicationId 与 MainActivity 包名不同，必须用全限定名启动
$ADB -s emulator-5554 shell am start -n com.example.download_91/com.bilinico.download_91.MainActivity
```

- 首次启动会弹「允许访问照片和媒体文件」→ 点「允许」(1080x1920 坐标 825,1158)。
- **测试站点**：真实站点 91lol.im 可直连（本机 DNS 正常）；`jiuse.icu` / `91porny.com` / `91porn.com` 在本机解析到 127.0.0.1，需代理，无法直接测。
- **本地 mock 站点**：`D:\91\mock_server.py`（监听 8099，40 切片 m3u8）。启动：
  ```
  "C:\Users\Administrator\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe" "D:/91/mock_server.py"
  adb reverse tcp:8099 tcp:8099
  ```
  然后在 App 设置页「手动输入网址」填 `http://127.0.0.1:8099`。
  ⚠️ m3u8 内切片地址必须是**相对路径** `segN.ts`；写绝对路径 `/media/segN.ts` 会被 `_parseM3u8`（`crawler_core.dart:1877`）拼成 `/media//media/segN.ts` 全部 404。

**关键 UI 坐标（1080x1920）**：底部导航 批量(115,1796) / 搜索(320,1796) / 已关注(537,1796) / 已下载(720,1796) / 设置(960,1796)；设置页 手动输入网址(540,670)；下载列表 暂停/继续(800,728)、停止(940,728)。

---

## 六、已知未修问题（非本次改动引入）

1. **下载页顶部布局溢出** —— `BOTTOM OVERFLOWED BY 4.0 PIXELS` 黄黑条纹。
2. **手动输网址弹窗偶发红屏** —— `'_dependents.isEmpty': is not true`（已在设置页改 controller 持有方缓解，未彻底消除）。
3. **偶发原生崩溃** —— `Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0xdead0000 in tid (DartWorker)`。
4. **jiuse 模板列表加载不出来（网络层问题，非代码 bug）** —— 已确认：`_parseVideoListJiuse`（`crawler_core.dart:576`）分发正确、Cloudflare 误判逻辑不触发（`_isCloudflareChallenge` 仅 403/503 生效）、代理链路内容正常（24 个 colVideoList）。真正原因是 `DioException [connection timeout] ... (URL=https://jiuse.icu/video)`：**Dart HttpClient / Dio 不读 Android 系统代理**，而本机直连 jiuse.icu 必然超时。
   可行的绕过方案（本次已跑通链路，未固化到代码）：SNI 透明代理 `D:\91\sni_proxy.py` + `iptables -t nat -A OUTPUT -m owner --uid-owner 10048 -p tcp --dport 443 -j REDIRECT --to-ports 8443`。若要产品化，需在 `_initDio()`（`crawler_core.dart:337`）里支持 App 内代理配置。
5. **jiuse 解析器与测试文件**：`lib\crawler\config.dart:42-43/219/406-427`、`lib\crawler\crawler_core.dart:547/576/1174`、`lib\pages\batch_page.dart:761`，配套 `test\jiuse_parse_test.dart` / `jiuse_url_test.dart` / `jiuse_full_test.dart` 保留。

---

## 七、本次任务未做的事

- 未执行 `flutter analyze` 全量复查（改动前基线为 42 issues，无 error，全为既有 warning/info）。
- 未打 release 包（`android\app\release.keystore` 存在但未配置签名构建流程）。
- 未向 jiuse 类站点做代理支持的产品化改造。
