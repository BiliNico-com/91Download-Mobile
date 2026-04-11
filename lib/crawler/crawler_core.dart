/// 爬虫核心类
/// 严格参照 Python 版本 _src/lib/__init__.py

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'config.dart';
import '../models/video_info.dart';
import '../utils/logger.dart';

class CrawlerCore {
  final Dio _dio;
  String baseUrl;
  String? imgBaseUrl;
  String _siteType = "original";  // 默认 original，会自动检测
  bool _stopFlag = false;
  bool _pauseFlag = false;
  
  Database? _db;
  bool _dbInitialized = false;
  
  // 回调
  Function(String msg, String level)? onLog;
  Function(double progress, String msg)? onProgress;
  Function(int downloaded, int total)? onOverallProgress;

  CrawlerCore({
    required this.baseUrl,
    this.imgBaseUrl,
    Dio? dio,
  }) : _dio = dio ?? Dio() {
    _initDio();
    _detectSiteType();
  }
  
  /// 检测站点类型
  void _detectSiteType() {
    _siteType = CrawlerConfig.detectSiteType(baseUrl);
    print('[Crawler] 站点类型检测: domain=${Uri.parse(baseUrl).host}, type=$_siteType');
  }
  
  /// 获取站点类型
  String get siteType => _siteType;

  void _initDio() {
    _dio.options = BaseOptions(
      connectTimeout: Duration(seconds: CrawlerConfig.connectTimeout),
      receiveTimeout: Duration(seconds: CrawlerConfig.readTimeout),
      headers: CrawlerConfig.defaultHeaders,
      followRedirects: true,
    );
    
    // 设置 Referer
    _dio.options.headers['Referer'] = '$baseUrl/';
    
    // 设置语言 Cookie（关键！）
    _setLanguageCookie();
  }

  /// 设置语言 Cookie - 必须与 Python 版本一致
  void _setLanguageCookie() {
    final uri = Uri.parse(baseUrl);
    final domain = uri.host;
    
    // 设置 language=cn_CN（注意：正确名称是 language，不是 session_language）
    _dio.options.headers['Cookie'] = 'language=cn_CN';
    
    // 如果是 91porn.com，需要额外设置
    if (domain.contains('91porn.com')) {
      _dio.options.headers['Cookie'] = 'language=cn_CN; domain=.91porn.com; path=/';
    }
    
    print('[Crawler] 设置语言 Cookie: language=cn_CN (domain=$domain)');
  }

  /// 初始化数据库
  Future<void> _initDb() async {
    if (_dbInitialized) return;
    try {
      final dbPath = await getDatabasesPath();
      _db = await openDatabase(
        '$dbPath/download_history.db',
        onCreate: (db, version) {
          return db.execute('''
            CREATE TABLE IF NOT EXISTS download_history (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              video_id TEXT UNIQUE,
              title TEXT,
              url TEXT,
              file_path TEXT,
              upload_date TEXT,
              download_time TEXT,
              file_exists INTEGER DEFAULT 1
            )
          ''');
        },
        version: 1,
      );
      _dbInitialized = true;
    } catch (e) {
      print('[Crawler] 数据库初始化失败: $e');
    }
  }
  
  /// 确保数据库已初始化
  Future<Database?> _getDb() async {
    await _initDb();
    return _db;
  }

  // ==================== 获取视频列表 ====================

  /// 获取视频列表
  /// [listType] 列表类型（list/ori/hot/top等）
  /// [page] 页码
  Future<List<VideoInfo>> getVideoList(String listType, int page) async {
    // 根据站点类型选择 URL 模板
    final listTypes = CrawlerConfig.getListTypes(_siteType);
    final urlPattern = listTypes[listType];
    
    if (urlPattern == null) {
      await logger.e('Crawler', '未知的列表类型: $listType (siteType=$_siteType)');
      throw Exception('未知的列表类型: $listType');
    }
    
    final url = '$baseUrl/${urlPattern.replaceAll('{page}', page.toString())}';
    await logger.i('Crawler', '网络请求: GET $url (siteType=$_siteType)');
    
    try {
      final resp = await _dio.get(url);
      await logger.d('Crawler', '响应状态: ${resp.statusCode}, 长度: ${resp.data.toString().length}');
      
      final html = resp.data.toString();
      
      // 根据站点类型选择解析方法
      List<VideoInfo> videos;
      if (_siteType == "porn91") {
        videos = _parseVideoListPorn91(html);
      } else {
        videos = _parseVideoListOriginal(html);
      }
      
      await logger.i('Crawler', '解析完成, 返回 ${videos.length} 个视频');
      return videos;
      
    } catch (e) {
      await logger.e('Crawler', '获取视频列表失败: $e');
      return [];
    }
  }

