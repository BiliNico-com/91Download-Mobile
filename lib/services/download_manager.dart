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

/// 格式化工具类
class FormatUtils {
  /// 格式化字节数
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
  
  /// 格式化速度
  static String formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) return '${bytesPerSecond.toStringAsFixed(0)} B/s';
    if (bytesPerSecond < 1024 * 1024) return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    return '${(bytesPerSecond / 1024 / 1024).toStringAsFixed(2)} MB/s';
  }
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
  
  /// 更新下载速度与字节数统计
  ///
  /// 注意：**既不修改 [progress]，也不修改 [progressText]**。
  /// - progress 只由「已完成切片数」驱动（两个口径混写会导致进度条抽动）
  /// - progressText 只承载切片进度（如「下载中 13/120」）
  /// - 速度通过 [speedText] 单独提供，UI 只在一处展示
  ///
  /// 这样界面上不会出现「字节数 + 速度」和「切片数 + 速度」两套信息重复。
  void updateProgressWithSpeed(int downloaded, int total) {
    final now = DateTime.now();
    downloadedBytes = downloaded;

    // HLS 流的总字节数通常不可知（需先下完全部切片），
    // 此处仅在已知时更新，避免被 0 覆盖。
    if (total > 0) {
      totalBytes = total;
    }

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
  }
  
  /// 获取格式化后的速度文本
  String get speedText {
    if (downloadSpeed <= 0) return '';
    return FormatUtils.formatSpeed(downloadSpeed);
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
  // 静态常量：文件名非法字符正则（避免每次下载重复编译）
  static final _invalidFileNameChars = RegExp(r'[<>:"/\\|?*]');
  
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
    String? dbPath;
    try {
      if (externalDbPath != null && externalDbPath!.isNotEmpty) {
        // 使用外部存储路径（卸载后保留）
        final dbDir = Directory('$externalDbPath/.db');
        if (!await dbDir.exists()) {
          await dbDir.create(recursive: true);
        }
        dbPath = '${dbDir.path}/download_tasks.db';
      }
    } catch (e) {
      Logger().log('Download', '外部存储数据库路径创建失败，将回退到内部存储: $e');
      dbPath = null;
    }

    try {
      dbPath ??= '${await getDatabasesPath()}/download_tasks.db';
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
              download_time TEXT,
              start_time TEXT,
              end_time TEXT,
              progress REAL,
              progress_text TEXT
            )
          ''');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          // 旧库只有一列 download_time，既当创建时间又当完成时间，
          // 于是「已完成」排序用的是创建时刻，与用户感知的「下载于…」不符。
          // v2 拆成 start_time / end_time：老数据无从区分，统一回填到两列，
          // 至少保证升级后不再丢时间信息。
          if (oldVersion < 2) {
            for (final col in ['start_time', 'end_time']) {
              if (!await _hasColumn(db, 'download_tasks', col)) {
                await db.execute('ALTER TABLE download_tasks ADD COLUMN $col TEXT');
              }
            }
            await db.execute(
                'UPDATE download_tasks SET start_time = download_time WHERE start_time IS NULL');
            await db.execute(
                'UPDATE download_tasks SET end_time = download_time WHERE end_time IS NULL');
          }
          // v3 记录分片进度：此前进度只存在内存里，进程被系统杀掉后
          // 重启只能显示 0%，用户以为要从头下（分片文件其实还在）。
          if (oldVersion < 3) {
            for (final col in ['progress', 'progress_text']) {
              if (!await _hasColumn(db, 'download_tasks', col)) {
                final type = col == 'progress' ? 'REAL' : 'TEXT';
                await db.execute(
                    'ALTER TABLE download_tasks ADD COLUMN $col $type');
              }
            }
          }
        },
        version: 3,
      );
      _dbInitialized = true;
    } catch (e) {
      Logger().log('Download', '数据库初始化失败: $e');
    }
  }
  
  /// 判断表中是否已有某列（SQLite 没有 IF NOT EXISTS 形式的 ADD COLUMN）
  Future<bool> _hasColumn(Database db, String table, String column) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows.any((r) => r['name'] == column);
  }

  /// 把库里存的整数安全地还原成 [DownloadStatus]。
  ///
  /// 原来直接 `DownloadStatus.values[idx]`，而 DB 版本固定 1、没有 onUpgrade，
  /// 一旦枚举增删成员，旧库里的整数就会越界抛 RangeError，
  /// 升级后首次打开下载页直接崩溃，用户只能清数据自救。
  static DownloadStatus _decodeStatus(Object? raw, {String? filePath}) {
    if (raw is int && raw >= 0 && raw < DownloadStatus.values.length) {
      return DownloadStatus.values[raw];
    }
    Logger().log('Download', '未知的任务状态 $raw，按已有文件推断');
    // 有文件路径就当作已完成，否则让用户重新下载，避免误报"已完成"
    return (filePath != null && filePath.isNotEmpty)
        ? DownloadStatus.completed
        : DownloadStatus.failed;
  }

  /// 切换下载目录后重置数据库连接。
  ///
  /// 数据库文件存放在下载目录的 `.db` 下，切换目录后必须重新打开，
  /// 否则新目录的下载记录永远读不到、旧目录的改动还在写。
  void resetForNewDirectory({String? externalDbPath}) {
    try {
      _db?.close();
    } catch (_) {}
    _db = null;
    _dbInitialized = false;
    this.externalDbPath = externalDbPath;
    if (externalDbPath != null && externalDbPath.isNotEmpty) {
      _downloadDir = externalDbPath;
    }
  }

  /// 设置爬虫和下载目录
  void setup(CrawlerCore crawler, String downloadDir) {
    _crawler = crawler;
    _downloadDir = downloadDir;
  }
  
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  /// 未完成的任务：下载中 / 等待 / 暂停 / 失败
  ///
  /// 失败任务归入这里（而不是"已下载"），因为它并未完成，
  /// 且需要就地提供"重试/删除"操作，与其它未完成项一致。
  ///
  /// 排序：进行中的排在前面，失败的整体沉到末尾。
  /// 这样失败项不会插在正在下载的任务之间打断视线，
  /// 界面上再配一个分组标题即可清晰区分。
  List<DownloadTask> get downloadingTasks {
    final active = <DownloadTask>[];
    final failed = <DownloadTask>[];

    for (final t in _tasks) {
      switch (t.status) {
        case DownloadStatus.downloading:
        case DownloadStatus.pending:
        case DownloadStatus.paused:
          active.add(t);
          break;
        case DownloadStatus.failed:
          failed.add(t);
          break;
        case DownloadStatus.completed:
          break;
      }
    }

    // 失败项按失败时间倒序（最近失败的靠前）
    failed.sort((a, b) {
      final ta = a.endTime ?? a.startTime;
      final tb = b.endTime ?? b.startTime;
      return tb.compareTo(ta);
    });

    return [...active, ...failed];
  }

  /// 已完成的任务，按完成时间倒序（最近完成的在最上面）
  ///
  /// 不再包含失败任务：失败项已归入 [downloadingTasks]。
  /// 显式排序是必要的——_tasks 的顺序取决于任务何时被加入列表，
  /// 与"何时下载完成"并不一致（恢复自数据库的任务是追加在后，
  /// 而本次会话新增的任务是插在最前）。
  List<DownloadTask> get completedTasks {
    final list = _tasks
        .where((t) => t.status == DownloadStatus.completed)
        .toList();
    list.sort((a, b) {
      final ta = a.endTime ?? a.startTime;
      final tb = b.endTime ?? b.startTime;
      return tb.compareTo(ta);
    });
    return list;
  }

  List<DownloadTask> get failedTasks =>
      _tasks.where((t) => t.status == DownloadStatus.failed).toList();
  
  int get downloadingCount => downloadingTasks.length;
  int get completedCount => completedTasks.length;
  
  /// 获取当前正在下载的任务数量
  int get activeDownloads => _activeDownloads;
  
  /// 获取等待中的任务数量
  int get waitingCount => _waitingQueue.length;
  
  /// 检查视频是否已下载（检查内存任务 + 历史数据库 + 文件是否存在）
  /// 返回 true 表示视频已经下载完成过且文件存在
  Future<bool> isVideoDownloaded(String videoId) async {
    // 1. 检查内存中是否有已完成的任务
    final task = _taskMap[videoId];
    if (task != null && task.status == DownloadStatus.completed) {
      // 检查文件是否存在
      if (task.filePath != null && task.filePath!.isNotEmpty) {
        final file = File(task.filePath!);
        if (await file.exists()) return true;
      }
    }
    // 2. 检查历史数据库
    if (_crawler != null) {
      try {
        final path = await _crawler!.getDownloadedPath(videoId);
        if (path != null && path.isNotEmpty) {
          final file = File(path);
          if (await file.exists()) return true;
        }
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
      // 如果是已完成的任务
      if (existing.status == DownloadStatus.completed) {
        // 检查文件是否存在
        bool fileExists = false;
        if (existing.filePath != null && existing.filePath!.isNotEmpty) {
          try {
            fileExists = await File(existing.filePath!).exists();
          } catch (_) {}
        }
        
        if (!fileExists) {
          // 文件不存在，允许重新下载，清理旧记录
          _tasks.remove(existing);
          _taskMap.remove(id);
          await _deleteTaskFromDb(id);
        } else if (forceRestart) {
          // 文件存在且用户确认覆盖
          try {
            await File(existing.filePath!).delete();
            await logger.log('Download', '已删除旧文件: ${existing.filePath}');
          } catch (e) {
            await logger.log('Download', '删除旧文件失败: $e');
          }
          _waitingQueue.remove(existing);
          _tasks.remove(existing);
          _taskMap.remove(id);
          await _deleteTaskFromDb(id);
        } else {
          // 文件存在且未确认覆盖
          return 'duplicate';
        }
      }
      // 失败的任务，允许重新下载
      if (existing.status == DownloadStatus.failed) {
        _waitingQueue.remove(existing);
        _tasks.remove(existing);
        _taskMap.remove(id);
        await _deleteTaskFromDb(id);
      }
    }
    
    final task = DownloadTask(id: id, video: video);
    _tasks.insert(0, task);
    _taskMap[id] = task;
    await _saveTaskToDb(task);  // 保存到数据库
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
  
  /// 跟踪正在下载的任务ID集合，支持并发下载时正确跟踪
  final Set<String> _activeTaskIds = {};
  
  /// 执行下载
  Future<void> _startDownload(DownloadTask task) async {
    _activeDownloads++;
    _activeTaskIds.add(task.id);
    
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
      final safeTitle = task.video.title.replaceAll(_invalidFileNameChars, '_');
      // 构建文件名：视频名称 + 作者信息（避免同名覆盖）
      String fileName;
      final author = task.video.author ?? task.video.authorId;
      if (author != null && author.isNotEmpty) {
        final safeAuthor = author.replaceAll(_invalidFileNameChars, '_');
        // 带上唯一 ID：同一作者上传两个同标题的视频时，
        // 仅靠「标题_作者」会得到同一路径，后下的会静默覆盖先下的，
        // 且「已完成」里出现两条记录指向同一文件，删任一条会连带删掉另一条
        fileName = '${safeTitle}_${safeAuthor}_${task.video.id}.mp4';
      } else {
        fileName = '${safeTitle}_${task.video.id}.mp4';
      }
      final savePath = '$_downloadDir/$fileName';
      
      await logger.log('Download', '保存路径: $savePath');
      
      // ── 进度回调挂在本次任务独占的控制句柄上 ──
      // 此前用的是 CrawlerCore 上的全局单槽字段，而并发数默认就是 2，
      // 两个任务会互相覆盖：A 的进度显示成 B 的、任务结束把回调置 null
      // 让仍在跑的任务卡在某个百分比。
      final ctrl = _crawler!.control;
      ctrl.onLog = (msg, level) => logger.log('Download', msg);
      
      // 进度唯一来源是爬虫的「已完成切片数」。
      // progressText 只承载切片进度（如「下载中 13/120」）；
      // 速度由 speedText 单独提供，UI 右侧胶囊展示，避免同一信息重复出现。
      //
      // 节流落盘：每个切片都写库会造成 SQLite 写放大（120 片 = 120 次事务），
      // 因此最多每 5 秒记一次，外加状态切换时（完成/暂停/失败）无条件记一次。
      var lastPersistAt = DateTime.fromMillisecondsSinceEpoch(0);
      ctrl.onProgress = (progress, msg) {
        // 单调递增：任何情况下都不允许进度回退
        if (progress > task.progress) {
          task.progress = progress;
        }
        if (msg.isNotEmpty) {
          task.progressText = msg;
        }
        final now = DateTime.now();
        if (now.difference(lastPersistAt).inSeconds >= 5) {
          lastPersistAt = now;
          _saveTaskToDb(task);
        }
        notifyListeners();
      };
      
      // 总体进度回调：只更新速度与字节数统计，不改 progress 也不改 progressText
      ctrl.onOverallProgress = (downloaded, total) {
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
      } else if (ctrl.isPaused || task.status == DownloadStatus.paused) {
        // 暂停：downloadVideo 会在保留已下载切片后返回 false，
        // 这里不能当成失败，否则用户一暂停任务就变成「失败」
        await logger.log('Download', '已暂停: ${task.video.title}');
        task.status = DownloadStatus.paused;
        task.progressText = '已暂停';
        task.downloadSpeed = 0.0;
        task.lastUpdateTime = DateTime.now();
        _saveTaskToDb(task);
      } else {
        await logger.log('Download', '下载失败: ${task.video.title}');
        task.status = DownloadStatus.failed;
        // 用爬虫给出的具体原因，而不是笼统的「下载失败」：
        // 加密流不支持、站点改版、切片批量失败……这些用户能据此决定是重试还是放弃
        task.error = ctrl.failureReason ?? '下载失败';
        task.downloadSpeed = 0.0;
        task.endTime = DateTime.now();  // ✅ 设置结束时间
        _saveTaskToDb(task);
      }
      
    } catch (e) {
      await logger.log('Download', '下载异常: $e');
      task.status = DownloadStatus.failed;
      task.error = e.toString();
      task.downloadSpeed = 0.0;
      task.endTime = DateTime.now();
    } finally {
      // ✅ 清理回调，避免引用泄漏（只清自己这一份，不影响并发任务）
      final ctrl = _crawler!.control;
      ctrl.onProgress = null;
      ctrl.onOverallProgress = null;
      ctrl.onLog = null;
      // 只重置停止标记；不能 reset 暂停标记，
      // 否则刚被暂停的任务会被立刻「解除暂停」而失去意义
      if (task.status != DownloadStatus.paused) {
        ctrl.reset();
      }
      // 无论成功或失败，释放并发槽位并启动下一个等待任务
      _activeDownloads--;
      _activeTaskIds.remove(task.id);
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
  ///
  /// 通过该任务独占的 DownloadControl 通知爬虫：不再派发新切片，
  /// 等在途切片收尾后挂起，已下载的切片保留在临时目录供续传。
  void pauseTask(String taskId) {
    final task = _taskMap[taskId];
    if (task != null && task.status == DownloadStatus.downloading) {
      task.status = DownloadStatus.paused;
      task.progressText = '已暂停';
      task.downloadSpeed = 0.0;
      _crawler?.control.pause();
      notifyListeners();
    }
  }
  
  /// 继续任务
  void resumeTask(String taskId) {
    final task = _taskMap[taskId];
    if (task != null && task.status == DownloadStatus.paused) {
      task.lastUpdateTime = DateTime.now();
      task.lastDownloadedBytes = task.downloadedBytes;
      task.status = DownloadStatus.pending;
      task.progressText = '等待中';
      notifyListeners();
      _tryStartNext(task);
    }
  }
  
  /// 重试任务
  Future<void> retryTask(String taskId) async {
    final task = _taskMap[taskId];
    if (task != null && task.status == DownloadStatus.failed) {
      // 断点续传：**保留**已下载的切片，重试时 _downloadTs 会跳过它们。
      // （此前这里会删除临时目录，导致每次都从零开始重下，
      //   对长视频尤其浪费流量与时间。）
      // 临时目录只会在这两种情况下清理：
      //   1. 下载成功完成
      //   2. 用户在下载页删除该任务（见 deleteFilesForTask）
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
  ///
  /// [deleteFile] 为 true 时一并删除磁盘文件，避免只删记录导致
  /// 文件残留在下载目录（下次扫描或恢复时又被发现）。
  ///
  /// [isCompleted] 决定是否连带删除 `*_temp` 分片目录：
  /// 已完成任务的 `_temp` 只是合并后的残留，可以清；
  /// 但进行中/已暂停/失败任务的 `_temp` 里是**已下好的分片**，
  /// 清掉就等于把断点续传的成果一起扔掉，用户想重下只能从第 0 片开始。
  /// 因此仅在明确是已完成任务时才清临时目录。
  Future<void> cancelTask(
    String taskId, {
    bool deleteFile = false,
    bool isCompleted = false,
  }) async {
    Logger().logSync('Download', 'cancelTask 被调用, taskId: $taskId');
    Logger().logSync('Download', '_taskMap.keys: ${_taskMap.keys.toList()}');
    Logger().logSync('Download', '_tasks ids: ${_tasks.map((t) => t.id).toList()}');
    
    final task = _taskMap[taskId];
    if (task != null) {
      Logger().logSync('Download', '找到任务, 状态: ${task.status}');
      // 如果任务正在下载中，通知爬虫停止并释放槽位
      if (_activeTaskIds.contains(taskId)) {
        _crawler?.stop();
        _activeTaskIds.remove(taskId);
        _activeDownloads--;
        // finally 块会处理 reset() 和 notifyListeners()
      }
      // 从所有列表中移除
      _waitingQueue.remove(task);
      final removed = _tasks.remove(task);
      _taskMap.remove(taskId);
      Logger().logSync('Download', '从 _tasks 移除: $removed, 剩余任务数: ${_tasks.length}');
      // 删除数据库记录（必须 await，否则可能未完成就退出，记录残留导致"复活"）
      await _deleteTaskFromDb(taskId);
      
      // 删除磁盘文件；临时目录按任务状态决定是否保留
      if (deleteFile) {
        await deleteFilesForTask(task, deleteTempDir: isCompleted);
      } else if (isCompleted) {
        // 不删视频文件，但已完成任务的残留分片目录没有保留价值
        await deleteTempDirFor(task.filePath ?? '');
      }
      
      // 通知 UI 更新
      notifyListeners();
      Logger().logSync('Download', '已调用 notifyListeners()');
    } else {
      Logger().logSync('Download', '任务不存在于 _taskMap 中!');
      // 尝试从 _tasks 中直接查找并删除
      final taskInList = _tasks.where((t) => t.id == taskId).firstOrNull;
      if (taskInList != null) {
        Logger().logSync('Download', '在 _tasks 中找到任务，尝试直接删除');
        _tasks.remove(taskInList);
        _taskMap.remove(taskId);
        await _deleteTaskFromDb(taskId);
        if (deleteFile) {
          await deleteFilesForTask(taskInList, deleteTempDir: isCompleted);
        } else if (isCompleted) {
          await deleteTempDirFor(taskInList.filePath ?? '');
        }
        notifyListeners();
        Logger().logSync('Download', '直接删除成功，剩余任务数: ${_tasks.length}');
      }
    }
  }
  
  /// 只移除任务记录（不触碰磁盘文件）
  ///
  /// 供缓存清理使用：孤立记录对应的文件早已不存在，
  /// 此时只需把残留的数据库记录和内存条目清掉。
  Future<void> removeTaskRecord(String taskId) async {
    final task = _taskMap[taskId];
    if (task != null) {
      _waitingQueue.remove(task);
      _tasks.remove(task);
      _taskMap.remove(taskId);
    } else {
      final taskInList = _tasks.where((t) => t.id == taskId).firstOrNull;
      if (taskInList != null) {
        _tasks.remove(taskInList);
        _taskMap.remove(taskId);
      }
    }
    await _deleteTaskFromDb(taskId);
    notifyListeners();
  }

  /// 删除某个任务对应的视频文件
  ///
  /// [deleteTempDir] 默认 true。对于进行中/失败的取消操作应传 false，
  /// 保留 `*_temp` 里已下好的分片，否则断点续传的成果会被一起删掉。
  Future<void> deleteFilesForTask(
    DownloadTask task, {
    bool deleteTempDir = true,
  }) async {
    final path = task.filePath;
    if (path == null || path.isEmpty) return;
    
    // 删除已合并的视频文件
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
        await logger.log('Download', '已删除文件: $path');
      }
    } catch (e) {
      await logger.log('Download', '删除文件失败 ($path): $e');
    }
    
    // 删除可能残留的临时切片目录
    if (deleteTempDir) {
      await deleteTempDirFor(path);
    }
  }
  
  /// 删除某个视频路径对应的 *_temp 临时目录
  Future<void> deleteTempDirFor(String filePath) async {
    if (filePath.isEmpty) return;
    try {
      final tempDir = Directory('${filePath}_temp');
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
        await logger.log('Download', '已删除临时目录: ${tempDir.path}');
      }
    } catch (e) {
      await logger.log('Download', '删除临时目录失败: $e');
    }
  }
  
  /// 清除已完成的任务
  Future<void> clearCompleted() async {
    final completedIds = _tasks.where((t) => t.status == DownloadStatus.completed).map((t) => t.video.id).toList();
    _tasks.removeWhere((t) => t.status == DownloadStatus.completed);
    _taskMap.removeWhere((_, t) => t.status == DownloadStatus.completed);
    // 从数据库删除已完成的任务（await 确保真正落库）
    for (final id in completedIds) {
      await _deleteTaskFromDb(id);
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
      // 已完成任务优先用 endTime，否则用 startTime。
      // download_time 保留写「排序用的那个时刻」，兼容未升级的旧读取路径。
      final timeToSave = (task.status == DownloadStatus.completed && task.endTime != null)
          ? task.endTime!
          : task.startTime;
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
          'download_time': timeToSave.toIso8601String(),
          // 分别落盘：以前只存一列 download_time，
          // 重启后「下载于…」显示的是创建时间而不是完成时间，倒序也随之错位。
          'start_time': task.startTime.toIso8601String(),
          'end_time': task.endTime?.toIso8601String(),
          // 分片进度落盘：进程被系统杀掉后，重启才能显示真实进度，
          // 而不是看着 0% 以为要从头再下一遍（分片文件其实都还在）。
          'progress': task.progress,
          'progress_text': task.progressText,
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
    // 关闭数据库连接。不关的话每次 dispose 都泄漏一个 SQLite 句柄，
    // 且句柄未落盘的数据可能丢失（SQLite 是延迟写入）。
    try {
      _db?.close();
    } catch (e) {
      Logger().log('Download', '关闭数据库失败: $e');
    }
    _db = null;
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
        // 旧库里可能被清空或为 NULL 的必填字段不能直接透传给 VideoInfo，
        // 否则列表渲染时拿到 null 标题会抛异常，整页下载记录都打不开。
        final id = map['id'] as String?;
        if (id == null || id.isEmpty) {
          Logger().log('Download', '跳过 id 缺失的任务记录');
          continue;
        }
        final video = VideoInfo(
          id: id,
          url: (map['url'] as String?) ?? '',
          title: (map['title'] as String?) ?? '未知视频',
          cover: map['cover'] as String?,
          author: map['author'] as String?,
          duration: map['duration'] as String?,
        );
        
        if (!_taskMap.containsKey(video.id)) {
          final task = DownloadTask(id: video.id, video: video);
          task.status = _decodeStatus(map['status'], filePath: map['file_path'] as String?);
          task.filePath = map['file_path'] as String?;
          task.error = map['error'] as String?;
          // 恢复上一次落盘的分片进度，让用户看到「接着下」而不是 0%
          final savedProgress = map['progress'];
          if (savedProgress is num && savedProgress > 0 && savedProgress <= 1) {
            task.progress = savedProgress.toDouble();
          }
          final savedText = map['progress_text'];
          if (savedText is String && savedText.isNotEmpty) {
            task.progressText = savedText;
          }
          // 优先用拆分后的 start_time / end_time；老库只有 download_time，
          // 此时退化为「两者相同」，与原行为一致但不丢时间。
          final startRaw = map['start_time'] ?? map['download_time'];
          final endRaw = map['end_time'];
          if (startRaw is String && startRaw.isNotEmpty) {
            task.startTime = DateTime.tryParse(startRaw) ?? DateTime.now();
          }
          if (endRaw is String && endRaw.isNotEmpty) {
            task.endTime = DateTime.tryParse(endRaw);
          } else if (task.status == DownloadStatus.completed) {
            // 已完成却没有结束时间（老数据）：用开始时间兜底，
            // 让「下载于…」至少有值，而不是显示成当前时间。
            task.endTime = task.startTime;
          }
          _tasks.add(task);
          _taskMap[video.id] = task;
        }
      }
      
      // 同时从 download_history.db 恢复已完成的任务
      await _restoreCompletedFromHistory();
      
      if (_tasks.isNotEmpty) {
        notifyListeners();
        await logger.log('Download', '从数据库恢复了 ${_tasks.length} 个下载任务');
      }
    } catch (e) {
      Logger().log('Download', '恢复任务失败: $e');
    }
  }
  
  /// 从 download_history.db 恢复已完成的任务
  ///
  /// 重要：必须校验文件是否真实存在。
  /// 历史记录与任务表是两套独立的表，删除时若只清掉其中一处，
  /// 残留记录会在下次启动时被无条件当成「已完成」重新显示，
  /// 表现为「已删除的下载又冒出来了」。
  /// 这里对文件已丢失的记录直接跳过，并顺手清理其残留历史记录。
  Future<void> _restoreCompletedFromHistory() async {
    if (_crawler == null) return;
    
    try {
      final history = await _crawler!.getDownloadHistory(limit: 1000);
      int restoredCount = 0;
      final staleIds = <String>[];
      
      for (final record in history) {
        final videoId = record['video_id'] as String?;
        if (videoId == null || _taskMap.containsKey(videoId)) continue;
        
        final filePath = record['file_path'] as String?;
        
        // 校验文件真实存在，不存在则视为失效记录，不再恢复
        bool fileExists = false;
        if (filePath != null && filePath.isNotEmpty) {
          try {
            fileExists = await File(filePath).exists();
          } catch (_) {
            fileExists = false;
          }
        }
        
        if (!fileExists) {
          staleIds.add(videoId);
          continue;
        }
        
        final video = VideoInfo(
          id: videoId,
          url: (record['url'] as String?) ?? '',
          title: (record['title'] as String?) ?? '未知视频',
          // 恢复时把封面/作者/时长一并还原，否则「已下载」列表里
          // 这些字段全为空白，用户看不出下的是谁的作品。
          cover: record['cover'] as String?,
          author: record['author'] as String?,
          duration: record['duration'] as String?,
          uploadDate: record['upload_date'] as String?,
        );
        
        final task = DownloadTask(id: video.id, video: video);
        task.status = DownloadStatus.completed;
        task.filePath = filePath;
        final timeRaw = record['download_time'];
        if (timeRaw is String && timeRaw.isNotEmpty) {
          final t = DateTime.tryParse(timeRaw);
          if (t != null) {
            task.startTime = t;
            task.endTime = t;  // 历史记录只有完成时刻，两者取同一值
          }
        }
        
        _tasks.add(task);
        _taskMap[video.id] = task;
        restoredCount++;
      }
      
      // 清理失效的历史记录，避免每次启动都重复扫描
      if (staleIds.isNotEmpty) {
        await logger.log('Download', '发现 ${staleIds.length} 条文件已丢失的历史记录，正在清理');
        for (final id in staleIds) {
          try {
            await _crawler!.deleteDownloadHistory(id);
          } catch (e) {
            Logger().log('Download', '清理失效历史记录失败 ($id): $e');
          }
        }
      }
      
      if (restoredCount > 0) {
        await logger.log('Download', '从历史记录恢复了 $restoredCount 个已完成任务');
      }
    } catch (e) {
      Logger().log('Download', '从历史记录恢复失败: $e');
    }
  }
}
