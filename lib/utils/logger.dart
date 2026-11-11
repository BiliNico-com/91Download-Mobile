import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// 日志级别
///
/// 历史调用点都传字符串（info / warn / error / debug），这里集中定义常量，
/// 避免各处手写拼错。
class LogLevel {
  static const String debug = 'debug';
  static const String info = 'info';
  static const String warn = 'warn';
  static const String error = 'error';
}

/// 应用运行日志
///
/// 设计目标（配合「把手机上操作与下载全过程都记下来，出问题直接提交日志」）：
/// 1. 时间戳带日期（yyyy-MM-dd HH:mm:ss.SSS），跨天跨会话都能对齐；
/// 2. 分级：debug / info / warn / error；
/// 3. 缓冲写盘：高频调用（下载分块、爬虫解析）先进内存队列，定时批量落盘，
///    不再每行一次同步 IO，避免卡 UI；
/// 4. 会话头：启动时写入 App 版本、设备型号、Android 版本等，
///    用户发来的一份日志自身就带齐了排查所需的环境信息；
/// 5. 崩溃捕获：Flutter 框架异常与未捕获的异步异常都写入并立即落盘；
/// 6. 轮转与上限：单文件超过上限自动换新文件，目录只保留最近若干个；
/// 7. 一键提交：exportForShare 导出一份快照文件，配合 share_plus 以文件形式分享。
class Logger {
  static final Logger _instance = Logger._internal();
  factory Logger() => _instance;
  Logger._internal();

  /// 单文件大小上限，超过后自动开新文件
  static const int maxFileBytes = 3 * 1024 * 1024;

  /// 日志目录保留的最大文件数（含当前文件）
  static const int maxLogFiles = 6;

  /// 内存缓冲最大行数，超出丢弃最旧的，防止长期运行吃内存
  static const int maxBufferLines = 4000;

  /// 缓冲落盘间隔
  static const Duration flushInterval = Duration(milliseconds: 800);

  bool _enabled = false;
  File? _logFile;
  String? _logPath;
  String? _logDirPath;

  final List<String> _buffer = [];
  Timer? _flushTimer;
  bool _flushing = false;
  bool _crashHooksInstalled = false;

  /// 因缓冲溢出丢弃的行数，下次落盘时说明一次
  int _droppedLines = 0;

  /// 当前会话的环境信息块（写入文件头）
  String? _sessionHeader;

  bool get enabled => _enabled;
  String? get logPath => _logPath;

  /// 缓冲中尚未落盘的行数
  int get bufferedLines => _buffer.length;

  /// 当前会话环境信息（分享文案里用）
  String get sessionSummary => (_sessionHeader ?? '').trim();

  // ==================== 生命周期 ====================