  /// 解析视频列表 HTML - porn91 CMS（91porn 风格）
  List<VideoInfo> _parseVideoListPorn91(String html) {
    final videos = <VideoInfo>[];
    final seenIds = <String>{};
    
    print('[Crawler] 解析 porn91 HTML, 长度: ${html.length}');
    
    // 策略1：只匹配 col-lg-3 容器内的视频卡片（过滤 col-lg-8 广告）
    final containerMatches = CrawlerConfig.containerPattern.allMatches(html).toList();
    print('[Crawler] 找到 ${containerMatches.length} 个 col-lg-3 视频容器');
    
    for (var i = 0; i < containerMatches.length; i++) {
      final match = containerMatches[i];
      final start = match.start;
      final end = (i + 1 < containerMatches.length) 
          ? containerMatches[i + 1].start 
          : html.length;
      
      final wellContent = html.substring(start, end);
      
      // 提取 viewkey
      final viewkeyMatch = CrawlerConfig.viewkeyPattern.firstMatch(wellContent);
      if (viewkeyMatch == null) continue;
      
      final videoHref = viewkeyMatch.group(1)!.replaceAll('&amp;', '&');
      final viewkey = viewkeyMatch.group(2)!;
      
      // 提取封面（优先从 playvthumb_XXXXXX）
      String? cover;
      final playvthumbMatch = CrawlerConfig.playvthumbPattern.firstMatch(wellContent);
      if (playvthumbMatch != null) {
        cover = VideoInfo.buildCoverUrl(playvthumbMatch.group(1)!);
      }
      
      // 提取标题
      final titleMatch = CrawlerConfig.titlePattern.firstMatch(wellContent);
      if (titleMatch == null) continue;
      
      final title = titleMatch.group(1)!.trim();
      
      // 提取作者
      String? author;
      final authorMatch = CrawlerConfig.authorPattern.firstMatch(wellContent);
      if (authorMatch != null) {
        author = authorMatch.group(1)!.trim();
      }
      
      // 提取时长
      String? duration;
      final durationMatch = CrawlerConfig.durationPattern.firstMatch(wellContent);
      if (durationMatch != null) {
        duration = durationMatch.group(1)!.trim();
      }
      
      // 构造完整 URL
      String videoUrl;
      if (videoHref.startsWith('http')) {
        videoUrl = videoHref;
      } else if (videoHref.startsWith('/')) {
        videoUrl = '$baseUrl$videoHref';
      } else {
        videoUrl = '$baseUrl/$videoHref';
      }
      
      // 去重
      if (seenIds.contains(viewkey)) continue;
      seenIds.add(viewkey);
      
      videos.add(VideoInfo(
        id: viewkey,
        url: videoUrl,
        title: title,
        cover: cover,
        author: author,
        duration: duration,
      ));
    }
    
    print('[Crawler] 解析到 ${videos.length} 个视频');
    return videos;
  }
  
