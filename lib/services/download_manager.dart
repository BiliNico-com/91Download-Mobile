import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import '../models/video_info.dart';
import '../crawler/crawler_core.dart';
import '../utils/logger.dart';

/// 下载任务状态
enum DownloadStatus {
  pending,    // 等待中
  downloading, // 下载中
  paused,     // 已暂停
  completed,  // 已完成
  failed,     // 失败
}

/// 下载任务
class DownloadTask {
  final String id;
  final VideoInfo video;
  DownloadStatus status;
  double progress;      // 0.0 - 1.0
  String progressText;  // "5/100"
  String? error;
  String? filePath;
  DateTime startTime;
  DateTime? endTime;
  
  // 下载速度相关
  int downloadedBytes = 0;      // 已下载字节数
  int totalBytes = 0;           // 总字节数
  double downloadSpeed = 0.0;   // 下载速度 (bytes/s)
  DateTime? lastUpdateTime;    // 上次更新时间
  int lastDownloadedBytes = 0; // 上次已下载字节数
  
  DownloadTask({
    required this.id,
    required this.video,
    this.status = DownloadStatus.pending,
    this.progress = 0.0,
    this.progressText = '',
    this.error,
    this.filePath,
    DateTime? startTime,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.downloadSpeed = 0.0,
  }) : startTime = startTime ?? DateTime.now();
  
  /// 更新下载速度和进度
  void updateProgressWithSpeed(int downloaded, int total) {
    final now = DateTime.now();
    downloadedBytes = downloaded;
    totalBytes = total;
    
    if (lastUpdateTime != null) {
      final timeDiff = now.difference(lastUpdateTime!).inMilliseconds;
      if (timeDiff > 0) {
        final bytesDiff = downloaded - lastDownloadedBytes;
        // 计算速度 (bytes/s)，避免负数
        downloadSpeed = bytesDiff > 0 ? (bytesDiff / timeDiff * 1000) : downloadSpeed;
      }
    }
    
    lastUpdateTime = now;
    lastDownloadedBytes = downloaded;
    
    // 更新进度
    if (total > 0) {
      progress = downloaded / total;
    }
    
    // 更新进度文本
    progressText = '${_formatBytes(downloaded)}/${_formatBytes(total)}';
    if (downloadSpeed > 0) {
      progressText += ' (${_formatSpeed(downloadSpeed)})';
    }
  }
  
  /// 格式化字节数
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
  
  /// 格式化速度
  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) return '${bytesPerSecond.toStringAsFixed(0)} B/s';
    if (bytesPerSecond < 1024 * 1024) return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    return '${(bytesPerSecond / 1024 / 1024).toStringAsFixed(2)} MB/s';
  }
  
  /// 获取格式化后的速度文本
  String get speedText {
    if (downloadSpeed <= 0) return '';
    return _formatSpeed(downloadSpeed);
  }
  
  String get statusText {
    switch (status) {
      case DownloadStatus.pending: return '等待中';
      case DownloadStatus.downloading: return '下载中';
      case DownloadStatus.paused: return '已暂停';
      case DownloadStatus.completed: return '已完成';
      case DownloadStatus.failed: return '失败';
    }
  }
}

/// 下载管理器
class DownloadManager extends ChangeNotifier {
  final List<DownloadTask> _tasks = [];
  final Map<String, DownloadTask> _taskMap = {};
  CrawlerCore? _crawler;
  String _downloadDir = '';
  Database? _db;
  bool _dbInitialized = false;
  
  /// 外部数据库路径（用于持久化保存，卸载后不丢失）
  String? externalDbPath;
  
  /// 同时下载任务数上限（由设置页面控制）
  int maxConcurrentTasks = 2;
  
  /// TS切片并发下载数（由设置页面控制）
  int maxConcurrentSegments = 32;
  
  /// 当前正在下载的任务数量
  int _activeDownloads = 0;
  
  /// 等待队列（pending状态的任务）
  final List<DownloadTask> _waitingQueue = [];
  
