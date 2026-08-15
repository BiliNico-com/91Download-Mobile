import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';

/// 作者信息模型
class FollowedAuthor {
  final String authorId;
  final String authorName;
  final String? avatarUrl;
  final DateTime followedAt;
  final String? lastVideoId;     // 最近一次检查到的视频ID
  final DateTime? lastCheckedAt; // 最近一次检查时间
  final int? newVideoCount;      // 新增视频数（本次检查发现）

  FollowedAuthor({
    required this.authorId,
    required this.authorName,
    this.avatarUrl,
    required this.followedAt,
    this.lastVideoId,
    this.lastCheckedAt,
    this.newVideoCount,
  });

  /// 是否有新内容（未检查过的不算）
  bool get hasNewContent => newVideoCount != null && newVideoCount! > 0;

  factory FollowedAuthor.fromMap(Map<String, dynamic> map) {
    return FollowedAuthor(
      authorId: map['author_id'] ?? '',
      authorName: map['author_name'] ?? '',
      avatarUrl: map['avatar_url'],
      followedAt: DateTime.tryParse(map['followed_at'] ?? '') ?? DateTime.now(),
      lastVideoId: map['last_video_id'],
      lastCheckedAt: map['last_checked_at'] != null
          ? DateTime.tryParse(map['last_checked_at'])
          : null,
      newVideoCount: map['new_video_count'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'author_id': authorId,
      'author_name': authorName,
      'avatar_url': avatarUrl,
      'followed_at': followedAt.toIso8601String(),
      'last_video_id': lastVideoId,
      'last_checked_at': lastCheckedAt?.toIso8601String(),
      'new_video_count': newVideoCount,
    };
  }
}

/// 作者关注服务
class FollowedAuthorsService extends ChangeNotifier {
  static FollowedAuthorsService? _instance;
  static FollowedAuthorsService get instance => _instance ??= FollowedAuthorsService._();
  
  Database? _db;
  bool _dbInitialized = false;
  String? _externalDbPath;
  
  /// 关注状态缓存（authorId -> bool）
  final Map<String, bool> _followedCache = {};
  
  /// 已关注作者列表缓存
  List<FollowedAuthor> _followedList = [];
  List<FollowedAuthor> get followedList => _followedList;

  FollowedAuthorsService._();

  /// 设置外部数据库路径
  void setExternalDbPath(String? path) {
    _externalDbPath = path;
  }

