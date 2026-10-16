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

/// 单个下载任务的控制句柄与进度回调容器。
///
/// 每个 downloadVideo 调用持有独立实例，避免并发任务之间互相串扰：
/// - [pause]/[resume]/[stop] 只影响自己的下载循环
/// - [onProgress]/[onOverallProgress] 只把进度推给自己的任务
class DownloadControl {
  bool _stopFlag = false;
  bool _pauseFlag = false;

  /// 回调
  Function(String msg, String level)? onLog;
  Function(double progress, String msg)? onProgress;
  Function(int downloaded, int total)? onOverallProgress;

  /// 本次下载已接收的字节总数（用于速度显示）
  int receivedBytes = 0;

  /// 失败原因。
  ///
  /// downloadVideo 只用 bool 返回成败，具体原因（加密流不支持、
  /// 地址解析失败……）此前只进日志，界面上一律显示笼统的「下载失败」。
  /// 把原因挂在这里，让 DownloadManager 能写进任务的 error 字段展示给用户。
  String? failureReason;

  bool get isStopped => _stopFlag;
  bool get isPaused => _pauseFlag;

  /// 暂停等待器：pause 挂起时在这里等 resume/stop 叫醒
  Completer<void>? _pauseWaiter;

  void stop() {
    _stopFlag = true;
    // 唤醒可能在暂停中挂起的下载循环，否则 stop 会一直等待
    _pauseFlag = false;
    _wakePause();
  }

  void pause() {
    _pauseFlag = true;
  }

  void resume() {
    _pauseFlag = false;
    _wakePause();
  }

  void reset() {
    _stopFlag = false;
    _pauseFlag = false;
    _wakePause();
  }

  void _wakePause() {
    final waiter = _pauseWaiter;
    _pauseWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  /// 若处于暂停状态则挂起，直到 resume()/stop() 被调用。
  /// 返回 true 表示应该终止下载（被 stop 打断），false 表示可以继续。
  Future<bool> awaitIfPaused() async {
    while (_pauseFlag && !_stopFlag) {
      final waiter = _pauseWaiter ??= Completer<void>();
      await waiter.future;
    }
    return _stopFlag;
  }
}

class CrawlerCore {
  final Dio _dio;
  String baseUrl;
  String? imgBaseUrl;
  String _siteType = "original";  // 默认 original，会自动检测
  
  /// TS切片并发下载数（可由 DownloadManager 动态设置）
  int _maxConcurrentDownloads = 32;
  set maxConcurrentDownloads(int value) => _maxConcurrentDownloads = value.clamp(1, 64);
  int get maxConcurrentDownloads => _maxConcurrentDownloads;
  
  Database? _db;
  bool _dbInitialized = false;
  
  // Debug开关：是否保存HTML到文件
  bool saveDebugHtml = false;
  
  /// 全局日志回调（各任务共用，只承载日志不承载进度）
  Function(String msg, String level)? onLog;
  
  // 外部数据库路径（用于持久化保存，卸载后不丢失）
  String? externalDbPath;

  /// 每个下载任务一份的独立控制句柄。
  ///
  /// 此前 pause/stop 与进度回调都是 CrawlerCore 上的全局单槽字段，
  /// 而 maxConcurrentTasks 默认就是 2、可上调到 5，多个任务共用同一个
  /// CrawlerCore 实例时：暂停 A 会连带暂停 B，A 的进度会写进 B 的界面，
  /// 任务结束还会把回调置 null 让仍在跑的任务停止更新。
  ///
  /// 这里用 Zone 把句柄与「发起下载的那条异步链」绑定：
  /// `runZoned` 期间在该 Zone 内创建的所有 Future/async 函数
  /// 都能通过 [control] 拿到同一份句柄，且各并发下载互不干扰。
  DownloadControl? _zoneControl;

  /// 创建一份绑定到当前异步链的控制句柄。
  ///
  /// 用法（见 downloadVideoAt）：
  /// ```dart
  /// final ctrl = createControl();
  /// await runZoned(() => downloadVideo(...), zoneValues: {_zoneKey: ctrl});
  /// ```
  DownloadControl createControl() => DownloadControl();

  static final Object _zoneKey = Object();

  /// 当前下载的控制句柄。
  ///
  /// 优先取 Zone 绑定那一份；若调用方没有用 runZoned 包裹
  /// （例如老的同步入口），退回一个全局兜底句柄，
  /// 保证任何调用路径都不会拿到 null。
  DownloadControl get control {
    final scoped = Zone.current[_zoneKey];
    if (scoped is DownloadControl) return scoped;
    return _zoneControl ??= DownloadControl();
  }

  /// 开启一次受控下载：返回该任务独占的控制句柄，
  /// 并把它绑定到当前 Zone，让下载链路上的 [control] 都取到同一份。
  DownloadControl beginDownload() {
    return DownloadControl();
  }

  /// 在绑定好 [ctrl] 的 Zone 中执行下载。
  ///
  /// 下载流程里所有 `control` 读取（暂停检查、进度上报）
  /// 都会命中这份句柄；两个并发任务各自在不同的 Zone 中运行，
  /// 因此互不可见、互不干扰。
  Future<T> runWithControl<T>(
    DownloadControl ctrl,
    Future<T> Function() body,
  ) {
    return runZoned(body, zoneValues: {_zoneKey: ctrl});
  }