  /// 初始化数据库
  Future<void> _initDb() async {
    if (_dbInitialized) return;
    try {
      String dbPath;
      if (externalDbPath != null && externalDbPath!.isNotEmpty) {
        // 使用外部存储路径（卸载后保留）
        final dbDir = Directory('$externalDbPath/.db');
        if (!await dbDir.exists()) {
          await dbDir.create(recursive: true);
        }
        dbPath = '${dbDir.path}/download_tasks.db';
      } else {
        // 使用应用私有路径（默认行为）
        dbPath = '${await getDatabasesPath()}/download_tasks.db';
      }
      _db = await openDatabase(
        dbPath,
        onCreate: (db, version) {
          return db.execute('''
            CREATE TABLE IF NOT EXISTS download_tasks (
              id TEXT PRIMARY KEY,
              url TEXT,
              title TEXT,
              cover TEXT,
              author TEXT,
              duration TEXT,
              status INTEGER,
              file_path TEXT,
              error TEXT,
              download_time TEXT
            )
          ''');
        },
        version: 1,
      );
      _dbInitialized = true;
    } catch (e) {
      Logger().log('Download', '数据库初始化失败: $e');
    }
  }
  
  /// 设置爬虫和下载目录
  void setup(CrawlerCore crawler, String downloadDir) {
    _crawler = crawler;
    _downloadDir = downloadDir;
  }
  
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  List<DownloadTask> get downloadingTasks => 
    _tasks.where((t) => t.status == DownloadStatus.downloading || t.status == DownloadStatus.pending || t.status == DownloadStatus.paused).toList();
  List<DownloadTask> get completedTasks => 
    _tasks.where((t) => t.status == DownloadStatus.completed).toList();
  List<DownloadTask> get failedTasks => 
    _tasks.where((t) => t.status == DownloadStatus.failed).toList();
  
  int get downloadingCount => downloadingTasks.length;
  int get completedCount => completedTasks.length;
  
  /// 获取当前正在下载的任务数量
  int get activeDownloads => _activeDownloads;
  
  /// 获取等待中的任务数量
  int get waitingCount => _waitingQueue.length;
  
  /// 检查视频是否已下载（检查内存任务 + 历史数据库）
  /// 返回 true 表示视频已经下载完成过（包含已完成任务和历史记录）
  Future<bool> isVideoDownloaded(String videoId) async {
    // 1. 检查内存中是否有已完成的任务
    final task = _taskMap[videoId];
    if (task != null && task.status == DownloadStatus.completed) {
      return true;
    }
    // 2. 检查历史数据库（持久化记录，跨会话有效）
    if (_crawler != null) {
      try {
        return await _crawler!.isDownloaded(videoId);
      } catch (e) {
        Logger().log('Download', '检查下载历史失败: $e');
      }
    }
    return false;
  }
  
  /// 检查视频是否正在下载队列中（等待中/下载中/暂停）
  bool isVideoInQueue(String videoId) {
    final task = _taskMap[videoId];
    if (task == null) return false;
    return task.status == DownloadStatus.pending ||
           task.status == DownloadStatus.downloading ||
           task.status == DownloadStatus.paused;
  }
  
  /// 添加下载任务
  /// [forceRestart] 为 true 时，如果任务已完成会先删除旧文件再重新下载
  /// 返回值：'new' 新任务, 'duplicate' 队列中已存在, 'replaced' 覆盖了已完成的任务
  Future<String> addTask(VideoInfo video, {bool forceRestart = false}) async {
    final id = video.id;
    
    // 检查是否在队列中（等待/下载/暂停）
    if (_taskMap.containsKey(id)) {
      final existing = _taskMap[id]!;
      if (existing.status == DownloadStatus.pending ||
          existing.status == DownloadStatus.downloading ||
          existing.status == DownloadStatus.paused) {
        return 'duplicate';
      }
      // 如果是已完成的任务且用户确认覆盖
      if (existing.status == DownloadStatus.completed && forceRestart) {
        // 删除旧的下载文件
        if (existing.filePath != null && existing.filePath!.isNotEmpty) {
          try {
            final oldFile = File(existing.filePath!);
            if (await oldFile.exists()) {
              await oldFile.delete();
              await logger.log('Download', '已删除旧文件: ${existing.filePath}');
            }
          } catch (e) {
            await logger.log('Download', '删除旧文件失败: $e');
          }
        }
        // 从列表和映射中移除旧任务
        _waitingQueue.remove(existing);
        _tasks.remove(existing);
        _taskMap.remove(id);
        _deleteTaskFromDb(id);
      } else if (existing.status == DownloadStatus.completed) {
        return 'duplicate';
      }
      // 失败的任务，允许重新下载
      if (existing.status == DownloadStatus.failed) {
        _waitingQueue.remove(existing);
        _tasks.remove(existing);
        _taskMap.remove(id);
        _deleteTaskFromDb(id);
      }
    }
    
    final task = DownloadTask(id: id, video: video);
    _tasks.insert(0, task);
    _taskMap[id] = task;
    _saveTaskToDb(task);  // 保存到数据库
    notifyListeners();
    
    // 按并发限制决定立即下载还是加入队列
    _tryStartNext(task);
    
    return 'new';
  }
  