  /// 初始化数据库
  Future<void> _initDb() async {
    if (_dbInitialized) return;
    try {
      String dbPath;
      if (_externalDbPath != null && _externalDbPath!.isNotEmpty) {
        // 使用外部存储路径（卸载后保留）
        try {
          // 兼容迁移旧数据（旧版在 followed_db 目录，某次重构曾短暂改用 .db 目录）
          await _migrateLegacyDbIfNeeded(_externalDbPath!);
          final dbDir = Directory('$_externalDbPath/followed_db');
          if (!await dbDir.exists()) {
            await dbDir.create(recursive: true);
          }
          dbPath = '${dbDir.path}/followed_authors.db';
        } catch (e) {
          debugPrint('[FollowedAuthors] 外部存储不可用，回退到内部存储: $e');
          dbPath = '${await getDatabasesPath()}/followed_authors.db';
        }
      } else {
        // 使用应用私有路径
        dbPath = '${await getDatabasesPath()}/followed_authors.db';
      }
      
      _db = await openDatabase(
        dbPath,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS followed_authors (
              author_id TEXT PRIMARY KEY,
              author_name TEXT NOT NULL,
              avatar_url TEXT,
              followed_at TEXT NOT NULL,
              last_video_id TEXT,
              last_checked_at TEXT,
              new_video_count INTEGER DEFAULT 0
            )
          ''');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 3) {
            try { await db.execute('ALTER TABLE followed_authors ADD COLUMN last_video_id TEXT'); } catch (_) {}
            try { await db.execute('ALTER TABLE followed_authors ADD COLUMN last_checked_at TEXT'); } catch (_) {}
            try { await db.execute('ALTER TABLE followed_authors ADD COLUMN new_video_count INTEGER DEFAULT 0'); } catch (_) {}
          }
        },
        onDowngrade: (db, oldVersion, newVersion) async {},
        version: 3,
      );
      _dbInitialized = true;
      
      // 加载已关注列表
      await _loadFollowedList();
    } catch (e) {
      debugPrint('[FollowedAuthors] 数据库初始化失败: $e');
    }
  }

  /// 兼容迁移：旧版数据在 followed_db 目录，某次重构曾短暂改用 .db 目录。
  /// 若 followed_db 下没有库、但 .db 下有，则把 .db 的数据复制过来，避免丢失。
  Future<void> _migrateLegacyDbIfNeeded(String externalPath) async {
    final legacyDb = File('$externalPath/followed_db/followed_authors.db');
    final newDb = File('$externalPath/.db/followed_authors.db');
    try {
      if (!await legacyDb.exists() && await newDb.exists()) {
        await Directory('$externalPath/followed_db').create(recursive: true);
        await newDb.copy(legacyDb.path);
        debugPrint('[FollowedAuthors] 已将 .db 目录下的关注数据迁移到 followed_db');
      }
    } catch (e) {
      debugPrint('[FollowedAuthors] 迁移旧数据失败: $e');
    }
  }

  /// 确保数据库已初始化
  Future<Database?> _getDb() async {
    await _initDb();
    return _db;
  }

  /// 加载已关注作者列表
  Future<void> _loadFollowedList() async {
    final db = await _getDb();
    if (db == null) return;
    
    try {
      final maps = await db.query(
        'followed_authors',
        orderBy: 'followed_at DESC',
      );
      _followedList = maps.map((m) => FollowedAuthor.fromMap(m)).toList();
      
      // 更新缓存
      _followedCache.clear();
      for (final author in _followedList) {
        _followedCache[author.authorId] = true;
      }
      
      debugPrint('[FollowedAuthors] 加载关注列表完成，共 ${_followedList.length} 个作者');
      debugPrint('[FollowedAuthors] 缓存: $_followedCache');
      
      notifyListeners();
    } catch (e) {
      debugPrint('[FollowedAuthors] 加载关注列表失败: $e');
    }
  }

  /// 同步检查作者是否已关注（仅从缓存判断，可能不准确但快速）
  /// 用于 UI 快速判断，如果需要准确结果请使用 isFollowed()
  bool isFollowedSync(String authorId) {
    final result = _followedCache[authorId] ?? false;
    debugPrint('[FollowedAuthors] isFollowedSync($authorId) = $result, 缓存大小: ${_followedCache.length}');
    return result;
  }

  /// 检查作者是否已关注
  Future<bool> isFollowed(String authorId) async {
    // 先检查缓存
    if (_followedCache.containsKey(authorId)) {
      return _followedCache[authorId] ?? false;
    }
    
    // 缓存未命中，从数据库查询
    final db = await _getDb();
    if (db == null) return false;
    
    try {
      final result = await db.query(
        'followed_authors',
        where: 'author_id = ?',
        whereArgs: [authorId],
        limit: 1,
      );
      final isFollowed = result.isNotEmpty;
      _followedCache[authorId] = isFollowed;
      return isFollowed;
    } catch (e) {
      debugPrint('[FollowedAuthors] 检查关注状态失败: $e');
      return false;
    }
  }

  /// 关注作者，返回错误信息（null 表示成功）
  Future<String?> follow(String authorId, String authorName, {String? avatarUrl}) async {
    if (authorId.isEmpty) {
      return '作者ID为空';
    }

    final db = await _getDb();
    if (db == null) {
      return '数据存储初始化失败，请重启应用后重试';
    }
    
    try {
      final name = authorName.isNotEmpty ? authorName : authorId;
      final author = FollowedAuthor(
        authorId: authorId,
        authorName: name,
        avatarUrl: avatarUrl,
        followedAt: DateTime.now(),
      );
      
      await db.insert(
        'followed_authors',
        author.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      
      _followedCache[authorId] = true;
      _followedList.insert(0, author);
      notifyListeners();
      
      return null;  // null = 成功
    } catch (e) {
      debugPrint('[FollowedAuthors] 关注作者失败: $e');
      return '关注失败: $e';
    }
  }

  /// 取消关注作者，返回错误信息（null 表示成功）
  Future<String?> unfollow(String authorId) async {
    final db = await _getDb();
    if (db == null) {
      return '数据存储初始化失败，请重启应用后重试';
    }
    
    try {
      await db.delete(
        'followed_authors',
        where: 'author_id = ?',
        whereArgs: [authorId],
      );
      
      // 从缓存中移除（而不是设置为 false）
      _followedCache.remove(authorId);
      _followedList.removeWhere((a) => a.authorId == authorId);
      debugPrint('[FollowedAuthors] 已取消关注: $authorId, 剩余 ${_followedList.length} 个关注');
      notifyListeners();
      
      return null;  // null = 成功
    } catch (e) {
      debugPrint('[FollowedAuthors] 取消关注失败: $e');
      return '取消关注失败: $e';
    }
  }

  /// 切换关注状态，返回错误信息（null 表示成功）
  Future<String?> toggleFollow(String authorId, String authorName, {String? avatarUrl}) async {
    final isFollowedNow = await isFollowed(authorId);
    if (isFollowedNow) {
      return await unfollow(authorId);
    } else {
      return await follow(authorId, authorName, avatarUrl: avatarUrl);
    }
  }

  /// 获取已关注作者数量
  int get followedCount => _followedList.length;

  /// 有新内容的作者数量
  int get newContentCount => _followedList.where((a) => a.hasNewContent).length;

  /// 是否有作者未检查过（从未检查过的也算"可能更新"）
  bool get hasUncheckedAuthors => _followedList.any((a) => a.lastCheckedAt == null);

  /// 检查所有关注作者的更新情况
  /// [crawler] 用于爬取作者主页第一页
  /// [onProgress] 回调: (当前/总数, 作者名)
  /// 返回: 有更新的作者列表
  Future<List<FollowedAuthor>> checkForUpdates(
    dynamic crawler, {
    void Function(int current, int total, String authorName)? onProgress,
  }) async {
    final now = DateTime.now();
    final updatedAuthors = <FollowedAuthor>[];
    final total = _followedList.length;

    for (int i = 0; i < _followedList.length; i++) {
      final author = _followedList[i];
      onProgress?.call(i + 1, total, author.authorName);

      try {
        // 只爬取第一页，获取最新视频
        final videos = await crawler.getAuthorVideos(author.authorId, page: 1);
        
        if (videos.isNotEmpty) {
          final latestVideoId = videos.first.id;
          
          // 首次检查：记录最新视频ID，不算新内容
          if (author.lastVideoId == null) {
            await _saveCheckResult(author.authorId, latestVideoId, now, 0);
            _updateAuthorInList(author.authorId, (a) => FollowedAuthor(
              authorId: a.authorId,
              authorName: a.authorName,
              avatarUrl: a.avatarUrl,
              followedAt: a.followedAt,
              lastVideoId: latestVideoId,
              lastCheckedAt: now,
              newVideoCount: 0,
            ));
          } else if (latestVideoId != author.lastVideoId) {
            // 有新视频：计算新增数量
            int newCount = 0;
            for (final v in videos) {
              if (v.id == author.lastVideoId) break;
              newCount++;
            }
            if (newCount == 0) newCount = 1; // 至少1个新的
            
            await _saveCheckResult(author.authorId, latestVideoId, now, newCount);
            _updateAuthorInList(author.authorId, (a) {
              final updated = FollowedAuthor(
                authorId: a.authorId,
                authorName: a.authorName,
                avatarUrl: a.avatarUrl,
                followedAt: a.followedAt,
                lastVideoId: latestVideoId,
                lastCheckedAt: now,
                newVideoCount: newCount,
              );
              updatedAuthors.add(updated);
              return updated;
            });
          } else {
            // 无更新（此时 lastVideoId 一定非 null，因为 null 分支已处理）
            await _saveCheckResult(author.authorId, author.lastVideoId!, now, 0);
            _updateAuthorInList(author.authorId, (a) => FollowedAuthor(
              authorId: a.authorId,
              authorName: a.authorName,
              avatarUrl: a.avatarUrl,
              followedAt: a.followedAt,
              lastVideoId: a.lastVideoId,
              lastCheckedAt: now,
              newVideoCount: 0,
            ));
          }
        }
      } catch (e) {
        debugPrint('[FollowedAuthors] 检查 ${author.authorName} 更新失败: $e');
      }
    }

    notifyListeners();
    return updatedAuthors;
  }

  /// 保存检查结果到数据库
  Future<void> _saveCheckResult(
    String authorId,
    String lastVideoId,
    DateTime checkedAt,
    int newCount,
  ) async {
    final db = await _getDb();
    if (db == null) return;
    try {
      await db.update(
        'followed_authors',
        {
          'last_video_id': lastVideoId,
          'last_checked_at': checkedAt.toIso8601String(),
          'new_video_count': newCount,
        },
        where: 'author_id = ?',
        whereArgs: [authorId],
      );
    } catch (e) {
      debugPrint('[FollowedAuthors] 保存检查结果失败: $e');
    }
  }

  /// 更新内存中的作者信息
  void _updateAuthorInList(
    String authorId,
    FollowedAuthor Function(FollowedAuthor) updateFn,
  ) {
    final index = _followedList.indexWhere((a) => a.authorId == authorId);
    if (index >= 0) {
      _followedList[index] = updateFn(_followedList[index]);
    }
  }

  /// 清除某个作者的新内容标记（进入作者页后调用）
  Future<void> clearNewFlag(String authorId) async {
    final db = await _getDb();
    if (db != null) {
      try {
        await db.update(
          'followed_authors',
          {'new_video_count': 0},
          where: 'author_id = ?',
          whereArgs: [authorId],
        );
      } catch (_) {}
    }
    _updateAuthorInList(authorId, (a) => FollowedAuthor(
      authorId: a.authorId,
      authorName: a.authorName,
      avatarUrl: a.avatarUrl,
      followedAt: a.followedAt,
      lastVideoId: a.lastVideoId,
      lastCheckedAt: a.lastCheckedAt,
      newVideoCount: 0,
    ));
    notifyListeners();
  }

  /// 刷新列表
  Future<void> refresh() async {
    await _loadFollowedList();
  }
}
