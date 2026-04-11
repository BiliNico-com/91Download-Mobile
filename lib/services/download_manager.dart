import 'dart:async';
import 'package:flutter/material.dart';
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
  
  DownloadTask({
    required this.id,
    required this.video,
    this.status = DownloadStatus.pending,
    this.progress = 0.0,
    this.progressText = '',
    this.error,
    this.filePath,
    DateTime? startTime,
  }) : startTime = startTime ?? DateTime.now();
  
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
    notifyListeners();
    
    await logger.i('DownloadManager', '开始下载: ${task.video.title}');
    
    try {
      // 1. 获取视频详情（m3u8地址）
      await logger.d('DownloadManager', '获取视频详情...');
      final detail = await _crawler!.getVideoDetail(task.video);
      
      if (detail == null || detail.m3u8Url == null) {
        task.status = DownloadStatus.failed;
        task.error = '无法获取视频地址';
        notifyListeners();
        await logger.e('DownloadManager', '获取视频地址失败');
        return;
      }
      
      await logger.i('DownloadManager', '获取到 m3u8 地址');
      
      // 2. 下载视频
      final savePath = '$_downloadDir/${task.video.title}.mp4';
      await logger.i('DownloadManager', '保存路径: $savePath');
      
      // 设置进度回调
      _crawler!.onProgress = (progress, msg) {
        task.progress = progress;
        task.progressText = msg;
        notifyListeners();
      };
      
      final success = await _crawler!.downloadVideo(detail, savePath);
      
      if (success) {
        task.status = DownloadStatus.completed;
        task.filePath = savePath;
        task.progress = 1.0;
        task.progressText = '下载完成';
        await logger.i('DownloadManager', '下载完成: ${task.video.title}');
      } else {
        task.status = DownloadStatus.failed;
        task.error = '下载失败';
        await logger.e('DownloadManager', '下载失败');
      }
      
    } catch (e) {
      task.status = DownloadStatus.failed;
      task.error = e.toString();
      await logger.e('DownloadManager', '下载异常: $e');
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
    notifyListeners();
  }
  
  /// 获取任务
  DownloadTask? getTask(String taskId) => _taskMap[taskId];
}