  /// 解析视频列表 HTML - original CMS（ml0987/hsex 风格）
  /// 严格参照 Python 版本 _extract_search_results
  List<VideoInfo> _parseVideoListOriginal(String html) {
    final videos = <VideoInfo>[];
    final seenIds = <String>{};
    
    print('[Crawler] 解析 original HTML, 长度: ${html.length}');
    
    // 策略1: 完整容器解析 - 匹配 thumbnail 容器
    // <div class="thumbnail">
    //   <a href="video-xxx.htm"><div style="background-image:url('...')" title="标题"></div></a>
    //   <var class="duration">时长</var>
    //   <a href="user.htm?author=xxx">作者</a>
    // </div>
    final containerPattern = RegExp(
      r'<div[^>]*class="[^"]*thumbnail[^"]*"[^>]*>(.*?)</div>\s*</div>',
      caseSensitive: false,
      dotAll: true,
    );
    
    for (final containerMatch in containerPattern.allMatches(html)) {
      final container = containerMatch.group(1)!;
      
      // 提取视频链接和ID
      final videoLinkMatch = RegExp(r'href="(video-(\d+)\.htm)"').firstMatch(container);
      if (videoLinkMatch == null) continue;
      
      final videoHref = videoLinkMatch.group(1)!;
      final videoId = videoLinkMatch.group(2)!;
      
      if (seenIds.contains(videoId)) continue;
      seenIds.add(videoId);
      
      // 提取封面（支持HTML实体编码 &#39; 和普通引号）
      String? cover;
      final coverMatch = RegExp(r'background-image:\s*url\(([^)]+)\)').firstMatch(container);
      if (coverMatch != null) {
        var coverUrl = coverMatch.group(1)!.trim();
        // 去掉引号（包括HTML实体编码）
        coverUrl = coverUrl.replaceAll('&#39;', '').replaceAll('&apos;', '');
        coverUrl = coverUrl.replaceAll(RegExp(r'''['"]'''), '');
        if (coverUrl.startsWith('http')) {
          cover = coverUrl;
        } else if (coverUrl.isNotEmpty) {
          cover = '$baseUrl/$coverUrl';
        }
      }
      
      // 提取标题
      String? title;
      final titleMatch = RegExp(r'title="([^"]+)"').firstMatch(container);
      if (titleMatch != null) {
        title = titleMatch.group(1)!.trim();
      }
      if (title == null) {
        // 备用：从 h5 或标题区域提取
        final h5Match = RegExp(r'<h5[^>]*>.*?<a[^>]*>([^<]+)</a>').firstMatch(container);
        if (h5Match != null) {
          title = h5Match.group(1)!.trim();
        }
      }
      if (title == null) continue;
      
      // 提取时长 <var class="duration">时长</var>
      String? duration;
      final durationMatch = RegExp(r'<var[^>]*class="[^"]*duration[^"]*"[^>]*>([^<]+)</var>').firstMatch(container);
      if (durationMatch != null) {
        duration = durationMatch.group(1)!.trim();
      }
      
      // 提取作者 <a href="user.htm?author=xxx">&nbsp;作者</a>
      String? author;
      final authorMatch = RegExp(r'<a[^>]*href="user\.htm\?author=([^"]+)"[^>]*>(?:&nbsp;)?([^<]+)</a>').firstMatch(container);
      if (authorMatch != null) {
        author = authorMatch.group(2)!.trim();
      }
      
      videos.add(VideoInfo(
        id: videoId,
        url: '$baseUrl/$videoHref',
        title: title,
        cover: cover,
        author: author,
        duration: duration,
      ));
    }
    
    print('[Crawler] 策略1(thumbnail容器)找到 ${videos.length} 个视频');
    
    // 策略2: 简单链接格式（兜底）
    if (videos.isEmpty) {
      // 支持HTML实体编码的封面URL
      final pattern2 = RegExp(
        r'''<a[^>]*href="[^"]*video-(\d+)\.htm[^"]*"[^>]*>.*?background-image:\s*url\(([^)]+)\)''',
        caseSensitive: false,
        dotAll: true,
      );
      
      for (final match in pattern2.allMatches(html)) {
        final videoId = match.group(1)!;
        var coverUrl = match.group(2)!.trim();
        
        // 去掉引号和HTML实体编码
        coverUrl = coverUrl.replaceAll('&#39;', '').replaceAll('&apos;', '');
        coverUrl = coverUrl.replaceAll(RegExp(r'''['"]'''), '');
        
        String? cover;
        if (coverUrl.startsWith('http')) {
          cover = coverUrl;
        } else if (coverUrl.isNotEmpty) {
          cover = '$baseUrl/$coverUrl';
        }
        
        if (seenIds.contains(videoId)) continue;
        seenIds.add(videoId);
        
        // 提取标题
        String? title;
        final pos = match.end;
        final blockEnd = pos + 500 < html.length ? pos + 500 : html.length;
        final block = html.substring(pos, blockEnd);
        final titleMatch = RegExp(r'title="([^"]+)"').firstMatch(html.substring(match.start, match.end + 500));
        if (titleMatch != null) {
          title = titleMatch.group(1)!.trim();
        }
        if (title == null) continue;
        
        // 尝试从上下文提取时长和作者
        String? duration;
        String? author;
        
        final durationMatch = RegExp(r'<var[^>]*class="[^"]*duration[^"]*"[^>]*>([^<]+)</var>').firstMatch(block);
        if (durationMatch != null) {
          duration = durationMatch.group(1)!.trim();
        }
        
        final authorMatch = RegExp(r'<a[^>]*href="user\.htm\?author=([^"]+)"[^>]*>(?:&nbsp;)?([^<]+)</a>').firstMatch(block);
        if (authorMatch != null) {
          author = authorMatch.group(2)!.trim();
        }
        
        videos.add(VideoInfo(
          id: videoId,
          url: '$baseUrl/video-$videoId.htm',
          title: title,
          cover: cover,
          author: author,
          duration: duration,
        ));
      }
      
      print('[Crawler] 策略2找到 ${videos.length} 个视频');
    }
    
    print('[Crawler] 解析到 ${videos.length} 个视频');
    return videos;
  }

