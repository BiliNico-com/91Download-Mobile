/// 爬虫核心类
/// 严格参照 Python 版本 _src/lib/__init__.py

import 'dart:async';
import 'dart:convert';
import 'dart:math';
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
  
  // Debug开关：是否保存HTML到文件
  bool saveDebugHtml = false;
  
  // 回调
  Function(String msg, String level)? onLog;
  Function(double progress, String msg)? onProgress;
  Function(int downloaded, int total)? onOverallProgress;

  CrawlerCore({
    required this.baseUrl,
    this.imgBaseUrl,
    Dio? dio,
  }) : _dio = dio ?? Dio() {
    // 重要：先检测站点类型，再初始化Dio（请求头依赖站点类型）
    _detectSiteType();
    _initDio();
  }
  
  /// 检测站点类型
  void _detectSiteType() {
    _siteType = CrawlerConfig.detectSiteType(baseUrl);
    Logger().logSync('Crawler', '站点类型检测: domain=${Uri.parse(baseUrl).host}, type=$_siteType');
  }
  
  /// 获取站点类型
  String get siteType => _siteType;
  
  /// 保存 HTML 到文件（调试用）
  Future<void> _saveHtmlToFile(String html, String listType, int page) async {
    // 检查开关
    if (!saveDebugHtml) return;
    
    try {
      // 保存到外部存储根目录下的 debug_html 文件夹
      final baseDir = await getExternalStorageDirectory();
      if (baseDir == null) {
        await logger.log('Debug', '无法获取外部存储目录');
        return;
      }
      // 简化路径：直接在包目录下的 debug_html 文件夹
      final dir = Directory('${baseDir.path}/debug_html');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${dir.path}/${_siteType}_${listType}_page$page\_$timestamp.html');
      await file.writeAsString(html);
      await logger.log('Debug', 'HTML已保存: ${file.path}');
    } catch (e) {
      await logger.log('Debug', '保存HTML失败: $e');
    }
  }

  /// 禁用缓存的请求选项（复用）
  Options get _noCacheOptions => Options(
    headers: {
      'Cache-Control': 'no-cache, no-store, must-revalidate',
      'Pragma': 'no-cache',
      'Expires': '0',
    },
    extra: {'cache': false},
  );

  void _initDio() {
    // 使用移动端请求头（porn91）或桌面端请求头（其他站点）
    final headers = CrawlerConfig.getHeaders(_siteType);
    
    _dio.options = BaseOptions(
      connectTimeout: Duration(seconds: CrawlerConfig.connectTimeout),
      receiveTimeout: Duration(seconds: CrawlerConfig.readTimeout),
      headers: headers,
      followRedirects: true,
      // 禁用 Dio HTTP 客户端缓存
      receiveDataWhenStatusError: false,
      extra: {'cache': false},
    );
    
    // 设置 Referer
    _dio.options.headers['Referer'] = '$baseUrl/';
    
    // 设置 Sec-Fetch-Site（动态设置，首次访问为none）
    _dio.options.headers['Sec-Fetch-Site'] = 'same-origin';
    
    // 设置语言 Cookie（关键！）
    _setLanguageCookie();
    
    // 日志记录请求头类型
    final isMobile = _siteType == "porn91";
    Logger().logSync('Crawler', '使用${isMobile ? "移动端" : "桌面端"}请求头 (siteType=$_siteType)');
  }

  /// 设置语言 Cookie - 必须与 Python 版本一致
  void _setLanguageCookie() {
    final uri = Uri.parse(baseUrl);
    final domain = uri.host;
    
    // 设置 language=cn_CN（注意：正确名称是 language，不是 session_language）
    // Cookie值只包含名值对，domain和path是属性，不属于值的一部分
    _dio.options.headers['Cookie'] = 'language=cn_CN';
    
    Logger().logSync('Crawler', '设置语言 Cookie: language=cn_CN (domain=$domain)');
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
      Logger().logSync('Crawler', '数据库初始化失败: $e');
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
      await logger.log('Crawler', '未知的列表类型: $listType (siteType=$_siteType)');
      throw Exception('未知的列表类型: $listType');
    }
    
    final url = '$baseUrl/${urlPattern.replaceAll('{page}', page.toString())}';
    // ✅ 修复4：使用更轻量的参数格式，避免触发反爬
    final ts = DateTime.now().millisecondsSinceEpoch;
    final urlWithCache = url.contains('?') ? '$url&_t=$ts' : '$url?_t=$ts';
    
    // ✅ 修复：日志记录实际请求的 URL
    await logger.log('Crawler', '网络请求: GET $urlWithCache (siteType=$_siteType)');
    
    try {
      String html;
      
      // ✅ 关键修复：porn91 需要 GET + POST 两步请求
      // Python版本逻辑：先GET获取初始cookie，再POST提交session_language=cn_CN
      if (_siteType == "porn91") {
        // 步骤1：GET 请求获取初始 cookie
        await logger.log('Crawler', 'porn91: 先 GET 请求获取初始 cookie...');
        final getResp = await _dio.get(urlWithCache, options: _noCacheOptions);
        
        // 从GET响应中提取Set-Cookie（Dio的headers key是小写的）
        final setCookies = getResp.headers['set-cookie'] ?? getResp.headers['Set-Cookie'];
        String cookies = _dio.options.headers['Cookie']?.toString() ?? 'language=cn_CN';
        if (setCookies != null && setCookies.isNotEmpty) {
          for (final cookie in setCookies) {
            // 提取cookie名值对（去掉domain、path等属性）
            final match = RegExp(r'^([^=]+=[^;]+)').firstMatch(cookie);
            if (match != null) {
              final cookieValue = match.group(1)!;
              // 避免重复添加相同的cookie
              if (!cookies.contains(cookieValue.split('=')[0] + '=')) {
                cookies += '; $cookieValue';
              }
            }
          }
          await logger.log('Crawler', 'porn91: 提取到 cookies: $cookies');
        }
        
        // 步骤2：POST 提交语言设置
        // 注意：必须使用 x-www-form-urlencoded 格式，不能用 JSON
        // 重要：添加Referer头，模拟浏览器行为
        await logger.log('Crawler', 'porn91: POST 提交语言设置 session_language=cn_CN');
        await logger.log('Crawler', 'porn91: POST URL=$urlWithCache');
        await logger.log('Crawler', 'porn91: POST Cookies=$cookies');
        final postResp = await _dio.post(
          urlWithCache,
          data: 'session_language=cn_CN',  // 使用字符串格式，Dio会自动设置 Content-Type: application/x-www-form-urlencoded
          options: Options(
            headers: {
              'Content-Type': 'application/x-www-form-urlencoded',
              'Cookie': cookies,  // 携带GET请求获取的cookie
              'Referer': urlWithCache,  // 添加Referer，模拟浏览器
              'Origin': baseUrl,  // 添加Origin
              'Cache-Control': 'no-cache, no-store, must-revalidate',
              'Pragma': 'no-cache',
            },
            extra: {'cache': false},
          ),
        );
        html = postResp.data.toString();
        await logger.log('Crawler', 'porn91: POST 响应长度 ${html.length} 字节');
        
        // ✅ 关键：将Cookie保存到全局，后续请求（如播放页）可以使用
        _dio.options.headers['Cookie'] = cookies;
        await logger.log('Crawler', 'porn91: 已保存Cookie到全局headers');
        
        // 检查响应中的分类信息
        final categoryMatch = RegExp(r'category=([a-z]+)').firstMatch(html);
        if (categoryMatch != null) {
          await logger.log('Crawler', 'porn91: 响应中的分类=${categoryMatch.group(1)}');
        }
      } else {
        // 其他站点：直接 GET
        final resp = await _dio.get(urlWithCache, options: _noCacheOptions);
        html = resp.data.toString();
      }
      
      // ✅ 调试日志：记录实际收到的 HTML 长度和前500字符
      await logger.log('Crawler', '收到响应: ${html.length} 字节, URL=$urlWithCache');
      await logger.log('Debug', 'HTML前500字符: ${html.substring(0, html.length > 500 ? 500 : html.length)}');
      
      // ✅ 保存原始 HTML 到文件（调试用）
      await _saveHtmlToFile(html, listType, page);
      
      // 根据站点类型选择解析方法
      List<VideoInfo> videos;
      if (_siteType == "porn91") {
        videos = _parseVideoListPorn91(html);
      } else {
        videos = _parseVideoListOriginal(html);
      }
      
      // ✅ 关键调试日志：记录 URL 和解析结果的对应关系
      await logger.log('Crawler', '解析结果: URL=$urlWithCache -> ${videos.length} 个视频');
      
      return videos;
      
    } catch (e) {
      await logger.log('Crawler', '获取视频列表失败: $e (URL=$urlWithCache)');
      return [];
    }
  }

  /// 解析视频列表 HTML - porn91 CMS（91porn 风格）
  List<VideoInfo> _parseVideoListPorn91(String html) {
    final videos = <VideoInfo>[];
    final seenIds = <String>{};
    
    Logger().logSync('Parse', '解析 porn91 HTML, 长度: ${html.length}');
    
    // 策略1：只匹配 col-lg-3 容器内的视频卡片（过滤 col-lg-8 广告）
    // 找到所有容器位置
    final containerMatches = CrawlerConfig.containerPattern.allMatches(html).toList();
    Logger().logSync('Parse', '找到 ${containerMatches.length} 个容器匹配');
    
    for (var i = 0; i < containerMatches.length; i++) {
      final match = containerMatches[i];
      final start = match.start;
      
      // 确定容器结束位置：找到下一个 <div class="col-xs-12 开始
      // 这样可以避开中间的广告位
      final nextDivPattern = RegExp(r'<div[^>]*class="[^"]*col-xs-12[^"]*"', caseSensitive: false);
      int? end;
      for (final m in nextDivPattern.allMatches(html)) {
        if (m.start > start) {
          end = m.start;
          break;
        }
      }
      
      final containerEnd = end ?? html.length;
      final wellContent = html.substring(start, containerEnd);
      
      // 提取 viewkey
      final viewkeyMatch = CrawlerConfig.viewkeyPattern.firstMatch(wellContent);
      if (viewkeyMatch == null) continue;
      
      final videoHref = viewkeyMatch.group(1)!.replaceAll('&amp;', '&');
      final viewkey = viewkeyMatch.group(2)!;
      
      // ✅ 修复：直接提取 img-responsive 的 src 属性获取封面ID
      // 注意：不能依赖容器ID（如 playvthumb_XXXXXX），因为它与实际图片文件名不一致！
      String? cover;
      String? coverId;
      
      // 优先从 img-responsive 标签提取（这是实际正确的封面URL）
      final imgMatch = RegExp(r'<img[^>]+class="img-responsive"[^>]+src="([^"]+)"')
          .firstMatch(wellContent);
      if (imgMatch != null) {
        final imgSrc = imgMatch.group(1)!;
        // 从URL中提取文件名作为封面ID（如 .../1191387.jpg -> 1191387）
        final idMatch = RegExp(r'/(\d+)\.(?:jpe?g|webp|png)', caseSensitive: false)
            .firstMatch(imgSrc);
        if (idMatch != null && idMatch.group(1) != null) {
          coverId = idMatch.group(1);
          cover = VideoInfo.buildCoverUrl(coverId!);
        } else if (imgSrc.startsWith('http')) {
          cover = imgSrc;
        }
      }
      
      // 提取标题
      final titleMatch = CrawlerConfig.titlePattern.firstMatch(wellContent);
      if (titleMatch == null) continue;
      
      final title = titleMatch.group(1)!.trim();
      
      // 提取作者（尝试多种格式）
      String? author;
      
      // 格式1: 作者：</span>xxx
      var authorMatch = CrawlerConfig.authorPattern.firstMatch(wellContent);
      if (authorMatch != null) {
        author = authorMatch.group(1)!.trim();
      }
      
      // 格式2: <a href="...author=xxx">作者名</a>
      if (author == null || author.isEmpty) {
        final linkMatch = RegExp(r'href="[^"]*author=([^"&]+)[^"]*"[^>]*>([^<]+)</a>', caseSensitive: false).firstMatch(wellContent);
        if (linkMatch != null) {
          author = linkMatch.group(2)?.trim();
        }
      }
      
      // 格式3: 作者：xxx（直接文本）
      if (author == null || author.isEmpty) {
        final textMatch = RegExp(r'作者[：:]\s*([^<\n\r]{2,20})').firstMatch(wellContent);
        if (textMatch != null) {
          author = textMatch.group(1)?.trim();
        }
      }
      
      // 清理作者名（去掉特殊字符）
      if (author != null) {
        author = author.replaceAll(RegExp(r'[\s　]+'), ' ').trim();
        if (author.isEmpty) author = null;
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
      
      // 详细日志
      Logger().logSync('Parse', '视频#${videos.length + 1}: ID=$viewkey, 封面ID=$coverId, 作者=$author, 时长=$duration, 标题=${title.length > 20 ? title.substring(0, 20) + "..." : title}');
      
      videos.add(VideoInfo(
        id: viewkey,
        url: videoUrl,
        title: title,
        cover: cover,
        author: author,
        authorId: null, // porn91 没有作者ID
        duration: duration,
      ));
    }
    
    Logger().logSync('Parse', '解析完成: ${videos.length} 个视频');
    
    return videos;
  }
  
  /// 解析视频列表 HTML - original CMS（ml0987/hsex 风格）
  /// 严格参照 Python 版本 _extract_search_results
  List<VideoInfo> _parseVideoListOriginal(String html) {
    final videos = <VideoInfo>[];
    final seenIds = <String>{};
    
    Logger().logSync('Parse', '解析 original HTML, 长度: ${html.length}');
    
    // 策略1: 完整容器解析 - 匹配 thumbnail 容器
    // <div class="thumbnail">
    //   <a>封面</a>
    //   <div class="caption title">标题</div>
    //   <div class="info"><p>&nbsp;&nbsp;<a href="user.htm?author=xxx">作者名</a></p></div>
    // </div>
    // ✅ 修复：匹配到下一个 </div> 后再找一个 </div>，确保包含 info 部分
    final containerPattern = RegExp(
      r'<div[^>]*class="[^"]*thumbnail[^"]*"[^>]*>([\s\S]*?)</div>\s*(?:</div>[\s\n]*)*</div>',
      caseSensitive: false,
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
      
      // 提取标题（允许 title= "xxx" 或 title="xxx" 格式）
      String? title;
      final titleMatch = RegExp(r'title\s*=\s*"([^"]+)"').firstMatch(container);
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
      
      // 提取作者（多种格式尝试）
      // ml0987 格式: <a href="user.htm?author=xxx">作者名</a>
      String? author;
      String? authorId;
      
      // 格式1: 带链接的作者 <a href="user.htm?author=xxx">作者名</a>
      var authorMatch = RegExp(
        r'<a[^>]*href="[^"]*user\.htm\?author=([^"&]+)"[^>]*>([^<]*)</a>',
        caseSensitive: false
      ).firstMatch(container);
      if (authorMatch != null) {
        authorId = authorMatch.group(1);
        author = authorMatch.group(2)?.replaceAll('&nbsp;', '').replaceAll(RegExp(r'&[a-z]+;'), '').trim();
      }
      
      // 格式2: 纯文本作者 作者：xxx
      if (author == null || author.isEmpty) {
        final textMatch = RegExp(r'作者[：:]\s*([^<\n\r]{2,20})').firstMatch(container);
        if (textMatch != null) {
          author = textMatch.group(1)?.trim();
        }
      }
      
      // 清理作者名
      if (author != null) {
        author = author.replaceAll(RegExp(r'[\s　]+'), ' ').trim();
        if (author.isEmpty) author = null;
      }
      
      // 从封面URL提取封面ID
      String? coverId;
      final coverIdMatch = RegExp(r'/(\d+)\.(webp|jpg|png)').firstMatch(cover ?? '');
      if (coverIdMatch != null) {
        coverId = coverIdMatch.group(1);
      }
      
      // 详细日志
      Logger().logSync('Parse', '视频#${videos.length + 1}: ID=$videoId, 封面ID=$coverId, 作者=$author, 作者ID=$authorId, 时长=$duration, 标题=${title.length > 20 ? title.substring(0, 20) + "..." : title}');
      
      videos.add(VideoInfo(
        id: videoId,
        url: '$baseUrl/$videoHref',
        title: title,
        cover: cover,
        author: author,
        authorId: authorId,
        duration: duration,
      ));
    }
    
    Logger().logSync('Parse', '策略1(thumbnail容器)找到 ${videos.length} 个视频');
    
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
        
        // 提取标题（允许 title= "xxx" 或 title="xxx" 格式）
        String? title;
        final pos = match.end;
        final blockEnd = pos + 500 < html.length ? pos + 500 : html.length;
        final block = html.substring(pos, blockEnd);
        final titleMatch = RegExp(r'title\s*=\s*"([^"]+)"').firstMatch(html.substring(match.start, match.end + 500));
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
        
        // 提取作者（多种格式）
        var authorMatch = RegExp(r'<a[^>]*href="[^"]*user\.htm\?author=([^"&]+)"[^>]*>([^<]*)</a>', caseSensitive: false).firstMatch(block);
        if (authorMatch != null) {
          author = authorMatch.group(2)?.replaceAll('&nbsp;', '').trim();
        }
        // 格式2: 纯文本
        if (author == null || author!.isEmpty) {
          final textMatch = RegExp(r'作者[：:]\s*([^<\n\r]{2,20})').firstMatch(block);
          if (textMatch != null) {
            author = textMatch.group(1)?.trim();
          }
        }
        
        // 从封面URL提取封面ID
        String? coverId;
        final coverIdMatch = RegExp(r'/(\d+)\.(webp|jpg|png)').firstMatch(cover ?? '');
        if (coverIdMatch != null) {
          coverId = coverIdMatch.group(1);
        }
        
        // 详细日志
        Logger().logSync('Parse', '视频#${videos.length + 1}: ID=$videoId, 封面ID=$coverId, 作者=$author, 时长=$duration, 标题=${title.length > 20 ? title.substring(0, 20) + "..." : title}');
        
        videos.add(VideoInfo(
          id: videoId,
          url: '$baseUrl/video-$videoId.htm',
          title: title,
          cover: cover,
          author: author,
          authorId: null, // 策略2无法提取作者ID
          duration: duration,
        ));
      }
      
      Logger().logSync('Parse', '策略2找到 ${videos.length} 个视频');
    }
    
    Logger().logSync('Parse', '解析完成: ${videos.length} 个视频');
    return videos;
  }

  // ==================== 搜索 ====================

  /// 搜索视频
  Future<List<VideoInfo>> searchVideos(String keyword, {int page = 1, String sort = "new"}) async {
    // 根据站点类型构建搜索URL
    final url = CrawlerConfig.buildSearchUrl(baseUrl, _siteType, keyword, page: page, sort: sort);
    
    // ✅ 修复：使用更轻量的参数格式
    final ts = DateTime.now().millisecondsSinceEpoch;
    final urlWithCache = url.contains('?') ? '$url&_t=$ts' : '$url?_t=$ts';
    
    // ✅ 修复：日志记录实际请求的 URL
    await logger.log('Crawler', '网络请求: 搜索视频 $urlWithCache (siteType=$_siteType)');
    
    try {
      final resp = await _dio.get(urlWithCache, options: _noCacheOptions);
      final html = resp.data.toString();
      
      // ✅ 调试日志
      await logger.log('Crawler', '搜索响应: ${html.length} 字节');
      
      // 根据站点类型选择解析方法
      List<VideoInfo> videos;
      if (_siteType == "porn91") {
        videos = _parseVideoListPorn91(html);
      } else {
        videos = _parseVideoListOriginal(html);
      }
      
      await logger.log('Crawler', '搜索结果: ${videos.length} 个视频');
      
      return videos;
    } catch (e) {
      await logger.log('Crawler', '搜索失败: $e (URL=$urlWithCache)');
      return [];
    }
  }

  /// 搜索作者
  Future<List<AuthorInfo>> searchAuthors(String keyword) async {
    // 根据站点类型构建不同的搜索URL
    String url;
    if (_siteType == "porn91") {
      // porn91 风格
      url = '$baseUrl/search_result.php?search_id=${Uri.encodeComponent(keyword)}&search_type=author';
    } else {
      // original 风格：使用 search.htm?search=xxx（和搜索视频一样的URL）
      url = '$baseUrl/search.htm?search=${Uri.encodeComponent(keyword)}';
    }
    
    // ✅ 修复：使用更轻量的参数格式
    final ts = DateTime.now().millisecondsSinceEpoch;
    final urlWithCache = url.contains('?') ? '$url&_t=$ts' : '$url?_t=$ts';
    
    // ✅ 修复：日志记录实际请求的 URL
    await logger.log('Crawler', '网络请求: 搜索作者 $urlWithCache');
    
    try {
      final resp = await _dio.get(urlWithCache, options: _noCacheOptions);
      final html = resp.data.toString();
      
      final authors = <AuthorInfo>[];
      final seenNames = <String>{};
      
      // 匹配作者链接
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
            id: authorParam,
            name: namePart.isNotEmpty ? namePart : authorParam,
            videoCount: count,
            profileUrl: '$baseUrl/user.htm?author=$authorParam',
          ));
        }
      }
      
      return authors;
    } catch (e) {
      await logger.log('Crawler', '搜索作者失败: $e');
      return [];
    }
  }

  // ==================== 作者主页 ====================

  /// 获取作者视频列表
  Future<List<VideoInfo>> getAuthorVideos(String authorId, {int page = 1}) async {
    String url;
    if (_siteType == "porn91") {
      // porn91 作者主页URL格式
      url = '$baseUrl/author.php?author=$authorId&page=$page';
    } else {
      // original CMS - 分页格式：user-N.htm?author=xxx
      url = '$baseUrl/user-$page.htm?author=$authorId';
    }
    
    // ✅ 修复：使用更轻量的参数格式
    final ts = DateTime.now().millisecondsSinceEpoch;
    final urlWithCache = url.contains('?') ? '$url&_t=$ts' : '$url?_t=$ts';
    
    // ✅ 修复：日志记录实际请求的 URL
    await logger.log('Crawler', '网络请求: 获取作者视频 $urlWithCache (siteType=$_siteType)');
    
    try {
      final resp = await _dio.get(urlWithCache, options: _noCacheOptions);
      final html = resp.data.toString();
      
      List<VideoInfo> videos;
      if (_siteType == "porn91") {
        videos = _parseVideoListPorn91(html);
      } else {
        videos = _parseVideoListOriginal(html);
      }
      
      return videos;
    } catch (e) {
      await logger.log('Crawler', '获取作者视频失败: $e (URL=$urlWithCache)');
      return [];
    }
  }

  // ==================== 获取视频详情 ====================

  /// 获取视频详情（m3u8地址等）
  Future<VideoInfo?> getVideoDetail(VideoInfo video) async {
    try {
      // ✅ 修复：使用更轻量的参数格式
      final ts = DateTime.now().millisecondsSinceEpoch;
      final urlWithCache = video.url.contains('?') 
          ? '${video.url}&_t=$ts' 
          : '${video.url}?_t=$ts';
      
      await logger.log('Crawler', '网络请求: 获取视频详情 $urlWithCache');
      
      // ✅ 携带Cookie请求播放页（关键！）
      // 获取当前存储的Cookie
      final currentCookie = _dio.options.headers['Cookie']?.toString() ?? 'language=cn_CN';
      
      final resp = await _dio.get(urlWithCache, options: Options(
        headers: {
          'Cookie': currentCookie,  // 携带Cookie
          'Cache-Control': 'no-cache, no-store, must-revalidate',
          'Pragma': 'no-cache',
          'Expires': '0',
        },
        extra: {'cache': false},
      ));
      final html = resp.data.toString();
      
      await logger.log('Crawler', '视频详情响应: ${html.length} 字节');
      
      // ✅ 调试：保存播放页HTML
      if (saveDebugHtml) {
        try {
          final baseDir = await getExternalStorageDirectory();
          if (baseDir != null) {
            final dir = Directory('${baseDir.path}/debug_html');
            if (!await dir.exists()) {
              await dir.create(recursive: true);
            }
            final timestamp = DateTime.now().millisecondsSinceEpoch;
            final file = File('${dir.path}/${_siteType}_detail_${video.id}_$timestamp.html');
            await file.writeAsString(html);
            await logger.log('Debug', '播放页HTML已保存: ${file.path}');
          }
        } catch (e) {
          await logger.log('Debug', '保存播放页HTML失败: $e');
        }
      }
      
      String? videoUrl;
      String? extractionMethod;
      
      // ===== porn91 专用策略 =====
      if (_siteType == "porn91") {
        
        // ✅ 从播放页 poster 属性提取视频ID（如 poster="https://.../thumb/848765.jpg"）
        // 注意：列表页封面ID与视频ID无关，必须用播放页poster ID
        String? posterVideoId;
        final posterMatch = RegExp(r'poster="[^"]*thumb/(\d+)\.jpg"').firstMatch(html);
        if (posterMatch != null) {
          posterVideoId = posterMatch.group(1);
          await logger.log('Debug', '播放页poster ID: $posterVideoId');
        } else {
          await logger.log('Debug', '⚠️ 未找到播放页poster属性');
        }
        
        // 策略 A: strencode2("%3c%73%6f...") — URL 编码的 <source> 标签
        // 可能有多个strencode2调用，优先匹配poster ID
        final strencodePattern = RegExp(r'''strencode2\(["'](%[0-9a-fA-F]{2}[^"']+)["']\)''');
        final strencodeMatches = strencodePattern.allMatches(html).toList();
        await logger.log('Debug', '找到 ${strencodeMatches.length} 个strencode2调用');
        
        for (var i = 0; i < strencodeMatches.length; i++) {
          final m = strencodeMatches[i];
          try {
            final encoded = m.group(1)!;
            final decoded = Uri.decodeComponent(encoded);
            await logger.log('Debug', 'strencode2#${i+1} 解码结果: ${decoded.length > 200 ? decoded.substring(0, 200) + "..." : decoded}');
            
            // 提取 src 属性
            final srcPattern = RegExp(r'''src=["']([^"']+)["']''', caseSensitive: false);
            final srcMatch = srcPattern.firstMatch(decoded);
            
            if (srcMatch != null) {
              final src = srcMatch.group(1)?.replaceAll('&amp;', '&') ?? '';
              if (src.contains('.mp4') || src.contains('.m3u8')) {
                // 提取视频URL中的ID
                final urlIdMatch = RegExp(r'/(\d+)\.(?:mp4|m3u8)').firstMatch(src);
                final urlVideoId = urlIdMatch?.group(1);
                await logger.log('Debug', '提取到视频URL: ID=$urlVideoId, URL=${src.length > 100 ? src.substring(0, 100) + "..." : src}');
                
                // 优先匹配poster ID
                if (posterVideoId != null && urlVideoId == posterVideoId) {
                  videoUrl = src;
                  extractionMethod = 'strencode2解码(ID匹配)';
                  await logger.log('Debug', '✅ poster ID匹配成功: posterVideoId=$posterVideoId');
                  break;  // 找到匹配的，退出循环
                } else if (videoUrl == null) {
                  // 没有poster ID时，取第一个作为候选
                  videoUrl = src;
                  extractionMethod = 'strencode2解码(首个)';
                  await logger.log('Debug', '⚠️ poster ID不匹配 (posterID=$posterVideoId, 视频ID=$urlVideoId)');
                }
              }
            }
          } catch (e) {
            await logger.log('Debug', 'strencode2解码失败: $e');
          }
        }
        
        // 策略 B: 直接查找 <source> 标签
        // 优先匹配封面ID，排除已知广告
        if (videoUrl == null) {
          
          final sourcePattern = RegExp(r'''<source[^>]+src=["']([^"']+)["']''', caseSensitive: false);
          final sourceMatches = sourcePattern.allMatches(html).toList();
          
          // 优先匹配poster ID
          for (var i = 0; i < sourceMatches.length; i++) {
            final match = sourceMatches[i];
            final src = match.group(1)?.replaceAll('&amp;', '&') ?? '';
            
            if (src.contains('.mp4') || src.contains('.m3u8')) {
              // 提取视频URL中的ID
              final urlIdMatch = RegExp(r'/(\d+)\.(?:mp4|m3u8)').firstMatch(src);
              final urlVideoId = urlIdMatch?.group(1);
              
              // 优先匹配poster ID
              if (posterVideoId != null && urlVideoId == posterVideoId) {
                videoUrl = src;
                extractionMethod = 'source标签(ID匹配)';
                break;
              }
            }
          }
          
          // 如果没有匹配到封面ID，取第一个非广告的source
          if (videoUrl == null) {
            for (var i = 0; i < sourceMatches.length; i++) {
              final match = sourceMatches[i];
              final src = match.group(1)?.replaceAll('&amp;', '&') ?? '';
              
              if (src.contains('.mp4') || src.contains('.m3u8')) {
                // 排除已知的广告视频ID
                if (src.contains('358999')) {
                  continue;
                }
                videoUrl = src;
                extractionMethod = 'source标签(首个非广告)';
                break;
              }
            }
          }
        }
        
        // 策略 C: 查找内嵌 JavaScript 中的视频 URL
        if (videoUrl == null) {
          final jsPatterns = [
            r'''\.(?:mp4|m3u8)["']?\s*;''',  // 简化匹配
            r'''["']https?://[^"']+\.(?:mp4|m3u8)[^"']*["']''',
          ];
          
          for (final pattern in jsPatterns) {
            final match = RegExp(pattern, caseSensitive: false).firstMatch(html);
            if (match != null) {
              final urlMatch = RegExp(r'''https?://[^"'\s]+\.(?:mp4|m3u8)[^"'\s]*''').firstMatch(match.group(0)!);
              if (urlMatch != null) {
                videoUrl = urlMatch.group(0);
                extractionMethod = 'JS内嵌';
                break;
              }
            }
          }
        }
      }
      
      // ===== 通用策略 (original CMS) =====
      if (videoUrl == null) {
        
        // 策略1: 从 <source> 标签提取 m3u8
        final sourceMatch = RegExp(r'''<source[^>]+src="([^"]+\.m3u8[^"]*)"''', caseSensitive: false).firstMatch(html);
        if (sourceMatch != null) {
          videoUrl = sourceMatch.group(1);
          extractionMethod = 'source-m3u8';
        }
        
        // 策略2: 搜索任何 .m3u8 URL
        if (videoUrl == null) {
          final m3u8Match = CrawlerConfig.m3u8Pattern.firstMatch(html);
          if (m3u8Match != null) {
            videoUrl = m3u8Match.group(1);
            extractionMethod = '通用m3u8正则';
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
        
        return VideoInfo(
          id: video.id,
          url: video.url,
          title: video.title,
          cover: video.cover,
          author: author,
          authorId: video.authorId, // 保留原有的作者ID
          duration: duration,
          m3u8Url: videoUrl,
        );
      }
      
      return null;
    } catch (e, stack) {
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
    
    var videoUrl = video.m3u8Url!;
    
    // 检查是否是直接 MP4 链接（porn91 等站点使用）
    final isDirectMp4 = videoUrl.endsWith('.mp4') || videoUrl.contains('.mp4?');
    
    if (isDirectMp4) {
      // 直接下载 MP4 文件
      return await _downloadDirectMp4(video, videoUrl, savePath);
    }
    
    onLog?.call('开始下载: ${video.title}', 'info');
    
    try {
      // 下载 m3u8 文件（禁用缓存）
      final m3u8Resp = await _dio.get(videoUrl, options: _noCacheOptions);
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
      
      // 记录下载状态：true=成功，false=失败
      final downloaded = List<bool>.filled(tsUrls.length, false);
      
      // 并发下载 TS 切片
      int success = 0;
      var futures = <Future<void>>[];
      
      // ✅ 进度节流：避免频繁更新UI导致进度条抽动
      DateTime? lastProgressUpdate;
      const progressThrottleMs = 200;  // 最小200ms更新一次
      
      for (var i = 0; i < tsUrls.length; i++) {
        if (_stopFlag) break;
        while (_pauseFlag) {
          await Future.delayed(Duration(milliseconds: 500));
        }
        
        final tsUrl = tsUrls[i];
        final tsPath = '${tempDir.path}/seg_${i.toString().padLeft(5, '0')}.ts';
        final index = i;  // 闭包捕获
        
        futures.add(_downloadTs(tsUrl, tsPath).then((ok) {
          downloaded[index] = ok;
          if (ok) {
            success++;
            // ✅ 节流更新进度
            final now = DateTime.now();
            if (lastProgressUpdate == null || 
                now.difference(lastProgressUpdate!).inMilliseconds >= progressThrottleMs) {
              onProgress?.call(success / tsUrls.length, '下载中 $success/${tsUrls.length}');
              lastProgressUpdate = now;
            }
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
      
      // ✅ 下载完成后强制更新一次最终进度
      onProgress?.call(success / tsUrls.length, '下载中 $success/${tsUrls.length}');
      
      if (_stopFlag) {
        onLog?.call('下载已停止', 'warn');
        return false;
      }
      
      // ✅ 新增：重试失败的切片（最多3轮）
      var failedIndices = <int>[];
      for (var i = 0; i < downloaded.length; i++) {
        if (!downloaded[i]) {
          failedIndices.add(i);
        }
      }
      
      for (var retryRound = 1; retryRound <= 3 && failedIndices.isNotEmpty; retryRound++) {
        onLog?.call('重试第 $retryRound 轮，${failedIndices.length} 个切片失败', 'warn');
        
        final stillFailed = <int>[];
        futures = [];
        
        // ✅ 重试时也使用进度节流
        DateTime? lastRetryProgressUpdate;
        
        for (final idx in failedIndices) {
          if (_stopFlag) break;
          
          final tsUrl = tsUrls[idx];
          final tsPath = '${tempDir.path}/seg_${idx.toString().padLeft(5, '0')}.ts';
          
          futures.add(_downloadTs(tsUrl, tsPath).then((ok) {
            if (ok) {
              downloaded[idx] = true;
              success++;
              // 节流更新
              final now = DateTime.now();
              if (lastRetryProgressUpdate == null || 
                  now.difference(lastRetryProgressUpdate!).inMilliseconds >= progressThrottleMs) {
                onProgress?.call(success / tsUrls.length, '重试中 $success/${tsUrls.length}');
                lastRetryProgressUpdate = now;
              }
            } else {
              stillFailed.add(idx);
            }
          }));
          
          if (futures.length >= CrawlerConfig.maxConcurrentDownloads) {
            await Future.wait(futures);
            futures.clear();
          }
        }
        
        if (futures.isNotEmpty) {
          await Future.wait(futures);
        }
        
        failedIndices = stillFailed;
        
        if (_stopFlag) {
          onLog?.call('下载已停止', 'warn');
          return false;
        }
      }
      
      // 检查成功率
      final successCount = downloaded.where((d) => d).length;
      final successRate = successCount / tsUrls.length * 100;
      
      if (failedIndices.isNotEmpty) {
        onLog?.call('有 ${failedIndices.length} 个切片下载失败（$successCount/${tsUrls.length}，成功率 ${successRate.toStringAsFixed(1)}%）', 'warn');
        
        if (successRate < 50) {
          onLog?.call('成功率低于 50%，放弃下载', 'error');
          await tempDir.delete(recursive: true);
          return false;
        }
        
        onLog?.call('将跳过失败的切片继续合并', 'warn');
      }
      
      // 合并 TS 文件（带完整性校验）
      onLog?.call('合并文件...', 'info');
      final mergeOk = await _mergeTsFiles(tempDir.path, savePath, downloaded);
      if (!mergeOk) {
        onLog?.call('合并失败：没有有效的切片文件', 'error');
        await tempDir.delete(recursive: true);
        return false;
      }
      
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

  /// 下载单个 TS 切片（带完整性校验）
  Future<bool> _downloadTs(String url, String savePath) async {
    for (var retry = 0; retry < CrawlerConfig.maxRetries; retry++) {
      try {
        final resp = await _dio.get(
          url,
          options: Options(
            responseType: ResponseType.bytes,
            headers: {
              'Cache-Control': 'no-cache, no-store, must-revalidate',
              'Pragma': 'no-cache',
            },
          ),
        );
        
        final bytes = resp.data as List<int>;
        
        // ✅ 完整性校验1：检查数据是否为空
        if (bytes.isEmpty) {
          Logger().logSync('Download', '切片数据为空: $url');
          continue;
        }
        
        // ✅ 完整性校验2：检查TS文件魔数（应以0x47开头）
        // TS同步字节：0x47，有效的TS文件必须以这个字节开头
        if (bytes[0] != 0x47) {
          Logger().logSync('Download', 'TS文件魔数校验失败: ${bytes[0].toRadixString(16)}, URL: $url');
          continue;
        }
        
        // ✅ 完整性校验3：检查文件最小大小（TS文件至少188字节）
        if (bytes.length < 188) {
          Logger().logSync('Download', 'TS文件过小: ${bytes.length} bytes, URL: $url');
          continue;
        }
        
        final file = File(savePath);
        await file.writeAsBytes(bytes);
        return true;
      } catch (e) {
        Logger().logSync('Download', '下载切片失败(retry ${retry + 1}): $e');
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

  /// 合并 TS 文件（带完整性校验）
  /// [downloaded] 下载状态列表，用于跳过失败的切片
  Future<bool> _mergeTsFiles(String tempDir, String outputPath, List<bool>? downloaded) async {
    final dir = Directory(tempDir);
    final files = await dir.list().toList();
    
    // 按文件名排序
    files.sort((a, b) => a.path.compareTo(b.path));
    
    final outputFile = File(outputPath);
    final sink = outputFile.openWrite();
    
    int validCount = 0;
    int skippedCount = 0;
    
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      // 如果有下载状态记录，跳过失败的切片
      if (downloaded != null && i < downloaded.length && !downloaded[i]) {
        Logger().logSync('Merge', '跳过缺失切片 ${i + 1}');
        skippedCount++;
        continue;
      }
      if (file is File) {
        try {
          final bytes = await file.readAsBytes();
          
          // ✅ 合并前再次校验文件完整性
          if (bytes.isEmpty) {
            Logger().logSync('Merge', '跳过空文件: ${file.path}');
            skippedCount++;
            continue;
          }
          if (bytes[0] != 0x47) {
            Logger().logSync('Merge', '跳过无效TS文件(魔数错误): ${file.path}');
            skippedCount++;
            continue;
          }
          
          sink.add(bytes);
          validCount++;
        } catch (e) {
          Logger().logSync('Merge', '读取文件失败: ${file.path}, $e');
          skippedCount++;
        }
      }
    }
    
    await sink.close();
    
    // ✅ 返回合并结果
    onLog?.call('合并完成: $validCount 个有效切片, 跳过 $skippedCount 个', 'info');
    return validCount > 0;
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
}