  CrawlerCore({
    required this.baseUrl,
    this.imgBaseUrl,
    Dio? dio,
    this.externalDbPath,
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

  // ==================== 分页状态 ====================

  /// 最近一次列表/搜索请求后，站点是否还有下一页
  ///
  /// 由 [_detectHasNextPage] 在每次请求后更新，页面通过此 getter 读取，
  /// 取代原先 `videos.length < 20` 的猜测式判断（条数不固定时会误判，
  /// 导致无限滚动在第 1 页后就被永久关闭）。
  bool get lastRequestHasMore => _lastRequestHasMore;
  bool _lastRequestHasMore = true;

  /// 最近一次请求是否成功解析到站点分页控件
  ///
  /// false 表示走了条数兜底逻辑，调用方可据此记录日志辅助排查。
  bool get lastPaginationParsed => _lastPaginationParsed;
  bool _lastPaginationParsed = false;

  /// 从列表页 HTML 判断是否还有下一页（双重保险策略）
  ///
  /// 优先级：
  ///   1. 站点分页控件 —— 在分页区域内查找比 [currentPage] 更大的页码链接，
  ///      或未置灰的"下一页"文本。这是最可靠的依据。
  ///   2. 条数兜底 —— 解析不到分页控件时（站点改版等），退回按返回条数判断。
  ///
  /// [currentPage] 当前页码，[itemCount] 本次解析出的视频条数。
  bool _detectHasNextPage(String html, int currentPage, int itemCount) {
    // ---- 策略 1：站点分页控件 ----
    try {
      // 先在分页区域内找，避免误命中正文中的普通链接
      final blocks = CrawlerConfig.paginationBlockPattern.allMatches(html);

      for (final block in blocks) {
        final content = block.group(0)!;

        // 1a. 存在比当前页更大的页码链接（如当前 page=2，存在 page=3）
        for (final m in CrawlerConfig.paginationPageLinkPattern.allMatches(content)) {
          final n = int.tryParse(m.group(1) ?? '');
          if (n != null && n > currentPage) {
            _lastPaginationParsed = true;
            _logPagination('分页控件命中：存在第 $n 页链接（当前 $currentPage）', true);
            return true;
          }
        }

        // 1b. 存在"下一页"文本，且未被置灰
        final nextMatch = CrawlerConfig.nextPageTextPattern.firstMatch(content);
        if (nextMatch != null) {
          // 截取该文本附近的片段，判断是否带 disabled 标记
          final start = nextMatch.start > 120 ? nextMatch.start - 120 : 0;
          final end = nextMatch.end + 120 < content.length ? nextMatch.end + 120 : content.length;
          final nearby = content.substring(start, end);

          if (CrawlerConfig.paginationDisabledPattern.hasMatch(nearby)) {
            _lastPaginationParsed = true;
            _logPagination('分页控件命中："下一页"已置灰，判定为最后一页', false);
            return false;
          }
          _lastPaginationParsed = true;
          _logPagination('分页控件命中：存在可点击的"下一页"', true);
          return true;
        }
      }

      // 分页区域没有可识别的"下一页"，但整个页面存在更大页码链接时也认为有下一页
      // （部分 CMS 的分页 class 不在预设列表里）
      for (final m in CrawlerConfig.paginationPageLinkPattern.allMatches(html)) {
        final n = int.tryParse(m.group(1) ?? '');
        if (n != null && n > currentPage) {
          _lastPaginationParsed = true;
          _logPagination('整页命中：存在第 $n 页链接（当前 $currentPage）', true);
          return true;
        }
      }
    } catch (e) {
      Logger().logSync('Crawler', '分页控件解析异常，回退到条数判断: $e');
    }

    // ---- 策略 2：条数兜底 ----
    _lastPaginationParsed = false;
    final hasMore = itemCount >= CrawlerConfig.fallbackPageSize;
    _logPagination('未解析到分页控件，按条数兜底：$itemCount 条 → hasMore=$hasMore', hasMore);
    return hasMore;
  }

  void _logPagination(String msg, bool hasMore) {
    Logger().logSync('Crawler', '$msg [hasMore=$hasMore]');
  }

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
    _dio.options.headers['Cookie'] = 'language=cn_CN';
    Logger().logSync('Crawler', '设置语言 Cookie: language=cn_CN (domain=${Uri.parse(baseUrl).host})');
  }

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
        dbPath = '${dbDir.path}/download_history.db';
        Logger().logSync('Crawler', '使用外部数据库路径: $dbPath');
      } else {
        // 使用应用私有路径（默认行为）
        dbPath = '${await getDatabasesPath()}/download_history.db';
      }
      _db = await openDatabase(
        dbPath,
        onCreate: (db, version) {
          return db.execute('''
            CREATE TABLE IF NOT EXISTS download_history (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              video_id TEXT UNIQUE,
              title TEXT,
              url TEXT,
              file_path TEXT,
              cover TEXT,
              author TEXT,
              duration TEXT,
              upload_date TEXT,
              download_time TEXT,
              file_exists INTEGER DEFAULT 1
            )
          ''');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          // 历史表原先只存 id/标题/url/路径，恢复已完成任务时
          // 界面却要渲染封面与作者，于是重启后一片灰块、作者空白。
          // v2 把封面/作者/时长一并落盘。
          if (oldVersion < 2) {
            final existing = await db.rawQuery('PRAGMA table_info(download_history)');
            final names = existing.map((r) => r['name']).toSet();
            for (final col in ['cover', 'author', 'duration']) {
              if (!names.contains(col)) {
                await db.execute('ALTER TABLE download_history ADD COLUMN $col TEXT');
              }
            }
          }
        },
        version: 2,
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
    // original 站点对 _t 参数敏感（首页/搜索带 _t 会 404），仅 porn91 保留 _t 防缓存
    final urlWithCache = _siteType == "porn91"
        ? (url.contains('?') ? '$url&_t=$ts' : '$url?_t=$ts')
        : url;
    
    // ✅ 修复：日志记录实际请求的 URL
    await logger.log('Crawler', '网络请求: GET $urlWithCache (siteType=$_siteType)');
    
    try {
      String html;
      
      // ✅ 关键修复：porn91 需要 GET + POST 两步请求
      // Python版本逻辑：先GET获取初始cookie，再POST提交session_language=cn_CN
      if (_siteType == "porn91") {
        try {
          // 步骤1：GET 请求获取初始 cookie
          await logger.log('Crawler', 'porn91: 先 GET 请求获取初始 cookie...');
          final getResp = await _dio.get(urlWithCache, options: _noCacheOptions);
          
          // 从GET响应中提取Set-Cookie（Dio的headers key是小写的）
          final setCookies = getResp.headers['set-cookie'] ?? getResp.headers['Set-Cookie'];
          String cookies = 'language=cn_CN';
          if (setCookies != null && setCookies.isNotEmpty) {
            for (final cookie in setCookies) {
              final match = RegExp(r'^([^=]+=[^;]+)').firstMatch(cookie);
              if (match != null) {
                final cookieValue = match.group(1)!;
                if (!cookies.contains(cookieValue.split('=')[0] + '=')) {
                  cookies += '; $cookieValue';
                }
              }
            }
            await logger.log('Crawler', 'porn91: 提取到 cookies: $cookies');
          }
          
          // 保存 Cookie 到全局
          _dio.options.headers['Cookie'] = cookies;
          
          // 步骤2：POST 提交语言设置
          await logger.log('Crawler', 'porn91: POST 提交语言设置 session_language=cn_CN');
          await logger.log('Crawler', 'porn91: POST URL=$urlWithCache');
          final postResp = await _dio.post(
            urlWithCache,
            data: 'session_language=cn_CN',
            options: Options(
              headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
                'Cookie': cookies,
                'Referer': urlWithCache,
                'Origin': baseUrl,
                'Cache-Control': 'no-cache, no-store, must-revalidate',
                'Pragma': 'no-cache',
              },
              extra: {'cache': false},
              validateStatus: (status) => status != null && status < 500,
            ),
          );
          html = postResp.data.toString();
          await logger.log('Crawler', 'porn91: POST 响应状态=${postResp.statusCode}, 长度 ${html.length} 字节');
        } catch (e) {
          await logger.log('Crawler', 'porn91 POST 失败，回退到 GET 结果: $e');
          // 如果 POST 失败（如网络错误、服务器拒绝），尝试直接使用 GET 获取 HTML
          try {
            final fallbackResp = await _dio.get(urlWithCache, options: _noCacheOptions);
            html = fallbackResp.data.toString();
            await logger.log('Crawler', 'porn91 GET 回退成功，长度 ${html.length} 字节');
          } catch (e2) {
            await logger.log('Crawler', 'porn91 GET 回退也失败: $e2');
            rethrow;
          }
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

      // 依据站点分页控件判断是否还有下一页（取代条数猜测）
      _lastRequestHasMore = _detectHasNextPage(html, page, videos.length);

      return videos;
      
    } catch (e) {
      await logger.log('Crawler', '获取视频列表失败: $e (URL=$urlWithCache)');
      _lastPaginationParsed = false;
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
      
      // 格式3: 作者：xxx（直接文本，跳过HTML标签）
      if (author == null || author.isEmpty) {
        final textMatch = RegExp(r'作者[：:]\s*(?:</?[^>]+>\s*)*([^<\n\r]+)').firstMatch(wellContent);
        if (textMatch != null) {
          author = textMatch.group(1)?.trim();
        }
      }
      
      // 清理作者名（去掉HTML标签和特殊字符）
      if (author != null) {
        // ✅ 修复：先剥离HTML标签，防止 </span> 等标签残留
        author = author.replaceAll(CrawlerConfig.htmlTagPattern, '');
        author = author.replaceAll('&nbsp;', '');
        author = author.replaceAll(CrawlerConfig.htmlEntityPattern, '');
        author = author.replaceAll(CrawlerConfig.whitespacePattern, ' ').trim();
        if (author.isEmpty) author = null;
      }
      
      // 提取时长
      String? duration;
      final durationMatch = CrawlerConfig.durationPattern.firstMatch(wellContent);
      if (durationMatch != null) {
        duration = durationMatch.group(1)!.trim();
      }
      
      // 提取上传时间（多种格式：绝对日期 + 相对时间）
      String? uploadDate;
      // 格式1: <span class="added-time">2024-01-15</span> 或 <span class="added-time">3天前</span>
      var dateMatch = RegExp(r'<span[^>]*class="[^"]*added[^"]*"[^>]*>([^<]+)</span>', caseSensitive: false).firstMatch(wellContent);
      if (dateMatch != null) {
        uploadDate = dateMatch.group(1)!.trim();
      }
      // 格式2: 添加/上传/更新 时间标签（中文）
      if (uploadDate == null || uploadDate!.isEmpty) {
        dateMatch = RegExp(r'(?:添加|上传|更新)[时日期\s]*[：:]\s*(.+?)(?:<|\s*$)', caseSensitive: false).firstMatch(wellContent);
        if (dateMatch != null) {
          uploadDate = dateMatch.group(1)!.trim();
        }
      }
      // 格式3: 相对时间（X天前 / X小时前 / X分钟前 / 刚刚）
      // 支持 "43 分钟 前"（带空格）和 "33分钟前"（无空格）两种格式
      if (uploadDate == null || uploadDate!.isEmpty) {
        dateMatch = RegExp(r'(\d+\s*[天时分秒钟小时月周]+\s*前|刚刚|刚才)', caseSensitive: false).firstMatch(wellContent);
        if (dateMatch != null) {
          uploadDate = dateMatch.group(1)!.trim();
        }
      }
      // 格式4: 绝对日期 YYYY-MM-DD 或 YYYY/MM/DD
      if (uploadDate == null || uploadDate!.isEmpty) {
        dateMatch = RegExp(r'(\d{4}[-/]\d{1,2}[-/]\d{1,2})').firstMatch(wellContent);
        if (dateMatch != null) {
          uploadDate = dateMatch.group(1)!.trim();
        }
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
        uploadDate: uploadDate,
      ));
    }
    
    Logger().logSync('Parse', '解析完成: ${videos.length} 个视频');
    
    return videos;
  }
  