  /// 初始化日志。enable 为 false 时只关开关，不动已有文件。
  Future<void> init(bool enable) async {
    _enabled = enable;
    if (!enable) {
      _flushTimer?.cancel();
      _flushTimer = null;
      return;
    }
    if (_logFile != null) {
      // 已初始化过（用户中途重新打开开关），续写同一个文件
      flushSync();
      return;
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/logs');
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }
      _logDirPath = logDir.path;

      final now = DateTime.now();
      final fileName = 'run_${DateFormat('yyyyMMdd_HHmmss').format(now)}.log';
      _logFile = File('${logDir.path}/$fileName');
      _logPath = _logFile!.path;

      _sessionHeader = await _buildSessionHeader();
      await _logFile!.writeAsString(_sessionHeader!, flush: true);

      installCrashHandlers();
      await _pruneOldFiles();
      if (_buffer.isNotEmpty) flushSync();
    } catch (e) {
      _enabled = false;
      print('Logger init failed: $e');
    }
  }

  /// 切换开关
  Future<void> toggle(bool enable) async {
    if (enable && !_enabled) {
      await init(true);
      return;
    }
    _enabled = enable;
    if (!enable) {
      flushSync();
      _flushTimer?.cancel();
      _flushTimer = null;
    }
  }

  /// 重建会话头（站点、下载目录变化时由 AppState 调用）
  Future<void> rebindSessionContext() async {
    if (!_enabled || _logFile == null) return;
    _sessionHeader = await _buildSessionHeader();
    writeRaw('\n—— 会话信息更新 ——\n${_sessionHeader!.trim()}\n\n', flushNow: true);
  }

  // ==================== 写入 ====================

  /// 写入日志（异步签名，兼容历史调用点）
  Future<void> log(String tag, String message, {String level = LogLevel.info}) async {
    if (!_enabled) return;
    _appendLine(_formatLine(tag, level, message));
  }

  /// 写入日志（同步调用点用，实际只进内存缓冲）
  ///
  /// 名称沿用历史的 logSync，但不再每行同步写磁盘：
  /// 按 flushInterval 批量落盘，避免高频日志卡住 UI。
  void logSync(String tag, String message, {String level = LogLevel.info}) {
    if (!_enabled) return;
    _appendLine(_formatLine(tag, level, message));
  }

  /// 用户操作打点（手机上点了什么）
  ///
  /// 单独用 UI 作 tag，在日志里搜 [UI] 就能看到完整操作轨迹。
  void mark(String action, [String detail = '']) {
    if (!_enabled) return;
    _appendLine(_formatLine('UI', LogLevel.info, detail.isEmpty ? action : '$action | $detail'));
  }

  /// 环境变化打点（站点切换、下载目录迁移等）
  void context(String key, String value) {
    if (!_enabled) return;
    _appendLine(_formatLine('Context', LogLevel.info, '$key = $value'));
  }

  /// 网络请求打点（由 Dio 拦截器调用）
  void network(String message, {String level = LogLevel.info}) {
    if (!_enabled) return;
    _appendLine(_formatLine('Net', level, message));
  }

  /// 直接写入原始文本（不做级别与时间戳加工）
  void writeRaw(String text, {bool flushNow = false}) {
    if (!_enabled || text.isEmpty) return;
    _buffer.add(text.endsWith('\n') ? text : '$text\n');
    if (flushNow) {
      flushSync();
    } else {
      _scheduleFlush();
    }
  }

  // ==================== 落盘 ====================

  void _appendLine(String line) {
    if (!_enabled) return;
    _buffer.add(line);
    if (_buffer.length > maxBufferLines) {
      final drop = _buffer.length - maxBufferLines;
      _buffer.removeRange(0, drop);
      _droppedLines += drop;
    }
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_flushTimer != null || _flushing) return;
    _flushTimer = Timer(flushInterval, () {
      _flushTimer = null;
      flushSync();
    });
  }

  /// 同步把缓冲写进文件
  void flushSync() {
    if (_flushing) return;
    final file = _logFile;
    if (!_enabled || file == null || _buffer.isEmpty) return;
    _flushing = true;
    try {
      final text = _takeBufferText();
      file.writeAsStringSync(text, mode: FileMode.append, flush: true);
      _rotateIfNeeded();
    } catch (e) {
      print('Logger flushSync failed: $e');
    } finally {
      _flushing = false;
    }
  }

  /// 异步落盘（分享、清空、切后台时用）
  Future<void> flush() async {
    if (_flushing) return;
    final file = _logFile;
    if (!_enabled || file == null || _buffer.isEmpty) return;
    _flushing = true;
    try {
      final text = _takeBufferText();
      await file.writeAsString(text, mode: FileMode.append, flush: true);
      _rotateIfNeeded();
    } catch (e) {
      print('Logger flush failed: $e');
    } finally {
      _flushing = false;
    }
  }

  String _takeBufferText() {
    final sb = StringBuffer();
    if (_droppedLines > 0) {
      sb.writeln('[${_fmtFull(DateTime.now())}][Logger][warn] 缓冲溢出，已丢弃较早的 $_droppedLines 行');
      _droppedLines = 0;
    }
    for (final line in _buffer) {
      sb.write(line);
      if (!line.endsWith('\n')) sb.write('\n');
    }
    _buffer.clear();
    return sb.toString();
  }

  /// 单文件超过上限后换新文件，并清理最旧的
  void _rotateIfNeeded() {
    try {
      final file = _logFile;
      final dirPath = _logDirPath;
      if (file == null || dirPath == null || !file.existsSync()) return;
      if (file.lengthSync() < maxFileBytes) return;

      final now = DateTime.now();
      final fileName = 'run_${DateFormat('yyyyMMdd_HHmmss').format(now)}.log';
      final next = File('$dirPath/$fileName');
      _logFile = next;
      _logPath = next.path;
      final header = _sessionHeader ?? '';
      next.writeAsStringSync(
        '${header.trim()}\n—— 上一个日志文件已达上限，转到本文件 ——\n\n',
        flush: true,
      );
      _pruneOldFiles();
    } catch (e) {
      print('Logger rotate failed: $e');
    }
  }

  Future<void> _pruneOldFiles() async {
    try {
      final dirPath = _logDirPath;
      if (dirPath == null) return;
      final dir = Directory(dirPath);
      if (!dir.existsSync()) return;
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.log'))
          .toList();
      if (files.length <= maxLogFiles) return;
      files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
      final removeCount = files.length - maxLogFiles;
      for (var i = 0; i < removeCount; i++) {
        try {
          files[i].deleteSync();
        } catch (_) {}
      }
    } catch (e) {
      print('Logger prune failed: $e');
    }
  }

  String _formatLine(String tag, String level, String message) {
    final ts = _fmtFull(DateTime.now());
    final normalized = message.replaceAll('\r', '');
    // 多行消息（异常堆栈）每行缩进，便于区分一条记录的边界
    final body = normalized.contains('\n')
        ? normalized.split('\n').map((l) => '    $l').join('\n')
        : normalized;
    return '[$ts][$tag][$level] $body\n';
  }

  String _fmtFull(DateTime dt) => DateFormat('yyyy-MM-dd HH:mm:ss.SSS').format(dt);

  // ==================== 会话头 ====================

  Future<String> _buildSessionHeader() async {
    final sb = StringBuffer();
    final now = DateTime.now();
    sb.writeln('========== 91Download 运行日志 ==========');
    sb.writeln('会话开始: ${_fmtFull(now)}');
    sb.writeln('时区: ${now.timeZoneName} (UTC+${now.timeZoneOffset.inHours})');
    try {
      final pkg = await PackageInfo.fromPlatform();
      sb.writeln('App: ${pkg.appName} ${pkg.version}+${pkg.buildNumber} (${pkg.packageName})');
    } catch (_) {
      sb.writeln('App: 版本信息读取失败');
    }
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        sb.writeln('设备: ${a.manufacturer} ${a.model} | Android ${a.version.release} (SDK ${a.version.sdkInt}) | ${a.isPhysicalDevice ? "真机" : "模拟器"}');
      } else if (Platform.isIOS) {
        final i = await info.iosInfo;
        sb.writeln('设备: ${i.name} | iOS ${i.systemVersion}');
      }
    } catch (_) {
      sb.writeln('设备: 设备信息读取失败');
    }
    sb.writeln('----------------------------------------');
    sb.writeln();
    return sb.toString();
  }

  /// 记录当前站点、下载目录等业务上下文
  Future<void> logEnvironment({
    String? site,
    String? siteType,
    String? downloadDir,
    String? theme,
    int? maxConcurrentTasks,
    int? maxConcurrentSegments,
    bool? saveHtml,
  }) async {
    if (!_enabled) return;
    final parts = <String>[];
    if (site != null) parts.add('站点=$site');
    if (siteType != null) parts.add('类型=$siteType');
    if (downloadDir != null) parts.add('下载目录=$downloadDir');
    if (theme != null) parts.add('主题=$theme');
    if (maxConcurrentTasks != null) parts.add('并发任务=$maxConcurrentTasks');
    if (maxConcurrentSegments != null) parts.add('并发分片=$maxConcurrentSegments');
    if (saveHtml != null) parts.add('保存HTML=$saveHtml');
    if (parts.isEmpty) return;
    writeRaw('[${_fmtFull(DateTime.now())}][Env][info] ${parts.join(" | ")}\n');
    await flush();
  }

  // ==================== 崩溃捕获 ====================

  void installCrashHandlers() {
    if (_crashHooksInstalled) return;
    _crashHooksInstalled = true;

    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      try {
        final extra = details.informationCollector?.call().join('\n') ?? '';
        logSync(
          'Crash',
          '${details.exceptionAsString()}\n${details.stack ?? ''}\n${extra}',
          level: LogLevel.error,
        );
        flushSync();
      } catch (_) {}
      previousOnError?.call(details);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      try {
        logSync('Crash', '未捕获异常: $error\n$stack', level: LogLevel.error);
        flushSync();
      } catch (_) {}
      // 返回 false：仍然打印到控制台，便于开发时定位
      return false;
    };

    // 切后台时补一次落盘，降低进程被回收时丢日志的概率
    WidgetsBinding.instance.addObserver(_LifecycleFlusher());
  }

  // ==================== 读取与管理 ====================

  /// 获取当前日志文件内容
  Future<String> getLogContent() async {
    await flush();
    final file = _logFile;
    if (file == null || !await file.exists()) {
      return '暂无日志';
    }
    try {
      return await file.readAsString();
    } catch (e) {
      try {
        final bytes = await file.readAsBytes();
        return String.fromCharCodes(bytes);
      } catch (e2) {
        return '日志读取失败: $e2';
      }
    }
  }

  /// 只取最后 tailLines 行（日志中心预览用，避免整文件读进内存）
  Future<String> getLogTail({int tailLines = 400}) async {
    final content = await getLogContent();
    if (content == '暂无日志' || content.isEmpty) return content;
    final lines = content.split('\n');
    if (lines.length <= tailLines) return content;
    return '...（仅显示最后 $tailLines 行，共 ${lines.length} 行）\n${lines.sublist(lines.length - tailLines).join('\n')}';
  }

  /// 清空日志（删除整个日志目录并按需重建当前文件）
  Future<void> clearLogs() async {
    try {
      flushSync();
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/logs');
      if (await logDir.exists()) {
        await logDir.delete(recursive: true);
      }
      _logFile = null;
      _logPath = null;
      _buffer.clear();
      _droppedLines = 0;
      if (_enabled) {
        await init(true);
      }
    } catch (e) {
      print('Clear logs failed: $e');
    }
  }

  /// 日志目录下的所有日志文件（最新在前）
  Future<List<File>> getAllLogFiles() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/logs');
      if (!await logDir.exists()) {
        return [];
      }
      final files = <File>[];
      await for (final entity in logDir.list()) {
        if (entity is File && entity.path.endsWith('.log')) {
          files.add(entity);
        }
      }
      files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      return files;
    } catch (e) {
      print('Get log files failed: $e');
      return [];
    }
  }

  Future<bool> deleteLogFile(String filePath) async {
    try {
      if (_logPath == filePath) {
        // 不让删除正在写的文件，否则后续日志全部丢失
        return false;
      }
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (e) {
      print('Delete log file failed: $e');
      return false;
    }
  }

  Future<int> deleteAllSavedLogs() async {
    try {
      flushSync();
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/logs');
      if (!await logDir.exists()) {
        return 0;
      }
      int count = 0;
      final keepPath = _logPath;
      await for (final entity in logDir.list()) {
        if (entity is File && entity.path.endsWith('.log')) {
          if (entity.path == keepPath) continue;
          await entity.delete();
          count++;
        }
      }
      return count;
    } catch (e) {
      print('Delete all saved logs failed: $e');
      return 0;
    }
  }

  /// 保存日志到指定目录，返回 (路径, 错误信息)
  Future<(String?, String?)> saveToDirectoryWithError(String targetDir) async {
    try {
      await flush();
      final file = _logFile;
      if (file == null || !await file.exists()) {
        return (null, '日志文件不存在: ${_logPath ?? "未初始化"}');
      }
      final bytes = await file.readAsBytes();
      final now = DateTime.now();
      final fileName = '91download_log_${DateFormat('yyyyMMdd_HHmmss').format(now)}.txt';

      final dir = Directory(targetDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final targetPath = targetDir.endsWith('/') ? '$targetDir$fileName' : '$targetDir/$fileName';
      final targetFile = File(targetPath);
      await targetFile.writeAsBytes(bytes);
      return (targetFile.path, null);
    } catch (e) {
      return (null, '写入失败: $e');
    }
  }

  /// 导出可分享的日志文件（复制到临时目录，返回文件路径）
  ///
  /// 不写进 cache/share_plus：share_plus 会把待分享文件再复制一份到那里，
  /// 源文件若已在其中会直接抛 IOException。
  Future<(String?, String?)> exportForShare() async {
    try {
      await flush();
      final file = _logFile;
      if (file == null || !await file.exists()) {
        return (null, '日志文件不存在: ${_logPath ?? "未初始化"}');
      }
      final tmp = await getTemporaryDirectory();
      final exportDir = Directory('${tmp.path}/log_export');
      if (!await exportDir.exists()) {
        await exportDir.create(recursive: true);
      }
      final now = DateTime.now();
      final name = '91download_log_${DateFormat('yyyyMMdd_HHmmss').format(now)}.txt';
      final target = File('${exportDir.path}/$name');
      await target.writeAsBytes(await file.readAsBytes(), flush: true);
      return (target.path, null);
    } catch (e) {
      return (null, '导出失败: $e');
    }
  }
}

/// 前后台切换时刷新缓冲
class _LifecycleFlusher extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      Logger().flushSync();
    }
  }
}

// 全局日志实例
final logger = Logger();