  // ==================== 搜索 ====================

  /// 搜索视频
  Future<List<VideoInfo>> searchVideos(String keyword, {int page = 1, String sort = "new"}) async {
    // 根据站点类型构建搜索URL
    final url = CrawlerConfig.buildSearchUrl(baseUrl, _siteType, keyword, page: page, sort: sort);
    await logger.i('Crawler', '网络请求: 搜索视频 $url (siteType=$_siteType)');
    
    try {
      final resp = await _dio.get(url);
      await logger.d('Crawler', '搜索响应状态: ${resp.statusCode}');
      final html = resp.data.toString();
      
      // 根据站点类型选择解析方法
      List<VideoInfo> videos;
      if (_siteType == "porn91") {
        videos = _parseVideoListPorn91(html);
      } else {
        videos = _parseVideoListOriginal(html);
      }
      
      await logger.i('Crawler', '搜索完成, 返回 ${videos.length} 个结果');
      return videos;
    } catch (e) {
      await logger.e('Crawler', '搜索失败: $e');
      return [];
    }
  }

  /// 搜索作者
  Future<List<AuthorInfo>> searchAuthors(String keyword) async {
    final url = '$baseUrl/search_result.php?search_id=${Uri.encodeComponent(keyword)}&search_type=author';
    await logger.i('Crawler', '网络请求: 搜索作者 $url');
    
    try {
      final resp = await _dio.get(url);
      await logger.d('Crawler', '搜索作者响应状态: ${resp.statusCode}');
      final html = resp.data.toString();
      
      final authors = <AuthorInfo>[];
      final seenNames = <String>{};
      
      // 匹配作者链接（参考PC版正则）
      // <a class="btn btn-default" href="user.htm?author=xxx">&nbsp;名字&nbsp;<span class="badge">数量</span></a>
      final pattern = RegExp(
        r'<a[^>]*class="[^"]*btn[^"]*"[^>]*href="user\.htm\?author=([^"]+)"[^>]*>\s*(&nbsp;)*([^<&]+)\s*(&nbsp;)*\s*<span[^>]*class="[^"]*badge[^"]*"[^>]*>\s*(\d+)\s*</span>\s*</a>',
        caseSensitive: false,
      );
      
      for (final match in pattern.allMatches(html)) {
        final authorParam = match.group(1) ?? '';
        final namePart = (match.group(3) ?? '').trim();
        final count = int.tryParse(match.group(5) ?? '0') ?? 0;
        
        if (!seenNames.contains(namePart)) {
          seenNames.add(namePart);
          authors.add(AuthorInfo(
            name: namePart.isNotEmpty ? namePart : authorParam,
            videoCount: count,
            profileUrl: '$baseUrl/user.htm?author=$authorParam',
          ));
        }
      }
      
      await logger.i('Crawler', '搜索作者完成, 结果数: ${authors.length}');
      return authors;
    } catch (e) {
      await logger.e('Crawler', '搜索作者失败: $e');
      return [];
    }
  }