  /// ✅ 新增：平衡 div 计数法提取指定 class 的 div 完整内容
  /// 解决正则懒惰匹配无法正确捕获嵌套 div 完整内容的问题
  static List<String> _extractBalancedDivContents(String html, String className) {
    final results = <String>[];
    final openPattern = RegExp(
      '<div[^>]*class="[^"]*$className[^"]*"[^>]*>',
      caseSensitive: false,
    );
    
    // 小写副本只算一次。以前写在 for 循环体内，匹配到 N 个区块就把
    // 整篇 HTML（几百 KB）重复小写化 N 次 —— 一次列表解析里这是最贵的开销。
    final lowerHtml = html.toLowerCase();

    for (final openMatch in openPattern.allMatches(html)) {
      int start = openMatch.end;
      int depth = 1;
      int pos = start;
      
      while (pos < lowerHtml.length && depth > 0) {
        final nextOpen = lowerHtml.indexOf('<div', pos);
        final nextClose = lowerHtml.indexOf('</div>', pos);
        
        if (nextClose == -1) break;
        
        if (nextOpen != -1 && nextOpen < nextClose) {
          // 确认是真正的 div 开标签（后面跟空格或 >）
          final charAfter = nextOpen + 4 < html.length ? html[nextOpen + 4] : '';
          if (charAfter == ' ' || charAfter == '>' || charAfter == '\n' || charAfter == '\r') {
            depth++;
          }
          pos = nextOpen + 1;
        } else {
          depth--;
          if (depth == 0) {
            results.add(html.substring(start, nextClose));
          }
          pos = nextClose + 6;
        }
      }
    }
    return results;
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
    // ✅ 修复：使用平衡 div 计数法替代正则，确保完整捕获包括 info 区域
    final containers = _extractBalancedDivContents(html, 'thumbnail');
    
    for (final container in containers) {
      
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
        author = authorMatch.group(2)?.replaceAll('&nbsp;', '').replaceAll(CrawlerConfig.htmlEntityPattern, '').trim();
      }
      
      // 格式2: 纯文本作者 作者：xxx（跳过HTML标签）
      if (author == null || author.isEmpty) {
        final textMatch = RegExp(r'作者[：:]\s*(?:</?[^>]+>\s*)*([^<\n\r]+)').firstMatch(container);
        if (textMatch != null) {
          author = textMatch.group(1)?.trim();
        }
      }
      
      // 清理作者名
      if (author != null) {
        // ✅ 修复：先剥离HTML标签，防止标签残留
        author = author.replaceAll(CrawlerConfig.htmlTagPattern, '');
        author = author.replaceAll(CrawlerConfig.whitespacePattern, ' ').trim();
        if (author.isEmpty) author = null;
      }
      
      // 提取上传时间（多种格式：绝对日期 + 相对时间）
      String? uploadDate;
      // 格式1: <span class="added-time">2024-01-15</span> 或 <span class="added-time">3天前</span>
      var dateMatch = RegExp(r'<span[^>]*class="[^"]*added[^"]*"[^>]*>([^<]+)</span>', caseSensitive: false).firstMatch(container);
      if (dateMatch != null) {
        uploadDate = dateMatch.group(1)!.trim();
      }
      // 格式2: 添加/上传/更新 时间标签（中文）
      if (uploadDate == null || uploadDate!.isEmpty) {
        dateMatch = RegExp(r'(?:添加|上传|更新)[时日期\s]*[：:]\s*(.+?)(?:<|\s*$)', caseSensitive: false).firstMatch(container);
        if (dateMatch != null) {
          uploadDate = dateMatch.group(1)!.trim();
        }
      }
      // 格式3: 相对时间（X天前 / X小时前 / X分钟前 / 刚刚）
      // 支持 "43 分钟 前"（带空格）和 "33分钟前"（无空格）两种格式
      if (uploadDate == null || uploadDate!.isEmpty) {
        dateMatch = RegExp(r'(\d+\s*[天时分秒钟小时月周]+\s*前|刚刚|刚才)', caseSensitive: false).firstMatch(container);
        if (dateMatch != null) {
          uploadDate = dateMatch.group(1)!.trim();
        }
      }
      // 格式4: 绝对日期 YYYY-MM-DD 或 YYYY/MM/DD
      if (uploadDate == null || uploadDate!.isEmpty) {
        dateMatch = RegExp(r'(\d{4}[-/]\d{1,2}[-/]\d{1,2})').firstMatch(container);
        if (dateMatch != null) {
          uploadDate = dateMatch.group(1)!.trim();
        }
      }
      
      // 从封面URL提取封面ID
      String? coverId;
      final coverIdMatch = RegExp(r'/(\d+)\.(webp|jpg|png)').firstMatch(cover ?? '');
      if (coverIdMatch != null) {
        coverId = coverIdMatch.group(1);
      }
      
      // 详细日志
      Logger().logSync('Parse', '视频#${videos.length + 1}: ID=$videoId, 封面ID=$coverId, 作者=$author, 作者ID=$authorId, 时长=$duration, 更新时间=$uploadDate, 标题=${title.length > 20 ? title.substring(0, 20) + "..." : title}');
      
      videos.add(VideoInfo(
        id: videoId,
        url: '$baseUrl/$videoHref',
        title: title,
        cover: cover,
        author: author,
        authorId: authorId,
        duration: duration,
        uploadDate: uploadDate,
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
    
    // ✅ 修复：搜索URL不再追加 _t 时间戳参数
    // 实测发现：部分站点（如 91lol.im / 好色Tv）中，`&_t=` 与 `&sort=` 同时出现时返回 404，
    // 单独带任何一个都正常。防缓存已有 _noCacheOptions（Cache-Control 头 + Dio extra cache:false）兜底，
    // 因此搜索请求直接使用 buildSearchUrl 生成的 URL，不再拼接 _t（防止后人改回去）。
    final urlWithCache = url;
    
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

      // 依据站点分页控件判断是否还有下一页（取代条数猜测）
      _lastRequestHasMore = _detectHasNextPage(html, page, videos.length);

      return videos;
    } catch (e) {
      await logger.log('Crawler', '搜索失败: $e (URL=$urlWithCache)');
      // 请求失败时不武断关闭无限滚动，保留上一次的判断
      _lastPaginationParsed = false;
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
    
    // ✅ 修复：搜索URL不再追加 _t 时间戳参数（与 searchVideos 保持一致）
    // 作者搜索 URL 同样是 search.htm，`&_t=` 与 `&sort=` 组合可能触发站点 404，
    // 防缓存已有 _noCacheOptions 兜底，因此不拼接 _t。
    final urlWithCache = url;
    
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
    // original 站点对 _t 参数敏感（首页/搜索带 _t 会 404），仅 porn91 保留 _t 防缓存
    final urlWithCache = _siteType == "porn91"
        ? (url.contains('?') ? '$url&_t=$ts' : '$url?_t=$ts')
        : url;
    
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

      // 依据站点分页控件判断是否还有下一页（取代条数猜测）
      _lastRequestHasMore = _detectHasNextPage(html, page, videos.length);

      return videos;
    } catch (e) {
      await logger.log('Crawler', '获取作者视频失败: $e (URL=$urlWithCache)');
      _lastPaginationParsed = false;
      return [];
    }
  }

  // ==================== 获取视频详情 ====================

  /// 获取视频详情（m3u8地址等）
  Future<VideoInfo?> getVideoDetail(VideoInfo video) async {
    try {
      // ✅ 修复：使用更轻量的参数格式
      final ts = DateTime.now().millisecondsSinceEpoch;
      // original 站点对 _t 参数敏感（首页/搜索带 _t 会 404），仅 porn91 保留 _t 防缓存
      final urlWithCache = _siteType == "porn91"
          ? (video.url.contains('?') ? '${video.url}&_t=$ts' : '${video.url}?_t=$ts')
          : video.url;
      
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
        
        // 提取上传日期 + 观看数（播放页可见，供在线播放页展示）
        String? uploadDate = video.uploadDate;
        if (uploadDate == null) {
          final dateMatch = RegExp(r'日期[：:]\s*(.+?)</div>').firstMatch(html);
          if (dateMatch != null) {
            uploadDate = dateMatch.group(1)!.trim();
          }
        }
        String? views = video.views;
        if (views == null) {
          final viewMatch = RegExp(r'观看[：:]\s*(\d+)').firstMatch(html);
          if (viewMatch != null) {
            views = viewMatch.group(1)!.trim();
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
          uploadDate: uploadDate,
          views: views,
          m3u8Url: videoUrl,
        );
      }
      
      return null;
    } catch (e, stack) {
      // 以前这里直接 `return null`，异常和堆栈全丢。
      // 结果是「解析失败」和「页面确实没有视频」在调用方看来完全一样，
      // 用户只能看到一句模糊的失败提示，日志里也查不到任何线索。
      lastDetailError = e.toString();
      await logger.log('Error', '解析视频详情失败 (${video.id}): $e');
      await logger.log('Error', '$stack');
      return null;
    }
  }

  /// 最近一次 [getVideoDetail] 失败的原因，供 UI 展示更具体的提示。
  String? lastDetailError;

  // ==================== 下载 ====================

  /// 下载视频
  Future<bool> downloadVideo(VideoInfo video, String savePath) async {
    // 本次下载独占的控制句柄：暂停/停止/进度回调都挂在它上面，
    // 避免与并发的其它任务互相干扰。
    final ctrl = beginDownload();
    return runWithControl(ctrl, () => _downloadVideoInner(video, savePath, ctrl));
  }

  Future<bool> _downloadVideoInner(
      VideoInfo video, String savePath, DownloadControl ctrl) async {
    if (video.m3u8Url == null) {
      // 先获取 m3u8 地址
      final detail = await getVideoDetail(video);
      if (detail == null || detail.m3u8Url == null) {
        ctrl.onLog?.call('获取视频地址失败', 'error');
        ctrl.failureReason = '获取视频地址失败，可能是站点改版或该视频已下架';
        return false;
      }
      video = detail;
    }
    
    var videoUrl = video.m3u8Url!;
    
    // 检查是否是直接 MP4 链接（porn91 等站点使用）
    final isDirectMp4 = videoUrl.endsWith('.mp4') || videoUrl.contains('.mp4?');
    
    if (isDirectMp4) {
      // 直接下载 MP4 文件
      return await _downloadDirectMp4(video, videoUrl, savePath, ctrl);
    }
    
    ctrl.onLog?.call('开始下载: ${video.title}', 'info');
    
    
    try {
      // 下载 m3u8 文件（禁用缓存）
      final m3u8Resp = await _dio.get(videoUrl, options: _noCacheOptions);
      final m3u8Content = m3u8Resp.data.toString();
      
      // 解析 TS 切片列表
      // 加密流必须在动手下载前拦住：不做解密的拼接结果一定是坏文件，
      // 而失败要趁早，不能让用户等下载完才发现播不了。
      if (_isEncryptedM3u8(m3u8Content)) {
        ctrl.onLog?.call('该视频受加密保护（AES-128），暂不支持下载', 'error');
        ctrl.failureReason = '该视频受加密保护，暂不支持下载';
        return false;
      }

      final tsUrls = _parseM3u8(m3u8Content, videoUrl);
      if (tsUrls.isEmpty) {
        ctrl.onLog?.call('解析 TS 列表失败', 'error');
        ctrl.failureReason = '解析视频地址失败，可能是站点改版';
        return false;
      }
      
      ctrl.onLog?.call('共 ${tsUrls.length} 个切片', 'info');
      
      // 创建临时目录
      final tempDir = Directory('${savePath}_temp');
      if (!await tempDir.exists()) {
        await tempDir.create(recursive: true);
      }
      
      // 记录下载状态：true=成功，false=失败
      final downloaded = List<bool>.filled(tsUrls.length, false);
      
      // ─── 进度上报 ───
      // 进度以「已完成切片数」为唯一口径，且对外单调递增，
      // 避免并发乱序 / 重试阶段导致进度条回跳（抽动）。
      final total = tsUrls.length;
      int finished = 0;            // 已处理完的切片数（成功或失败），只增不减
      double lastReported = 0.0;   // 最近一次上报的进度值
      DateTime? lastProgressUpdate;
      const progressThrottleMs = 200;  // 最小间隔，避免过于频繁刷新UI

      void reportProgress(String msg, {bool force = false}) {
        final value = finished / total;
        if (!force && value < lastReported) return;   // 永不后退
        final now = DateTime.now();
        final due = lastProgressUpdate == null ||
            now.difference(lastProgressUpdate!).inMilliseconds >= progressThrottleMs;
        if (!force && !due) return;
        lastReported = value > lastReported ? value : lastReported;
        lastProgressUpdate = now;
        ctrl.onProgress?.call(lastReported, msg);
      }

      // ─── 断点续传：统计已缓存的切片 ───
      // 上次失败时保留了临时目录，这里先探一遍有多少切片可直接复用，
      // 让用户知道这次不用从头下载。
      int cachedSegments = 0;
      try {
        for (var i = 0; i < total; i++) {
          final f = File('${tempDir.path}/seg_${i.toString().padLeft(5, '0')}.ts');
          if (await f.exists() && await f.length() >= 188) {
            cachedSegments++;
          }
        }
      } catch (_) {
        cachedSegments = 0;
      }
      if (cachedSegments > 0) {
        ctrl.onLog?.call('检测到 $cachedSegments/$total 个已下载切片，将续传',
            'info');
      }

      // ─── 滑动窗口并发 ───
      // 每完成一个切片立即补发下一个，始终保持 N 个在途。
      // 旧实现按批处理（凑满一批再一起 await），会被批内最慢的切片拖住，
      // 导致并发数调大后实际收益远低于预期。
      //
      // 实现说明：_downloadTs 自带重试且始终返回 bool，不会抛出，
      // 因此这里无需担心未处理的 Future 错误。
      // 用「未消费的完成信号计数 + 等待者队列」实现，信号不会丢失。
      var unconsumed = 0;
      final waiters = <Completer<void>>[];

      void signalDone() {
        if (waiters.isNotEmpty) {
          waiters.removeAt(0).complete();
        } else {
          unconsumed++;   // 没有等待者，先记账，稍后被消费
        }
      }

      /// 等待「任意一个」在途任务完成
      Future<void> waitAny() {
        if (unconsumed > 0) {
          unconsumed--;
          return Future.value();
        }
        final c = Completer<void>();
        waiters.add(c);
        return c.future;
      }

      Future<void> runOne(int i) async {
        final tsUrl = tsUrls[i];
        final tsPath = '${tempDir.path}/seg_${i.toString().padLeft(5, '0')}.ts';
        final ok = await _downloadTs(tsUrl, tsPath, ctrl);
        downloaded[i] = ok;        finished++;
        reportProgress('下载中 $finished/$total');
        signalDone();
      }

      var nextIndex = 0;
      var inFlight = 0;
      var paused = false;

      // 初始填满窗口
      while (inFlight < _maxConcurrentDownloads && nextIndex < total) {
        unawaited(runOne(nextIndex));
        nextIndex++;
        inFlight++;
      }

      // 每完成一个就补发下一个，始终保持窗口满载
      while (inFlight > 0) {
        if (ctrl.isStopped) break;
        await waitAny();
        inFlight--;
        if (ctrl.isStopped) break;
        // 暂停时不再派发新切片，等在途切片收尾后挂起
        if (await ctrl.awaitIfPaused()) {
          paused = true;
          break;
        }
        if (nextIndex < total) {
          unawaited(runOne(nextIndex));
          nextIndex++;
          inFlight++;
        }
      }

      // 收尾：等在途任务全部结束（暂停/停止时同样要收尾，避免半截写入）
      while (inFlight > 0) {
        await waitAny();
        inFlight--;
      }

      // ✅ 下载完成后强制上报一次最终进度
      reportProgress(
        paused ? '已暂停 $finished/$total' : '下载中 $finished/$total',
        force: true,
      );

      if (paused) {
        final doneCount = downloaded.where((d) => d).length;
        ctrl.onLog?.call('已暂停，保留 $doneCount 个已下载切片，恢复后可续传', 'info');
        return false;
      }
      
      if (ctrl.isStopped) {
        ctrl.onLog?.call('下载已停止', 'warn');
        return false;
      }
      
      // ✅ 重试失败的切片（最多3轮）
      var failedIndices = <int>[];
      for (var i = 0; i < downloaded.length; i++) {
        if (!downloaded[i]) {
          failedIndices.add(i);
        }
      }
      
      for (var retryRound = 1; retryRound <= 3 && failedIndices.isNotEmpty; retryRound++) {
        ctrl.onLog?.call('重试第 $retryRound 轮，${failedIndices.length} 个切片失败', 'warn');
        
        final stillFailed = <int>[];
        // 重试同样使用滑动窗口（同上，用未消费计数避免丢信号）
        var retryUnconsumed = 0;
        final retryWaiters = <Completer<void>>[];

        void signalRetryDone() {
          if (retryWaiters.isNotEmpty) {
            retryWaiters.removeAt(0).complete();
          } else {
            retryUnconsumed++;
          }
        }

        Future<void> waitRetryAny() {
          if (retryUnconsumed > 0) {
            retryUnconsumed--;
            return Future.value();
          }
          final c = Completer<void>();
          retryWaiters.add(c);
          return c.future;
        }

        Future<void> runRetry(int idx) async {
          final tsUrl = tsUrls[idx];
          final tsPath = '${tempDir.path}/seg_${idx.toString().padLeft(5, '0')}.ts';
          final ok = await _downloadTs(tsUrl, tsPath, ctrl);
          if (ok) {
            downloaded[idx] = true;
            // 重试成功也计入进度；reportProgress 内部保证不后退
            finished++;
            reportProgress('重试中 $finished/$total');
          } else {
            stillFailed.add(idx);
          }
          signalRetryDone();
        }

        var retryCursor = 0;
        var retryInFlight = 0;

        while (retryInFlight < _maxConcurrentDownloads &&
            retryCursor < failedIndices.length) {
          unawaited(runRetry(failedIndices[retryCursor]));
          retryCursor++;
          retryInFlight++;
        }

        while (retryInFlight > 0) {
          if (ctrl.isStopped) break;
          await waitRetryAny();
          retryInFlight--;
          if (ctrl.isStopped) break;
          // 暂停时停止派发重试切片
          if (await ctrl.awaitIfPaused()) {
            paused = true;
            break;
          }
          if (retryCursor < failedIndices.length) {
            unawaited(runRetry(failedIndices[retryCursor]));
            retryCursor++;
            retryInFlight++;
          }
        }

        // 收尾
        while (retryInFlight > 0) {
          await waitRetryAny();
          retryInFlight--;
        }

        failedIndices = stillFailed;
        
        if (paused) {
          final doneCount = downloaded.where((d) => d).length;
          ctrl.onLog?.call('已暂停，保留 $doneCount 个已下载切片，恢复后可续传', 'info');
          return false;
        }

        if (ctrl.isStopped) {
          ctrl.onLog?.call('下载已停止', 'warn');
          return false;
        }
      }
      
      // ✅ 严格失败处理：只要有切片失败，就不合并，直接标记失败
      // 避免生成有缺损的视频文件导致播放异常
      final successCount = downloaded.where((d) => d).length;
      
      if (failedIndices.isNotEmpty) {
        final failedSegNums = failedIndices.map((i) => '#${i + 1}').take(10).join(', ');
        final failedSummary = failedIndices.length <= 10 
            ? failedSegNums 
            : '$failedSegNums ... 共${failedIndices.length}个';
        ctrl.onLog?.call('下载失败：${failedIndices.length} 个切片无法下载（$successCount/${tsUrls.length}），失败切片: $failedSummary', 'error');
        ctrl.failureReason = '${failedIndices.length} 个切片下载失败（已成功 $successCount/${tsUrls.length}），可重试续传';
        // 断点续传：保留临时目录，下次下载会跳过已成功的切片
        ctrl.onLog?.call('已保留 $successCount 个已下载切片，重试时可续传', 'info');
        return false;
      }
      
      // 合并 TS 文件（带完整性校验）
      ctrl.onLog?.call('合并文件...', 'info');
      final mergeOk = await _mergeTsFiles(tempDir.path, savePath, downloaded, ctrl);
      if (!mergeOk) {
        ctrl.onLog?.call('合并失败：没有有效的切片文件', 'error');
        await tempDir.delete(recursive: true);
        ctrl.failureReason = '合并失败：没有有效的切片文件';
        return false;
      }
      
      // 清理临时文件
      await tempDir.delete(recursive: true);
      
      // 保存到数据库
      await _saveToHistory(video, savePath);
      
      ctrl.onLog?.call('下载完成: ${video.title}', 'info');
      return true;
      
    } catch (e) {
      ctrl.onLog?.call('下载失败: $e', 'error');
      ctrl.failureReason = '下载失败: $e';
      // 断点续传：异常时同样保留已下载的切片，便于重试续传。
      // 仅在明确不再重试（用户删除任务）时才清理，见 _cleanupTempDir。
      ctrl.onLog?.call('已保留临时文件，重试时可续传', 'info');
      return false;
    }
  }

  /// 检测 M3U8 是否声明了加密（`#EXT-X-KEY`）。
  ///
  /// 本 App 不做分片解密，而 `_parseM3u8` 会跳过所有 `#` 开头的行，
  /// 于是加密流会被当成明文下载：分片按密文落盘、直接拼接，
  /// 结果进度 100%、界面显示「下载完成」，点开却是黑屏/花屏。
  /// 静默产出垃圾文件是最坏的一种失败，因此这里必须在开始下载前拦住。
  ///
  /// `METHOD=NONE` 表示未加密，不算。
  static bool _isEncryptedM3u8(String content) {
    for (final rawLine in content.split('\n')) {
      final line = rawLine.trim();
      if (!line.startsWith('#EXT-X-KEY')) continue;
      final upper = line.toUpperCase();
      if (upper.contains('METHOD=NONE')) continue;
      if (upper.contains('METHOD=AES-128') ||
          upper.contains('METHOD=SAMPLE-AES') ||
          upper.contains('METHOD=')) {
        return true;
      }
    }
    return false;
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
  ///
  /// 断点续传：如果目标文件已存在且通过校验，直接复用，不再重新下载。
  /// 切片按索引命名（seg_00042.ts），因此重试时能精确对应到同一切片。
  Future<bool> _downloadTs(String url, String savePath, DownloadControl ctrl) async {
    // ── 续传检查：已存在且合法的切片直接复用 ──
    try {
      final existing = File(savePath);
      if (await existing.exists()) {
        final len = await existing.length();
        if (len >= 188) {
          // 抽检首字节：解密后的 TS 必须以 0x47 同步字节开头
          final raf = await existing.open();
          final head = await raf.readByte();
          await raf.close();
          if (head == 0x47) {
            ctrl.receivedBytes += len;
            return true;
          }
        }
        // 文件不合法（残缺/非 TS），删掉重新下载
        await existing.delete();
      }
    } catch (_) {
      // 检查失败时按"未缓存"处理，正常走下载流程
    }

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
        
        // 校验通过后才计入字节统计：此前在验证之前累加，
        // 导致坏切片/重试的字节也被算进速度，显示值虚高
        ctrl.receivedBytes += bytes.length;
        ctrl.onOverallProgress?.call(ctrl.receivedBytes, 0);
        
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
  Future<bool> _downloadDirectMp4(
      VideoInfo video, String mp4Url, String savePath,
      DownloadControl ctrl) async {
    ctrl.onLog?.call('开始下载 MP4: ${video.title}', 'info');
    ctrl.onLog?.call('MP4 URL: $mp4Url', 'debug');

    // 直链下载同样需要把字节数上报给 onOverallProgress，
    // 否则 DownloadTask 拿不到速度（downloadSpeed 恒为 0 → 界面不显示速度）。
    // TS 切片路径在收到每个切片时上报，这里在 onReceiveProgress 里上报。
    DateTime? lastSpeedReport;
    const speedReportIntervalMs = 300;  // 节流，避免高频刷新界面

    void reportBytes(int received, int total) {
      final now = DateTime.now();
      final due = lastSpeedReport == null ||
          now.difference(lastSpeedReport!).inMilliseconds >= speedReportIntervalMs;
      if (!due) return;
      lastSpeedReport = now;
      ctrl.receivedBytes = received;
      ctrl.onOverallProgress?.call(received, total);
    }

    final partFile = File('$savePath.part');
    try {
      // 获取文件大小
      final headResp = await _dio.head(mp4Url);
      final contentLength = int.tryParse(headResp.headers.value('content-length') ?? '0') ?? 0;
      
      if (contentLength > 0) {
        ctrl.onLog?.call('文件大小: ${(contentLength / 1024 / 1024).toStringAsFixed(2)} MB', 'info');
      }

      // ── 断点续传 ──
      // 直链此前用 _dio.download 一次拉完，无 Range 头、失败也不清半成品：
      // 大文件重试要从 0 开始白下，目录里还会留下看似正常、实际播到一半就断的 mp4。
      // 改为先下到 .part，带上 Range 头续传，成功后原子改名到最终路径。
      int alreadyBytes = 0;
      if (await partFile.exists()) {
        final len = await partFile.length();
        if (contentLength > 0 && len >= contentLength) {
          // 上次其实已经下完，只是没改名
          await partFile.rename(savePath);
          await _saveToHistory(video, savePath);
          ctrl.onLog?.call('检测到已完成的临时文件，直接使用', 'info');
          return true;
        }
        if (contentLength <= 0 || len < contentLength) {
          alreadyBytes = len;
          if (alreadyBytes > 0) {
            ctrl.onLog?.call(
                '断点续传：已下载 ${(alreadyBytes / 1024 / 1024).toStringAsFixed(1)} MB',
                'info');
          }
        }
      }

      final totalBytes = contentLength > 0 ? contentLength : 0;

      await _dio.download(
        mp4Url,
        partFile.path,
        options: Options(
          headers: alreadyBytes > 0 ? {'Range': 'bytes=$alreadyBytes-'} : null,
        ),
        deleteOnError: false,
        onReceiveProgress: (received, total) {
          // 续传时 received 是本次的字节数，加上已存部分才是整体进度
          final overall = alreadyBytes + received;
          reportBytes(overall, totalBytes > 0 ? totalBytes : total);

          final denom = totalBytes > 0 ? totalBytes : (total > 0 ? total : 0);
          if (denom > 0) {
            final progress = (overall / denom).clamp(0.0, 1.0);
            final downloadedMB = (overall / 1024 / 1024).toStringAsFixed(1);
            final totalMB = (denom / 1024 / 1024).toStringAsFixed(1);
            ctrl.onProgress?.call(progress, '$downloadedMB/$totalMB MB');
          }
        },
      );

      // 下载完成：原子改名到最终路径
      if (await partFile.exists()) {
        await partFile.rename(savePath);
      }
      
      // 保存到历史记录
      await _saveToHistory(video, savePath);
      
      ctrl.onLog?.call('下载完成: ${video.title}', 'info');
      return true;
      
    } catch (e) {
      // 保留 .part 供下次续传；只有明确被停止时才清掉
      if (ctrl.isStopped && await partFile.exists()) {
        try {
          await partFile.delete();
        } catch (_) {}
      }
      ctrl.onLog?.call('下载失败: $e', 'error');
      ctrl.failureReason = '下载失败: $e';
      return false;
    }
  }

  /// 合并 TS 文件（带完整性校验）
  /// [downloaded] 下载状态列表，用于跳过失败的切片
  Future<bool> _mergeTsFiles(String tempDir, String outputPath,
      List<bool>? downloaded, [DownloadControl? ctrl]) async {
    final dir = Directory(tempDir);
    final files = await dir.list().toList();

    // ── 关键：按下标定位切片，而不是按目录列表位置 ──
    // 旧实现用 dir.list() 的下标去查 downloaded[i]，只要 _temp 里
    // 存在任何非 seg_<n>.ts 的残留文件或分片缺口，后面每个下标都会错位，
    // 于是把失败切片的标记套到错误的文件上，合并出内容错乱却在界面上
    // 显示「下载完成」的视频。
    final segPattern = RegExp(r'seg_(\d+)\.ts$');
    final indexed = <MapEntry<int, File>>[];
    for (final f in files) {
      if (f is! File) continue;
      final m = segPattern.firstMatch(f.path);
      if (m == null) {
        Logger().logSync('Merge', '跳过非切片文件: ${f.path}');
        continue;
      }
      final n = int.tryParse(m.group(1)!);
      if (n == null) continue;
      indexed.add(MapEntry(n, f));
    }
    indexed.sort((a, b) => a.key.compareTo(b.key));

    final outputFile = File(outputPath);
    // 用 try/finally 保证异常路径下 sink 也会关闭，避免半截文件与句柄泄漏
    final sink = outputFile.openWrite();
    int validCount = 0;
    int skippedCount = 0;

    try {
      for (final entry in indexed) {
        final segIndex = entry.key;
        final file = entry.value;

        // 按切片序号查下载状态
        if (downloaded != null) {
          if (segIndex >= downloaded.length) {
            Logger().logSync('Merge', '跳过越界切片 seg_$segIndex');
            skippedCount++;
            continue;
          }
          if (!downloaded[segIndex]) {
            Logger().logSync('Merge', '跳过缺失切片 ${segIndex + 1}');
            skippedCount++;
            continue;
          }
        }

        try {
          // ── 流式拷贝 ──
          // 旧实现对每个切片 readAsBytes() 全量读入再 sink.add，
          // 一个 1GB 的片子会产生同等量级的内存峰值，合并阶段被 OOM 杀掉，
          // 而分片其实都已经下完了。改为边读边写，内存占用与文件大小无关。
          int written = 0;
          int firstByte = -1;
          await for (final chunk in file.openRead()) {
            if (firstByte < 0) firstByte = chunk.isEmpty ? -1 : chunk[0];
            if (written == 0 && chunk.isEmpty) continue;
            sink.add(chunk);
            written += chunk.length;
          }

          if (written == 0) {
            Logger().logSync('Merge', '跳过空文件: ${file.path}');
            skippedCount++;
            continue;
          }
          // 合并前再校验一次 TS 同步字节（0x47）
          if (firstByte != 0x47) {
            Logger().logSync('Merge', '跳过无效TS文件(魔数错误): ${file.path}');
            skippedCount++;
            continue;
          }

          validCount++;
        } catch (e) {
          Logger().logSync('Merge', '读取文件失败: ${file.path}, $e');
          skippedCount++;
        }
      }
    } finally {
      await sink.close();
    }

    // ✅ 返回合并结果
    ctrl?.onLog?.call('合并完成: $validCount 个有效切片, 跳过 $skippedCount 个', 'info');
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
        // 封面/作者/时长必须一并落盘，否则重启后
        // 从历史恢复出来的「已下载」项没有封面和作者。
        'cover': video.cover,
        'author': video.author,
        'duration': video.duration,
        'upload_date': video.uploadDate,
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

  /// 获取已下载视频的本地路径
  Future<String?> getDownloadedPath(String videoId) async {
    final db = await _getDb();
    if (db == null) return null;

    final result = await db.query(
      'download_history',
      columns: ['file_path'],
      where: 'video_id = ?',
      whereArgs: [videoId],
    );

    if (result.isNotEmpty) {
      return result.first['file_path'] as String?;
    }
    return null;
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

  /// 删除单个下载历史记录
  Future<void> deleteDownloadHistory(String videoId) async {
    final db = await _getDb();
    if (db == null) return;
    await db.delete('download_history', where: 'video_id = ?', whereArgs: [videoId]);
  }

  /// ✅ 清空下载历史
  Future<void> clearDownloadHistory() async {
    final db = await _getDb();
    if (db == null) return;
    await db.delete('download_history');
  }

  // ==================== 控制方法 ====================
  // 这些方法作用于「当前正在跑的下载」。并发多任务时请改用
  // DownloadManager 持有的每任务 DownloadControl 句柄。

  void stop() => control.stop();

  /// 暂停：不再派发新切片，等在途切片收尾后挂起。
  /// 已下载的切片保留在临时目录，恢复后据此续传。
  void pause() => control.pause();

  void resume() => control.resume();

  void reset() => control.reset();

  /// 更换站点
  void changeSite(String newBaseUrl) {
    baseUrl = newBaseUrl;
    // 先检测新站点类型（_initDio 内部依赖 _siteType 选择请求头）
    _detectSiteType();
    // 清除旧站点的 Cookie，避免跨站点干扰（特别是从 original 切到 porn91 时）
    _dio.options.headers.remove('Cookie');
    // 再用新站点类型初始化请求头
    _initDio();
  }
}
