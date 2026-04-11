import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';

class Logger {
  static final Logger _instance = Logger._internal();
  factory Logger() => _instance;
  Logger._internal();
  
  bool _enabled = false;
  File? _logFile;
  String? _logPath;
  
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
      final fileName = 'network_${DateFormat('yyyyMMdd_HHmmss').format(now)}.log';
      _logFile = File('${logDir.path}/$fileName');
      _logPath = _logFile!.path;
      
      await _logFile!.writeAsString('=== 91Download Network Log ===\n');
      await _logFile!.writeAsString('启动时间: ${now.toString()}\n\n', mode: FileMode.append);
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
  
  // 写入网络日志
  Future<void> log(String tag, String message) async {
    if (!_enabled) return;
    
    final timestamp = DateFormat('HH:mm:ss.SSS').format(DateTime.now());
    final line = '[$timestamp][$tag] $message\n';
    
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
  
  // 获取日志内容
  Future<String> getLogContent() async {
    if (_logFile == null || !await _logFile!.exists()) {
      return '暂无日志';
    }
    return await _logFile!.readAsString();
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
  
  // 获取日志目录下的所有日志文件
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
      
      // 按修改时间排序（最新的在前）
      files.sort((a, b) {
        final aTime = a.lastModifiedSync();
        final bTime = b.lastModifiedSync();
        return bTime.compareTo(aTime);
      });
      
      return files;
    } catch (e) {
      print('Get log files failed: $e');
      return [];
    }
  }
  
  // 删除指定的日志文件
  Future<bool> deleteLogFile(String filePath) async {
    try {
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
  
  // 删除所有保存的日志文件
  Future<int> deleteAllSavedLogs() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/logs');
      if (!await logDir.exists()) {
        return 0;
      }
      
      int count = 0;
      await for (final entity in logDir.list()) {
        if (entity is File && entity.path.endsWith('.log')) {
          await entity.delete();
          count++;
        }
      }
      
      // 如果当前日志文件还在，重建它
      if (_logFile != null && !await _logFile!.exists()) {
        final now = DateTime.now();
        final fileName = 'network_${DateFormat('yyyyMMdd_HHmmss').format(now)}.log';
        _logFile = File('${logDir.path}/$fileName');
        _logPath = _logFile!.path;
        await _logFile!.writeAsString('=== 91Download Network Log ===\n');
        await _logFile!.writeAsString('启动时间: ${now.toString()}\n\n', mode: FileMode.append);
      }
      
      return count;
    } catch (e) {
      print('Delete all saved logs failed: $e');
      return 0;
    }
  }
  
  // 保存日志到指定目录
  Future<String?> saveToDirectory(String targetDir) async {
    if (_logFile == null || !await _logFile!.exists()) {
      print('Save log failed: log file not found');
      return null;
    }
    
    try {
      final content = await _logFile!.readAsString();
      final now = DateTime.now();
      final fileName = 'network_log_${DateFormat('yyyyMMdd_HHmmss').format(now)}.txt';
      
      // 确保目录存在
      final dir = Directory(targetDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      
      // 使用 path.join 风格拼接路径
      final targetPath = targetDir.endsWith('/') 
          ? '$targetDir$fileName' 
          : '$targetDir/$fileName';
      final targetFile = File(targetPath);
      await targetFile.writeAsString(content);
      print('Log saved to: $targetPath');
      return targetFile.path;
    } catch (e) {
      print('Save log failed: $e');
      return null;
    }
  }
}

// 全局日志实例
final logger = Logger();
