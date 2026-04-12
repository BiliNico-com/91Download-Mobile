import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  
  /// 添加下载任务
  DownloadTask addTask(VideoInfo video) {
    final id = video.id;
    if (_taskMap.containsKey(id)) {
      return _taskMap[id]!;
    }
    
    final task = DownloadTask(id: id, video: video);
    _tasks.insert(0, task);
    _taskMap[id] = task;
    _savePendingTasks();  // 保存任务列表
    notifyListeners();
    
    // 自动开始下载
    _startDownload(task);
    
    return task;
  }
  
  /// 执行下载
  Future<void> _startDownload(DownloadTask task) async {
    if (_crawler == null || _downloadDir.isEmpty) {
      task.status = DownloadStatus.failed;
      task.error = '未配置爬虫或下载目录';
      notifyListeners();
      return;
    }
    
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
      final savePath = '$_downloadDir/$safeTitle.mp4';
      
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
        _savePendingTasks();  // 保存更新后的任务列表
      } else {
        await logger.log('Download', '下载失败: ${task.video.title}');
        task.status = DownloadStatus.failed;
        task.error = '下载失败';
        task.downloadSpeed = 0.0;
      }
      
    } catch (e) {
      await logger.log('Download', '下载异常: $e');
      task.status = DownloadStatus.failed;
      task.error = e.toString();
      task.downloadSpeed = 0.0;
    }
    
    notifyListeners();
  }
  
  /// 批量添加任务
  void addTasks(List<VideoInfo> videos) {
    for (final video in videos) {
      addTask(video);
    }
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
      _startDownload(task);
    }
  }
  
  /// 暂停任务
  void pauseTask(String taskId) {
    final task = _taskMap[taskId];
    if (task != null && task.status == DownloadStatus.downloading) {
      task.status = DownloadStatus.paused;
      task.downloadSpeed = 0.0;
      notifyListeners();
    }
  }
  
  /// 继续任务
  void resumeTask(String taskId) {
    final task = _taskMap[taskId];
    if (task != null && task.status == DownloadStatus.paused) {
      task.lastUpdateTime = DateTime.now();
      task.lastDownloadedBytes = task.downloadedBytes;
      _startDownload(task);
    }
  }
  
  /// 重试任务
  void retryTask(String taskId) {
    final task = _taskMap[taskId];
    if (task != null && task.status == DownloadStatus.failed) {
      task.status = DownloadStatus.pending;
      task.error = null;
      task.progress = 0;
      task.downloadedBytes = 0;
      task.totalBytes = 0;
      task.downloadSpeed = 0.0;
      _startDownload(task);
    }
  }
  
  /// 取消下载
  void cancelTask(String taskId) {
    final task = _taskMap[taskId];
    if (task != null) {
      _tasks.remove(task);
      _taskMap.remove(taskId);
      notifyListeners();
    }
  }
  
  /// 清除已完成的任务
  void clearCompleted() {
    _tasks.removeWhere((t) => t.status == DownloadStatus.completed);
    _taskMap.removeWhere((_, t) => t.status == DownloadStatus.completed);
    _savePendingTasks();  // 保存更新后的任务列表
    notifyListeners();
  }
  
  /// 获取任务
  DownloadTask? getTask(String taskId) => _taskMap[taskId];
  
  /// 保存未完成的任务到本地
  Future<void> _savePendingTasks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pendingTasks = _tasks.where((t) => 
        t.status == DownloadStatus.pending || 
        t.status == DownloadStatus.paused ||
        t.status == DownloadStatus.downloading
      ).toList();
      
      final taskList = pendingTasks.map((t) => {
        return {
          'id': t.video.id,
          'url': t.video.url,
          'title': t.video.title,
          'cover': t.video.cover,
          'author': t.video.author,
          'duration': t.video.duration,
          'status': t.status.index,
        };
      }).toList();
      
      await prefs.setString('pending_download_tasks', jsonEncode(taskList));
    } catch (e) {
      print('保存下载任务失败: $e');
    }
  }
  
  /// 从本地恢复未完成的任务
  Future<void> restorePendingTasks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final tasksJson = prefs.getString('pending_download_tasks');
      if (tasksJson == null || tasksJson.isEmpty) return;
      
      final taskList = jsonDecode(tasksJson) as List;
      for (final item in taskList) {
        final video = VideoInfo(
          id: item['id'],
          url: item['url'],
          title: item['title'],
          cover: item['cover'],
          author: item['author'],
          duration: item['duration'],
        );
        
        // 检查是否已存在
        if (!_taskMap.containsKey(video.id)) {
          final task = DownloadTask(id: video.id, video: video);
          // 恢复为等待状态（需要重新下载）
          task.status = DownloadStatus.pending;
          _tasks.add(task);
          _taskMap[video.id] = task;
        }
      }
      
      // 清除已恢复的任务
      await prefs.remove('pending_download_tasks');
      
      if (_tasks.isNotEmpty) {
        notifyListeners();
        await logger.log('Download', '恢复了 ${_tasks.length} 个下载任务');
      }
    } catch (e) {
      print('恢复下载任务失败: $e');
    }
  }
}
