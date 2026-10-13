import 'dart:io';
import '../components/cover_image.dart';
import '../crawler/crawler_core.dart';
import '../services/download_manager.dart';
import '../utils/logger.dart';

/// 缓存/残留文件扫描结果
class CacheScanResult {
  /// 残留的临时切片目录（形如 xxx.mp4_temp）
  final List<CacheEntry> tempDirs;

  /// 文件已丢失、但数据库仍有记录的历史条目
  final List<CacheEntry> orphanHistory;

  /// 文件已丢失、但任务表仍有记录的任务条目
  final List<CacheEntry> orphanTasks;

  /// 封面图磁盘缓存占用（由 cached_network_image 管理）
  final int coverCacheBytes;

  const CacheScanResult({
    this.tempDirs = const [],
    this.orphanHistory = const [],
    this.orphanTasks = const [],
    this.coverCacheBytes = 0,
  });

  int get totalCount =>
      tempDirs.length + orphanHistory.length + orphanTasks.length;

  /// 可清理的磁盘占用：临时目录 + 封面缓存
  int get totalBytes =>
      tempDirs.fold<int>(0, (sum, e) => sum + e.sizeBytes) + coverCacheBytes;

  /// 是否没有任何可清理内容
  bool get isEmpty => totalCount == 0 && coverCacheBytes == 0;

  static const empty = CacheScanResult();
}

/// 单个缓存条目
class CacheEntry {
  /// 展示名（标题或目录名）
  final String label;

  /// 磁盘路径或记录 ID
  final String path;

  /// 占用字节数（孤立记录无实体文件则为 0）
  final int sizeBytes;

  /// 该条目对应的视频 ID（清理孤立记录时用于精确删除）
  final String? videoId;

  const CacheEntry({
    required this.label,
    required this.path,
    this.sizeBytes = 0,
    this.videoId,
  });

  String get sizeText => formatBytes(sizeBytes);
}

/// 格式化字节数
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return '${value.toStringAsFixed(value >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
}