  /// 尝试启动下载（受并发限制控制）
  void _tryStartNext([DownloadTask? newTask]) {
    if (_crawler == null || _downloadDir.isEmpty) {
      if (newTask != null) {
        newTask.status = DownloadStatus.failed;
        newTask.error = '未配置爬虫或下载目录';
        notifyListeners();
      }
      return;
    }
    
    // 如果有新任务且当前有空位，立即下载
    if (newTask != null) {
      if (_activeDownloads < maxConcurrentTasks) {
        _startDownload(newTask);
      } else {
        // 加入等待队列
        newTask.status = DownloadStatus.pending;
        if (!_waitingQueue.contains(newTask)) {
          _waitingQueue.add(newTask);
        }
        notifyListeners();
      }
      return;
    }
    
    // 否则从队列中取下一个任务
    while (_waitingQueue.isNotEmpty && _activeDownloads < maxConcurrentTasks) {
      final nextTask = _waitingQueue.removeAt(0);
      if (nextTask.status == DownloadStatus.pending) {
        _startDownload(nextTask);
        break;  // 一次只启动一个，避免超过限制
      }
    }
  }
  
  /// 跟踪正在下载的任务ID，用于取消时判断
  String? _activeTaskId;
  
  /// 执行下载
  Future<void> _startDownload(DownloadTask task) async {
    _activeDownloads++;
    _activeTaskId = task.id;
    
    task.status = DownloadStatus.downloading;
    // 重置下载速度相关数据
    task.lastUpdateTime = DateTime.now();
    task.lastDownloadedBytes = 0;
    task.downloadSpeed = 0.0;
    notifyListeners();
    
    await logger.log('Download', '开始下载: ${task.video.title}');
    await logger.log('Download', '视频ID: ${task.video.id}, 封面: ${task.video.cover}');
    
    try {
      // 1. 获取视频详情（m3u8地址）
      await logger.log('Download', '获取视频详情...');
      final detail = await _crawler!.getVideoDetail(task.video);
      
      if (detail == null || detail.m3u8Url == null) {
        await logger.log('Download', '获取视频地址失败: detail=$detail');
        task.status = DownloadStatus.failed;
        task.error = '无法获取视频地址';
        notifyListeners();
        return;
      }
      
      await logger.log('Download', '获取到视频地址: ${detail.m3u8Url}');
      
      // 2. 下载视频
      // 清理文件名中的非法字符
      final safeTitle = task.video.title.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
      // 构建文件名：视频名称 + 作者信息（避免同名覆盖）
      String fileName;
      final author = task.video.author ?? task.video.authorId;
      if (author != null && author.isNotEmpty) {
        final safeAuthor = author.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
        fileName = '${safeTitle}_$safeAuthor.mp4';
      } else {
        fileName = '${safeTitle}_${task.video.id}.mp4';
      }
      final savePath = '$_downloadDir/$fileName';
      
      await logger.log('Download', '保存路径: $savePath');
      
      // 设置进度回调
      _crawler!.onProgress = (progress, msg) {
        task.progress = progress;
        // 如果是简单的百分比消息，转换为带速度的格式
        if (msg.isNotEmpty && !msg.contains('/')) {
          task.progressText = '$msg - ${task.speedText}';
        } else {
          task.progressText = msg;
        }
        notifyListeners();
      };
      
      // 设置总体进度回调（字节数和速度）
      _crawler!.onOverallProgress = (downloaded, total) {
        task.updateProgressWithSpeed(downloaded, total);
        notifyListeners();
      };
      
      final success = await _crawler!.downloadVideo(detail, savePath);
      
      if (success) {
        await logger.log('Download', '下载完成: ${task.video.title}');
        task.status = DownloadStatus.completed;
        task.filePath = savePath;
        task.progress = 1.0;
        task.progressText = '下载完成';
        task.downloadSpeed = 0.0;
        task.endTime = DateTime.now();  // ✅ 设置结束时间
        _saveTaskToDb(task);  // 更新数据库
      } else {
        await logger.log('Download', '下载失败: ${task.video.title}');
        task.status = DownloadStatus.failed;
        task.error = '下载失败';
        task.downloadSpeed = 0.0;
        task.endTime = DateTime.now();  // ✅ 设置结束时间
      }
      
    } catch (e) {
      await logger.log('Download', '下载异常: $e');
      task.status = DownloadStatus.failed;
      task.error = e.toString();
      task.downloadSpeed = 0.0;
      task.endTime = DateTime.now();
    } finally {
      // ✅ 清理回调，避免引用泄漏
      _crawler!.onProgress = null;
      _crawler!.onOverallProgress = null;
      // ✅ 下载完成后重置 stopFlag
      _crawler!.reset();
      // 无论成功或失败，释放并发槽位并启动下一个等待任务
      _activeDownloads--;
      _activeTaskId = null;
      notifyListeners();
      _tryStartNext();
    }
  }

