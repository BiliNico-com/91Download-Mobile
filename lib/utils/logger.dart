import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../services/network_info_service.dart';

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
/// 网络日志去重的一格：同一个签名在 window 内只放行第一条，
/// 其余累计到 suppressed，窗口结束时补一条「同类已忽略 N 条」。
///
/// 关掉代理时 91porn 会被 DNS 污染成 127.0.0.1，一次解析就会打出成百上千条
/// Connection refused，把 3MB 的日志文件瞬间刷满、把真正的线索挤掉。
class _NetDedupe {
  _NetDedupe(this.start, this.window, this.tag);

  final DateTime start;
  final Duration window;

  /// 首次出现时用的 tag，汇总行沿用它（Net / Download 等）
  final String tag;
  int suppressed = 0;

  bool expiredAt(DateTime now) => now.difference(start) >= window;
}

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

  /// 网络日志去重：签名 → 当前窗口状态
  ///
  /// 关掉代理时站点域名会被 DNS 污染成 127.0.0.1，一次解析就能产生成百上千条
  /// 完全相同的 "-> 失败(connectionError, ...) Connection refused"，
  /// 3 MB 的日志文件几秒就被刷满，真正做到排查用的那几条反而看不到。
  final Map<String, _NetDedupe> _netDedupe = {};

  /// 普通失败（4xx/5xx）的去重窗口
  static const Duration _netFailureWindow = Duration(seconds: 20);

  /// 连接级失败（代理没开、DNS 污染、拒绝连接）的去重窗口更长：
  /// 这类失败在一轮解析里会连打几十条，且内容完全一样，
  /// 保留第一条 + 末尾一条汇总足够定位问题。
  static const Duration _netOfflineWindow = Duration(minutes: 2);

  /// 去重表的条目上限，防止签名爆炸把内存吃掉
  static const int _netDedupeMaxKeys = 128;

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
  ///
  /// [dedupeKey] 非空时启用去重聚合：同一个 key 在窗口内只记第一条，
  /// 窗口结束（下一条同 key 到达时判定）补一行「同类已忽略 N 条」。
  /// 失败行的 key 由拦截器按「失败类型 + 主机 + 路径」生成，
  /// 成功行不传 key，历史行为完全不变。
  void network(
    String message, {
    String level = LogLevel.info,
    String? dedupeKey,
    bool offline = false,
  }) {
    if (!_enabled) return;
    if (dedupeKey == null || dedupeKey.isEmpty) {
      _appendLine(_formatLine('Net', level, message));
      return;
    }
    _appendDeduped('Net', level, message, dedupeKey, offline);
  }

  /// 通用去重写入（网络请求之外的高频失败也走这里）
  ///
  /// 典型场景：没连代理时整片视频的切片会齐齐失败，几百个切片 × 3 次重试
  /// 就是上千行 "下载切片失败"，把真正有用的那几行彻底淹没。
  /// [offline] 为 true 时用更长的窗口，因为这类失败通常整轮都一样。
  void logDeduped(
    String tag,
    String message, {
    String level = LogLevel.info,
    required String dedupeKey,
    bool offline = false,
  }) {
    if (!_enabled) return;
    _appendDeduped(tag, level, message, dedupeKey, offline);
  }

  /// 去重的实际实现：窗口内同 key 只放行第一条，窗口结束时补一行汇总
  void _appendDeduped(
    String tag,
    String level,
    String message,
    String dedupeKey,
    bool offline,
  ) {
    final now = DateTime.now();
    final window = offline ? _netOfflineWindow : _netFailureWindow;
    final existing = _netDedupe[dedupeKey];
    if (existing != null && !existing.expiredAt(now)) {
      // 同一签名还在窗口内：只计数，不落盘
      existing.suppressed++;
      return;
    }
    if (existing != null) {
      // 窗口结束，先把上一段被吞掉的数量交代清楚
      final n = existing.suppressed;
      _netDedupe.remove(dedupeKey);
      if (n > 0) {
        _appendLine(_formatLine(
          tag,
          LogLevel.warn,
          '同类已静默 $n 条（' + dedupeKey + '）',
        ));
      }
    }
    if (_netDedupe.length >= _netDedupeMaxKeys) {
      // 签名太多说明不是同一种失败在刷屏，老老实实记，别把内存拖垮
      _appendLine(_formatLine(tag, level, message));
      return;
    }
    _netDedupe[dedupeKey] = _NetDedupe(now, window, tag);
    _appendLine(_formatLine(tag, level, message));
  }

  /// 把还在窗口内的聚合计数冲刷掉（停止下载、导出日志前调用），
  /// 否则被静默的条数会一直不落盘。
  void flushNetworkDedupe() {
    if (_netDedupe.isEmpty) return;
    for (final entry in _netDedupe.entries) {
      final n = entry.value.suppressed;
      if (n > 0) {
        _appendLine(_formatLine(
          entry.value.tag,
          LogLevel.warn,
          '同类已静默 $n 条（' + entry.key + '）',
        ));
      }
    }
    _netDedupe.clear();
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

  /// 记录网络环境（接入方式 / 内网 IP / 系统代理 / 出口公网 IP），
  /// 用于判断当前是直连还是走了代理。
  ///
  /// 探测本身要发几次 HTTP（最长十几秒），调用方不要把它放在会阻塞
  /// 首帧的路径上；日志只是排查辅助，晚一点写并无影响。
  Future<NetworkSnapshot?> logNetworkEnvironment({
    bool force = true,
    String reason = '启动',
  }) async {
    if (!_enabled) return null;
    NetworkSnapshot? snap;
    try {
      snap = await NetworkInfoService.collect(force: force);
    } catch (e) {
      logSync('Env', '网络环境采集失败: $e', level: LogLevel.warn);
      return null;
    }
    final ts = _fmtFull(DateTime.now());
    writeRaw('[$ts][Env][info] 网络环境（$reason）\n');
    for (final line in snap.describeLines()) {
      writeRaw('[$ts][Env][info]   $line\n');
    }
    await flush();
    return snap;
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
    flushNetworkDedupe();
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
      _netDedupe.clear();
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
      flushNetworkDedupe();
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
      flushNetworkDedupe();
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