  // ==================== 获取视频详情 ====================

  /// 获取视频详情（m3u8地址等）
  Future<VideoInfo?> getVideoDetail(VideoInfo video) async {
    try {
      await logger.i('Crawler', '========== 开始获取视频详情 ==========');
      await logger.i('Crawler', '视频URL: ${video.url}');
      await logger.i('Crawler', '站点类型: $_siteType');
      
      final resp = await _dio.get(video.url);
      final html = resp.data.toString();
      await logger.d('Crawler', '页面响应状态: ${resp.statusCode}');
      await logger.d('Crawler', '页面长度: ${html.length} 字节');
      
      // 记录 HTML 片段用于调试
      if (html.length < 2000) {
        await logger.d('Crawler', '完整HTML: $html');
      } else {
        await logger.d('Crawler', 'HTML前500字符: ${html.substring(0, 500)}');
      }
      
      String? videoUrl;
      String? extractionMethod;
      
      // ===== porn91 专用策略 =====
      if (_siteType == "porn91") {
        await logger.d('Crawler', '[Porn91策略] 尝试提取视频URL...');
        
        // 策略 A: strencode2("%3c%73%6f...") — URL 编码的 <source> 标签
        await logger.d('Crawler', '[策略A] 查找 strencode2 编码...');
        final strencodeMatch = RegExp(r'''strencode2\(["'](%[0-9a-fA-F]{2}[^"']+)["']\)''').firstMatch(html);
        if (strencodeMatch != null) {
          try {
            final encoded = strencodeMatch.group(1)!;
            await logger.d('Crawler', '[策略A] 找到编码: ${encoded.substring(0, encoded.length > 50 ? 50 : encoded.length)}...');
            final decoded = Uri.decodeComponent(encoded);
            await logger.d('Crawler', '[策略A] 解码成功, 长度: ${decoded.length}');
            await logger.d('Crawler', '[策略A] 解码内容前200字符: ${decoded.substring(0, decoded.length > 200 ? 200 : decoded.length)}');
            
            // 从解码后的 HTML 中提取 src 属性
            final srcMatch = RegExp(r'''src=["'](https?://[^"']+\.(?:mp4|m3u8)[^"']*)["']''', caseSensitive: false).firstMatch(decoded);
            if (srcMatch != null) {
              videoUrl = srcMatch.group(1)?.replaceAll('&amp;', '&');
              extractionMethod = 'strencode2解码';
              await logger.i('Crawler', '[策略A成功] 从 strencode2 提取视频: $videoUrl');
            } else {
              await logger.w('Crawler', '[策略A] 解码后未找到视频URL');
            }
          } catch (e) {
            await logger.e('Crawler', '[策略A] strencode2 解码失败: $e');
          }
        } else {
          await logger.w('Crawler', '[策略A] 未找到 strencode2 编码');
        }
        
        // 策略 B: 直接查找 <source> 标签
        if (videoUrl == null) {
          await logger.d('Crawler', '[策略B] 查找 <source> 标签...');
          final sourcePattern = RegExp(r'''<source[^>]+src=["']([^"']+)["']''', caseSensitive: false);
          final sourceMatches = sourcePattern.allMatches(html).toList();
          await logger.d('Crawler', '[策略B] 找到 ${sourceMatches.length} 个 <source> 标签');
          
          for (var i = 0; i < sourceMatches.length && videoUrl == null; i++) {
            final match = sourceMatches[i];
            final src = match.group(1)?.replaceAll('&amp;', '&') ?? '';
            await logger.d('Crawler', '[策略B] 检查第 ${i+1} 个source: $src');
            
            if (src.contains('.mp4') || src.contains('.m3u8')) {
              videoUrl = src;
              extractionMethod = 'source标签';
              await logger.i('Crawler', '[策略B成功] 从 <source> 提取视频: $videoUrl');
            }
          }
        }
        
        // 策略 C: 查找内嵌 JavaScript 中的视频 URL
        if (videoUrl == null) {
          await logger.d('Crawler', '[策略C] 查找 JavaScript 内嵌URL...');
          final jsPatterns = [
            r'''\.(?:mp4|m3u8)["']?\s*;''',  // 简化匹配
            r'''["']https?://[^"']+\.(?:mp4|m3u8)[^"']*["']''',
          ];
          
          for (final pattern in jsPatterns) {
            final match = RegExp(pattern, caseSensitive: false).firstMatch(html);
            if (match != null) {
              await logger.d('Crawler', '[策略C] 找到候选: ${match.group(0)}');
              final urlMatch = RegExp(r'''https?://[^"'\s]+\.(?:mp4|m3u8)[^"'\s]*''').firstMatch(match.group(0)!);
              if (urlMatch != null) {
                videoUrl = urlMatch.group(0);
                extractionMethod = 'JS内嵌';
                await logger.i('Crawler', '[策略C成功] 从 JS 提取: $videoUrl');
                break;
              }
            }
          }
        }
      }
      
      // ===== 通用策略 (original CMS) =====
      if (videoUrl == null) {
        await logger.d('Crawler', '[通用策略] 开始通用URL提取...');
        
        // 策略1: 从 <source> 标签提取 m3u8
        final sourceMatch = RegExp(r'''<source[^>]+src="([^"]+\.m3u8[^"]*)"''', caseSensitive: false).firstMatch(html);
        if (sourceMatch != null) {
          videoUrl = sourceMatch.group(1);
          extractionMethod = 'source-m3u8';
          await logger.i('Crawler', '[通用策略1成功] 从 <source> 发现 m3u8: $videoUrl');
        }
        
        // 策略2: 搜索任何 .m3u8 URL
        if (videoUrl == null) {
          final m3u8Match = CrawlerConfig.m3u8Pattern.firstMatch(html);
          if (m3u8Match != null) {
            videoUrl = m3u8Match.group(1);
            extractionMethod = '通用m3u8正则';
            await logger.i('Crawler', '[通用策略2成功] 从通用正则发现 m3u8: $videoUrl');
          }
        }
        
        // 策略3: 从 JavaScript 变量提取
        if (videoUrl == null) {
          final jsPatterns = [
            r'''(?:video_url|sourceUrl|videoUrl|m3u8_url|file)\s*=\s*["']([^"']+\.m3u8[^"']*)["']''',
            r'''(?:video_url|sourceUrl|videoUrl|m3u8_url|file)\s*=\s*["'](https?://[^"']+)["']''',
          ];
          for (final pattern in jsPatterns) {
            final match = RegExp(pattern, caseSensitive: false).firstMatch(html);
            if (match != null) {
              videoUrl = match.group(1);
              extractionMethod = 'JS变量';
              await logger.i('Crawler', '[通用策略3成功] 从 JS 变量发现 m3u8: $videoUrl');
              break;
            }
          }
        }
      }
      
      if (videoUrl != null) {
        // 提取作者信息
        String? author = video.author;
        if (author == null) {
          if (_siteType == "porn91") {
            final authorMatch = CrawlerConfig.authorPattern.firstMatch(html);
            if (authorMatch != null) {
              author = authorMatch.group(1)?.trim();
            }
          } else {
            // original CMS
            final authorMatch = CrawlerConfig.authorPatternOriginal.firstMatch(html);
            if (authorMatch != null) {
              author = authorMatch.group(1)?.trim();
            }
          }
        }
        
        // 提取时长
        String? duration = video.duration;
        if (duration == null) {
          if (_siteType == "porn91") {
            final durationMatch = CrawlerConfig.durationPattern.firstMatch(html);
            if (durationMatch != null) {
              duration = durationMatch.group(1)?.trim();
            }
          } else {
            // original CMS
            final durationMatch = CrawlerConfig.durationPatternOriginal.firstMatch(html);
            if (durationMatch != null) {
              duration = durationMatch.group(1)?.trim();
            }
          }
        }
        
        await logger.i('Crawler', '========== 视频详情获取成功 ==========');
        await logger.i('Crawler', '提取方式: $extractionMethod');
        await logger.i('Crawler', '视频URL: $videoUrl');
        await logger.i('Crawler', '作者: $author, 时长: $duration');
        
        return VideoInfo(
          id: video.id,
          url: video.url,
          title: video.title,
          cover: video.cover,
          author: author,
          duration: duration,
          m3u8Url: videoUrl,
        );
      }
      
      await logger.e('Crawler', '========== 视频详情获取失败 ==========');
      await logger.e('Crawler', '所有策略均未能提取到视频URL');
      // 输出更多调试信息
      await logger.e('Crawler', 'HTML样例(中间1000字符): ${html.substring(html.length > 5000 ? 2500 : html.length > 1000 ? 500 : 0, html.length > 5000 ? 3500 : html.length)}');
      return null;
    } catch (e, stack) {
      await logger.e('Crawler', '获取视频详情异常: $e');
      await logger.e('Crawler', '堆栈: $stack');
      return null;
    }
  }