  /// 批量添加任务
  /// 返回 (新添加数量, 重复数量, 覆盖数量)
  Future<Map<String, int>> addTasks(List<VideoInfo> videos, {bool forceRestart = false}) async {
    int newCount = 0, dupCount = 0;
    for (final video in videos) {
      final result = await addTask(video, forceRestart: forceRestart);
      if (result == 'new') newCount++;
      else dupCount++;
    }
    return {'new': newCount, 'duplicate': dupCount};
  }
  
  /// 更新任务进度
  void updateProgress(String taskId, double progress, String progressText) {
    final task = _taskMap[taskId];
    if (task != null) {
      task.progress = progress;
      task.progressText = progressText;
      notifyListeners();
    }
  }
  
  /// 更新任务状态
  void updateStatus(String taskId, DownloadStatus status, {String? error, String? filePath}) {
    final task = _taskMap[taskId];
    if (task != null) {
      task.status = status;
      if (error != null) task.error = error;
      if (filePath != null) task.filePath = filePath;
      if (status == DownloadStatus.completed || status == DownloadStatus.failed) {
        task.endTime = DateTime.now();
        task.downloadSpeed = 0.0;
      }
      notifyListeners();
    }
  }
  
  /// 开始下载
  void startDownload(String taskId) {
    final task = _taskMap[taskId];
    if (task != null && task.status == DownloadStatus.pending) {
      task.status = DownloadStatus.downloading;
      notifyListeners();
    }
  }
  
  /// 开始任务
  void startTask(String taskId) {
    final task = _taskMap[taskId];
    if (task != null && task.status == DownloadStatus.pending) {
      _tryStartNext(task);
    }
  }
  
  /// 暂停任务
  void pauseTask(String taskId) {
    final task = _taskMap[taskId];
    if (task != null && task.status == DownloadStatus.downloading) {
      task.status = DownloadStatus.paused;
      task.downloadSpeed = 0.0;
      // ✅ 通知爬虫暂停
      _crawler?.pause();
      notifyListeners();
    }
  }
  
  /// 继续任务
  void resumeTask(String taskId) {
    final task = _taskMap[taskId];
    if (task != null && task.status == DownloadStatus.paused) {
      task.lastUpdateTime = DateTime.now();
      task.lastDownloadedBytes = task.downloadedBytes;
      // ✅ 通知爬虫恢复
      _crawler?.resume();
      _tryStartNext(task);
    }
  }
  
