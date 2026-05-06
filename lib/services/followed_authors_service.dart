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

  FollowedAuthor({
    required this.authorId,
    required this.authorName,
    this.avatarUrl,
    required this.followedAt,
  });

  factory FollowedAuthor.fromMap(Map<String, dynamic> map) {
    return FollowedAuthor(
      authorId: map['author_id'] ?? '',
      authorName: map['author_name'] ?? '',
      avatarUrl: map['avatar_url'],
      followedAt: DateTime.tryParse(map['followed_at'] ?? '') ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'author_id': authorId,
      'author_name': authorName,
      'avatar_url': avatarUrl,
      'followed_at': followedAt.toIso8601String(),
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
          final dbDir = Directory('$_externalDbPath/.db');
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
        onCreate: (db, version) {
          return db.execute('''
            CREATE TABLE IF NOT EXISTS followed_authors (
              author_id TEXT PRIMARY KEY,
              author_name TEXT NOT NULL,
              avatar_url TEXT,
              followed_at TEXT NOT NULL
            )
          ''');
        },
        version: 1,
      );
      _dbInitialized = true;
      
      // 加载已关注列表
      await _loadFollowedList();
    } catch (e) {
      debugPrint('[FollowedAuthors] 数据库初始化失败: $e');
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

  /// 关注作者
  Future<bool> follow(String authorId, String authorName, {String? avatarUrl}) async {
    final db = await _getDb();
    if (db == null) return false;
    
    try {
      final author = FollowedAuthor(
        authorId: authorId,
        authorName: authorName,
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
      
      return true;
    } catch (e) {
      debugPrint('[FollowedAuthors] 关注作者失败: $e');
      return false;
    }
  }

  /// 取消关注作者
  Future<bool> unfollow(String authorId) async {
    final db = await _getDb();
    if (db == null) return false;
    
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
      
      return true;
    } catch (e) {
      debugPrint('[FollowedAuthors] 取消关注失败: $e');
      return false;
    }
  }

  /// 切换关注状态
  Future<bool> toggleFollow(String authorId, String authorName, {String? avatarUrl}) async {
    final isFollowedNow = await isFollowed(authorId);
    if (isFollowedNow) {
      return await unfollow(authorId);
    } else {
      return await follow(authorId, authorName, avatarUrl: avatarUrl);
    }
  }

  /// 获取已关注作者数量
  int get followedCount => _followedList.length;

  /// 刷新列表
  Future<void> refresh() async {
    await _loadFollowedList();
  }
}