  // ==================== 下载 ====================

  /// 下载视频
  Future<bool> downloadVideo(VideoInfo video, String savePath) async {
    if (video.m3u8Url == null) {
      // 先获取 m3u8 地址
      final detail = await getVideoDetail(video);
      if (detail == null || detail.m3u8Url == null) {
        onLog?.call('获取视频地址失败', 'error');
        return false;
      }
      video = detail;
    }
    
    final videoUrl = video.m3u8Url!;
    
    // 检查是否是直接 MP4 链接（porn91 等站点使用）
    final isDirectMp4 = videoUrl.endsWith('.mp4') || videoUrl.contains('.mp4?');
    
    if (isDirectMp4) {
      // 直接下载 MP4 文件
      return await _downloadDirectMp4(video, videoUrl, savePath);
    }
    
    onLog?.call('开始下载: ${video.title}', 'info');
    
    try {
      // 下载 m3u8 文件
      final m3u8Resp = await _dio.get(videoUrl);
      final m3u8Content = m3u8Resp.data.toString();
      
      // 解析 TS 切片列表
      final tsUrls = _parseM3u8(m3u8Content, videoUrl);
      if (tsUrls.isEmpty) {
        onLog?.call('解析 TS 列表失败', 'error');
        return false;
      }
      
      onLog?.call('共 ${tsUrls.length} 个切片', 'info');
      
      // 创建临时目录
      final tempDir = Directory('${savePath}_temp');
      if (!await tempDir.exists()) {
        await tempDir.create(recursive: true);
      }
      
      // 并发下载 TS 切片
      int success = 0;
      final futures = <Future>[];
      
      for (var i = 0; i < tsUrls.length; i++) {
        if (_stopFlag) break;
        while (_pauseFlag) {
          await Future.delayed(Duration(milliseconds: 500));
        }
        
        final tsUrl = tsUrls[i];
        final tsPath = '${tempDir.path}/seg_${i.toString().padLeft(5, '0')}.ts';
        
        futures.add(_downloadTs(tsUrl, tsPath).then((ok) {
          if (ok) {
            success++;
            onProgress?.call(success / tsUrls.length, '下载中 $success/${tsUrls.length}');
          }
        }));
        
        // 控制并发数
        if (futures.length >= CrawlerConfig.maxConcurrentDownloads) {
          await Future.wait(futures);
          futures.clear();
        }
      }
      
      if (futures.isNotEmpty) {
        await Future.wait(futures);
      }
      
      if (_stopFlag) {
        onLog?.call('下载已停止', 'warn');
        return false;
      }
      
      // 合并 TS 文件
      onLog?.call('合并文件...', 'info');
      await _mergeTsFiles(tempDir.path, savePath);
      
      // 清理临时文件
      await tempDir.delete(recursive: true);
      
      // 保存到数据库
      await _saveToHistory(video, savePath);
      
      onLog?.call('下载完成: ${video.title}', 'info');
      return true;
      
    } catch (e) {
      onLog?.call('下载失败: $e', 'error');
      return false;
    }
  }

