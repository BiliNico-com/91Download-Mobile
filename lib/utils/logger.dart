import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';

/// 日志类型
enum LogType {
  normal,   // 普通日志，不受开关影响
  network,  // 网络日志
  ui,       // UI操作日志
}

class Logger {
  static final Logger _instance = Logger._internal();
  factory Logger() => _instance;
  Logger._internal();
  
  bool _enabled = false;
  File? _logFile;
  String? _logPath;
  
  // 日志类型开关
  bool enableNetworkLog = true;
  bool enableUILog = true;
  
  bool get enabled => _enabled;
  String? get logPath => _logPath;
  
  // 初始化日志
  Future<void> init(bool enable) async {
    _enabled = enable;
    if (!_enabled) return;
    
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/logs');
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }
      
      final now = DateTime.now();
      final fileName = 'debug_${DateFormat('yyyyMMdd_HHmmss').format(now)}.log';
      _logFile = File('${logDir.path}/$fileName');
      _logPath = _logFile!.path;
      
      await _logFile!.writeAsString('=== 91Download Debug Log ===\n');
      await _logFile!.writeAsString('启动时间: ${now.toString()}\n', mode: FileMode.append);
      await _logFile!.writeAsString('设备: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}\n\n', mode: FileMode.append);
    } catch (e) {
      print('Logger init failed: $e');
    }
  }
  
  // 切换开关
  Future<void> toggle(bool enable) async {
    if (enable && !_enabled) {
      await init(true);
    }
    _enabled = enable;
  }
  
  // 写入日志（带类型过滤）
  Future<void> log(String tag, String message, {String level = 'INFO', LogType type = LogType.normal}) async {
    // 检查日志类型开关
    if (type == LogType.network && !enableNetworkLog) return;
    if (type == LogType.ui && !enableUILog) return;
    
    final timestamp = DateFormat('HH:mm:ss.SSS').format(DateTime.now());
    final line = '[$timestamp][$level][$tag] $message\n';
    
    // 控制台输出
    print(line.trim());
    
    // 文件写入
    if (_logFile != null) {
      try {
        await _logFile!.writeAsString(line, mode: FileMode.append);
      } catch (e) {
        print('Logger write failed: $e');
      }
    }
  }
  
  // 便捷方法 - 普通日志
  Future<void> d(String tag, String message) => log(tag, message, level: 'DEBUG');
  Future<void> i(String tag, String message) => log(tag, message, level: 'INFO');
  Future<void> w(String tag, String message) => log(tag, message, level: 'WARN');
  Future<void> e(String tag, String message) => log(tag, message, level: 'ERROR');
  
  // 便捷方法 - 网络日志
  Future<void> network(String tag, String message, {String level = 'INFO'}) => 
      log(tag, message, level: level, type: LogType.network);
  
  // 便捷方法 - UI操作日志
  Future<void> ui(String tag, String message, {String level = 'INFO'}) => 
      log(tag, message, level: level, type: LogType.ui);
  
  // 获取日志内容
  Future<String> getLogContent() async {
    if (_logFile == null || !await _logFile!.exists()) {
      return '暂无日志';
    }
    return await _logFile!.readAsString();
  }
  
  // 获取所有日志文件
  Future<List<File>> getAllLogFiles() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/logs');
      if (!await logDir.exists()) return [];
      
      final files = await logDir.list().where((f) => f.path.endsWith('.log')).cast<File>().toList();
      files.sort((a, b) => b.path.compareTo(a.path)); // 最新的在前
      return files;
    } catch (e) {
      return [];
    }
  }
  
  // 清空日志
  Future<void> clearLogs() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/logs');
      if (await logDir.exists()) {
        await logDir.delete(recursive: true);
      }
      _logFile = null;
      _logPath = null;
    } catch (e) {
      print('Clear logs failed: $e');
    }
  }
  
  // 保存日志到指定目录
  Future<String?> saveToDirectory(String targetDir) async {
    if (_logFile == null || !await _logFile!.exists()) {
      print('Logger: 日志文件不存在');
      return null;
    }
    
    try {
      final content = await _logFile!.readAsString();
      final now = DateTime.now();
      final fileName = '91Download_log_${DateFormat('yyyyMMdd_HHmmss').format(now)}.txt';
      
      // 确保目标目录存在
      final dir = Directory(targetDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      
      final targetFile = File('$targetDir/$fileName');
      await targetFile.writeAsString(content);
      print('Logger: 日志已保存到 ${targetFile.path}');
      return targetFile.path;
    } catch (e) {
      print('Save log to directory failed: $e');
      return null;
    }
  }
}

// 全局日志实例
final logger = Logger();