/// 缓存管理服务
///
/// 负责扫描与清理下载目录中的残留：
///   1. `*_temp` 目录 —— 下载被强杀/崩溃时未合并的切片残留
///   2. 孤立历史记录 —— download_history.db 有记录但文件已不存在
///   3. 孤立任务记录 —— download_tasks.db 有记录但文件已不存在
///
/// 后两类是「已删除的下载又冒出来」的根源：记录未随文件一同清除，
/// 恢复时又未校验文件，于是被当成已完成重新显示。
class CacheService {
  /// 扫描下载目录与数据库中的残留
  static Future<CacheScanResult> scan({
    required String downloadDir,
    required DownloadManager downloadManager,
    CrawlerCore? crawler,
  }) async {
    if (downloadDir.isEmpty) return CacheScanResult.empty;

    final tempDirs = <CacheEntry>[];

    // ─── 0. 统计封面图磁盘缓存占用 ───
    int coverCacheBytes = 0;
    try {
      coverCacheBytes = await getCoverCacheSize();
    } catch (e) {
      await logger.log('Cache', '统计封面缓存失败: $e');
    }

    // ─── 1. 扫描 *_temp 残留目录 ───
    try {
      final dir = Directory(downloadDir);
      if (await dir.exists()) {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! Directory) continue;
          final name = entity.path.split(Platform.pathSeparator).last;
          if (!name.endsWith('_temp')) continue;

          final size = await _dirSize(entity);
          tempDirs.add(CacheEntry(
            // 去掉 _temp 后缀作为展示名
            label: name.substring(0, name.length - '_temp'.length),
            path: entity.path,
            sizeBytes: size,
          ));
        }
      }
    } catch (e) {
      await logger.log('Cache', '扫描临时目录失败: $e');
    }

    // ─── 2. 扫描孤立历史记录（记录存在但文件不在） ───
    final orphanHistory = <CacheEntry>[];
    if (crawler != null) {
      try {
        final history = await crawler.getDownloadHistory(limit: 5000);
        for (final record in history) {
          final videoId = record['video_id'] as String?;
          if (videoId == null) continue;

          final filePath = record['file_path'] as String?;
          final exists = await _fileExists(filePath);
          if (!exists) {
            orphanHistory.add(CacheEntry(
              label: (record['title'] ?? videoId).toString(),
              path: filePath ?? '',
              videoId: videoId,
            ));
          }
        }
      } catch (e) {
        await logger.log('Cache', '扫描历史记录失败: $e');
      }
    }

    // ─── 3. 扫描孤立任务记录 ───
    final orphanTasks = <CacheEntry>[];
    for (final task in downloadManager.tasks) {
      // 只关心已完成的：未完成的即使没有文件也是正常状态
      if (task.status != DownloadStatus.completed) continue;
      final exists = await _fileExists(task.filePath);
      if (!exists) {
        orphanTasks.add(CacheEntry(
          label: task.video.title,
          path: task.filePath ?? '',
          videoId: task.video.id,
        ));
      }
    }

    return CacheScanResult(
      tempDirs: tempDirs,
      orphanHistory: orphanHistory,
      orphanTasks: orphanTasks,
      coverCacheBytes: coverCacheBytes,
    );
  }

  /// 查询封面图磁盘缓存占用
  static Future<int> getCoverCacheSize() async {
    try {
      return await CoverCache.sizeBytes();
    } catch (e) {
      return 0;
    }
  }

  /// 清空封面图磁盘缓存
  ///
  /// 返回是否执行成功。清理后下次浏览会重新下载，但能立即释放空间。
  static Future<bool> clearCoverCache() async {
    try {
      await CoverCache.clear();
      await logger.log('Cache', '已清空封面图缓存');
      return true;
    } catch (e) {
      await logger.log('Cache', '清空封面图缓存失败: $e');
      return false;
    }
  }

  /// 执行清理
  ///
  /// [deleteTemp] / [deleteOrphanHistory] / [deleteOrphanTasks] 分别控制
  /// 三类残留是否清理，便于 UI 分项勾选。
  /// 返回实际释放的字节数。
  static Future<CacheCleanReport> clean({
    required CacheScanResult scanResult,
    required DownloadManager downloadManager,
    CrawlerCore? crawler,
    bool deleteTemp = true,
    bool deleteOrphanHistory = true,
    bool deleteOrphanTasks = true,
    bool deleteCoverCache = false,
  }) async {
    var freedBytes = 0;
    var tempCount = 0;
    var historyCount = 0;
    var taskCount = 0;

    // ─── 清理封面图缓存 ───
    if (deleteCoverCache) {
      final size = scanResult.coverCacheBytes;
      if (await clearCoverCache()) {
        freedBytes += size;
      }
    }

    // ─── 清理临时目录 ───
    if (deleteTemp) {
      for (final entry in scanResult.tempDirs) {
        try {
          final dir = Directory(entry.path);
          if (await dir.exists()) {
            await dir.delete(recursive: true);
            freedBytes += entry.sizeBytes;
            tempCount++;
          }
        } catch (e) {
          await logger.log('Cache', '删除临时目录失败 (${entry.path}): $e');
        }
      }
    }

    // ─── 清理孤立历史记录 ───
    if (deleteOrphanHistory && crawler != null) {
      for (final entry in scanResult.orphanHistory) {
        final id = entry.videoId;
        if (id == null) continue;
        try {
          await crawler.deleteDownloadHistory(id);
          historyCount++;
        } catch (e) {
          await logger.log('Cache', '删除历史记录失败 ($id): $e');
        }
      }
    }

    // ─── 清理孤立任务记录 ───
    if (deleteOrphanTasks) {
      for (final entry in scanResult.orphanTasks) {
        final id = entry.videoId;
        if (id == null) continue;
        try {
          // 任务记录本身已无对应文件，只删记录，不再尝试删文件
          await downloadManager.removeTaskRecord(id);
          taskCount++;
        } catch (e) {
          await logger.log('Cache', '删除任务记录失败 ($id): $e');
        }
      }
    }

    await logger.log('Cache',
        '清理完成: 临时目录 $tempCount 个, 历史记录 $historyCount 条, 任务记录 $taskCount 条, 释放 ${formatBytes(freedBytes)}');

    return CacheCleanReport(
      tempDirsRemoved: tempCount,
      historyRemoved: historyCount,
      tasksRemoved: taskCount,
      freedBytes: freedBytes,
    );
  }

  static Future<bool> _fileExists(String? path) async {
    if (path == null || path.isEmpty) return false;
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  /// 递归计算目录占用大小
  static Future<int> _dirSize(Directory dir) async {
    var total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }
}

/// 清理结果报告
class CacheCleanReport {
  final int tempDirsRemoved;
  final int historyRemoved;
  final int tasksRemoved;
  final int freedBytes;

  const CacheCleanReport({
    this.tempDirsRemoved = 0,
    this.historyRemoved = 0,
    this.tasksRemoved = 0,
    this.freedBytes = 0,
  });

  int get totalRemoved => tempDirsRemoved + historyRemoved + tasksRemoved;

  String get freedText => formatBytes(freedBytes);
}