  /// 解析 M3U8
  List<String> _parseM3u8(String content, String baseUrl) {
    final urls = <String>[];
    final lines = content.split('\n');
    
    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      
      if (line.startsWith('http')) {
        urls.add(line);
      } else {
        // 相对路径转绝对路径
        final base = baseUrl.substring(0, baseUrl.lastIndexOf('/') + 1);
        urls.add('$base$line');
      }
    }
    
    return urls;
  }

  /// 下载单个 TS 切片
  Future<bool> _downloadTs(String url, String savePath) async {
    for (var retry = 0; retry < CrawlerConfig.maxRetries; retry++) {
      try {
        final resp = await _dio.get(
          url,
          options: Options(responseType: ResponseType.bytes),
        );
        
        final file = File(savePath);
        await file.writeAsBytes(resp.data);
        return true;
      } catch (e) {
        if (retry < CrawlerConfig.maxRetries - 1) {
          await Future.delayed(Duration(seconds: 1));
        }
      }
    }
    return false;
  }

  /// 直接下载 MP4 文件（用于 porn91 等提供直链的站点）
  Future<bool> _downloadDirectMp4(VideoInfo video, String mp4Url, String savePath) async {
    onLog?.call('开始下载 MP4: ${video.title}', 'info');
    onLog?.call('MP4 URL: $mp4Url', 'debug');
    
    try {
      // 获取文件大小
      final headResp = await _dio.head(mp4Url);
      final contentLength = int.tryParse(headResp.headers.value('content-length') ?? '0') ?? 0;
      
      if (contentLength > 0) {
        onLog?.call('文件大小: ${(contentLength / 1024 / 1024).toStringAsFixed(2)} MB', 'info');
      }
      
      // 下载文件
      await _dio.download(
        mp4Url,
        savePath,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            final progress = received / total;
            final downloadedMB = (received / 1024 / 1024).toStringAsFixed(1);
            final totalMB = (total / 1024 / 1024).toStringAsFixed(1);
            onProgress?.call(progress, '$downloadedMB/$totalMB MB');
          } else if (contentLength > 0) {
            final progress = received / contentLength;
            final downloadedMB = (received / 1024 / 1024).toStringAsFixed(1);
            final totalMB = (contentLength / 1024 / 1024).toStringAsFixed(1);
            onProgress?.call(progress, '$downloadedMB/$totalMB MB');
          }
        },
      );
      
      // 保存到历史记录
      await _saveToHistory(video, savePath);
      
      onLog?.call('下载完成: ${video.title}', 'info');
      return true;
      
    } catch (e) {
      onLog?.call('下载失败: $e', 'error');
      return false;
    }
  }

  /// 合并 TS 文件
  Future<void> _mergeTsFiles(String tempDir, String outputPath) async {
    final dir = Directory(tempDir);
    final files = await dir.list().toList();
    
    // 按文件名排序
    files.sort((a, b) => a.path.compareTo(b.path));
    
    final outputFile = File(outputPath);
    final sink = outputFile.openWrite();
    
    for (var file in files) {
      if (file is File) {
        final bytes = await file.readAsBytes();
        sink.add(bytes);
      }
    }
    
    await sink.close();
  }

  // ==================== 数据库操作 ====================

  /// 保存到历史记录
  Future<void> _saveToHistory(VideoInfo video, String filePath) async {
    final db = await _getDb();
    if (db == null) return;
    
    await db.insert(
      'download_history',
      {
        'video_id': video.id,
        'title': video.title,
        'url': video.url,
        'file_path': filePath,
        'download_time': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 检查是否已下载
  Future<bool> isDownloaded(String videoId) async {
    final db = await _getDb();
    if (db == null) return false;
    
    final result = await db.query(
      'download_history',
      where: 'video_id = ?',
      whereArgs: [videoId],
    );
    
    return result.isNotEmpty;
  }

  /// 获取下载历史
  Future<List<Map<String, dynamic>>> getDownloadHistory({
    int limit = 50,
    int offset = 0,
  }) async {
    final db = await _getDb();
    if (db == null) return [];
    
    return await db.query(
      'download_history',
      orderBy: 'download_time DESC',
      limit: limit,
      offset: offset,
    );
  }

  // ==================== 控制方法 ====================

  void stop() {
    _stopFlag = true;
  }

  void pause() {
    _pauseFlag = true;
  }

  void resume() {
    _pauseFlag = false;
  }

  void reset() {
    _stopFlag = false;
    _pauseFlag = false;
  }

  /// 更换站点
  void changeSite(String newBaseUrl) {
    baseUrl = newBaseUrl;
    _initDio();
    _detectSiteType();
  }
  
  /// 获取当前站点类型
  String get siteType => _siteType;
}