  /// 重试任务
  Future<void> retryTask(String taskId) async {
    final task = _taskMap[taskId];
    if (task != null && task.status == DownloadStatus.failed) {
      // ✅ 重试前清理可能残留的临时文件
      if (task.filePath != null && task.filePath!.isNotEmpty) {
        try {
          final tempDir = Directory('${task.filePath}_temp');
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
            await logger.log('Download', '重试前清理临时目录: ${task.filePath}_temp');
          }
        } catch (e) {
          // 忽略清理错误
        }
      }
      // ✅ 重置爬虫状态
      _crawler?.reset();
      task.status = DownloadStatus.pending;
      task.error = null;
      task.progress = 0;
      task.downloadedBytes = 0;
      task.totalBytes = 0;
      task.downloadSpeed = 0.0;
      _tryStartNext(task);
    }
  }
  
  /// 取消下载（删除任务）
  void cancelTask(String taskId) {
    final task = _taskMap[taskId];
    if (task != null) {
      // 如果任务正在下载中，通知爬虫停止并释放槽位
      if (task.status == DownloadStatus.downloading) {
        _crawler?.stop();
        // finally 块会处理 _activeDownloads-- 和 reset()
      }
      // 从所有列表中移除
      _waitingQueue.remove(task);
      _tasks.remove(task);
      _taskMap.remove(taskId);
      // 异步删除数据库记录
      _deleteTaskFromDb(taskId);
      // 通知 UI 更新
      notifyListeners();
      Logger().logSync('Download', '任务已删除: $taskId, 剩余任务数: ${_tasks.length}');
    }
  }
  
  /// 清除已完成的任务
  void clearCompleted() {
    final completedIds = _tasks.where((t) => t.status == DownloadStatus.completed).map((t) => t.video.id).toList();
    _tasks.removeWhere((t) => t.status == DownloadStatus.completed);
    _taskMap.removeWhere((_, t) => t.status == DownloadStatus.completed);
    // 从数据库删除已完成的任务
    for (final id in completedIds) {
      _deleteTaskFromDb(id);
    }
    notifyListeners();
  }
  
  /// 获取任务
  DownloadTask? getTask(String taskId) => _taskMap[taskId];
  
  /// 保存任务到数据库
  Future<void> _saveTaskToDb(DownloadTask task) async {
    await _initDb();
    if (_db == null) return;
    
    try {
      await _db!.insert(
        'download_tasks',
        {
          'id': task.video.id,
          'url': task.video.url,
          'title': task.video.title,
          'cover': task.video.cover,
          'author': task.video.author,
          'duration': task.video.duration,
          'status': task.status.index,
          'file_path': task.filePath,
          'error': task.error,
          'download_time': task.startTime.toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      Logger().log('Download', '保存任务失败: $e');
    }
  }
  
  /// 删除任务从数据库
  Future<void> _deleteTaskFromDb(String taskId) async {
    await _initDb();
    if (_db == null) return;
    
    try {
      await _db!.delete('download_tasks', where: 'id = ?', whereArgs: [taskId]);
    } catch (e) {
      Logger().log('Download', '删除任务失败: $e');
    }
  }
  
  /// 清理所有资源
  @override
  void dispose() {
    _crawler?.reset();
    super.dispose();
  }
  
  /// 从数据库恢复任务
  Future<void> restorePendingTasks() async {
    await _initDb();
    if (_db == null) return;
    
    try {
      final List<Map<String, dynamic>> maps = await _db!.query(
        'download_tasks',
        orderBy: 'download_time DESC',
      );
      
      for (final map in maps) {
        final video = VideoInfo(
          id: map['id'],
          url: map['url'],
          title: map['title'],
          cover: map['cover'],
          author: map['author'],
          duration: map['duration'],
        );
        
        if (!_taskMap.containsKey(video.id)) {
          final task = DownloadTask(id: video.id, video: video);
          task.status = DownloadStatus.values[map['status'] as int];
          task.filePath = map['file_path'];
          task.error = map['error'];
          if (map['download_time'] != null) {
            task.startTime = DateTime.parse(map['download_time']);
          }
          _tasks.add(task);
          _taskMap[video.id] = task;
        }
      }
      
      if (_tasks.isNotEmpty) {
        notifyListeners();
        await logger.log('Download', '从数据库恢复了 ${_tasks.length} 个下载任务');
      }
    } catch (e) {
      Logger().log('Download', '恢复任务失败: $e');
    }
  }
}
