/// 爬虫核心类
/// 严格参照 Python 版本 _src/lib/__init__.py

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'config.dart';
import '../models/video_info.dart';
import '../utils/logger.dart';
import '../utils/network_log_interceptor.dart';

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

  /// 这次失败是否值得重试。
  ///
  /// 默认 true（网络抖动、切片失败等重试通常有效）。
  /// Cloudflare 人机验证这类确定性拒绝会置 false —— 立即重试只会
  /// 加重风控、且必然再次失败。
  bool retryable = true;

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

  /// 用户选择的播放线路域名（空串 = 自动，不改写）。
  ///
  /// 注意：porn91 与 original 站点的节点表完全不同，
  /// 设置页会按当前站点类型给出各自的选项，这里只认本类型白名单内的值。
  String cdnHost = '';

  /// 按当前线路改写视频地址。
  ///
  /// 只在原 host 属于**本站点类型**的域名集合时才改写：
  /// 换了别家的地址（比如把 hdcdn 的地址套到 91porn 上）只会一律 404。
  /// 已经是目标域名、或用户选了「自动」时原样返回。
  String applyCdnHost(String url) {
    if (cdnHost.isEmpty) return url;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    if (!CrawlerConfig.hostsFor(_siteType).contains(uri.host)) return url;
    if (uri.host == cdnHost) return url;
    // 九色系带 token 的 /s/<token>/ 路径只认 jiuse3 系，
    // 改写去 jiuse2 系一定 403——宁可让原地址继续用，也别把能放的地址改坏。
    if (CrawlerConfig.jiuseTokenPath(url) &&
        CrawlerConfig.jiuseHostSwapBlocked(uri.host, cdnHost)) {
      return url;
    }
    // porn91 的直链带 st/e/k/f 签名，签名与签发它的主机绑定。
    // 把 la.btc620.com 改写到别的线路后，路径和 query 原样送过去，
    // 服务器校验签名对不上，一律回 403——用户看到的就是「下到一半失败」
    // 或「存了个网页当视频」。这类地址只能原样使用。
    if (CrawlerConfig.isSignedMediaUrl(url)) {
      Logger().logSync('Cdn',
          '跳过 CDN 改写（地址带站点签名，换主机必然 403）: ' + uri.host);
      return url;
    }
    return uri.replace(host: cdnHost).toString();
  }
  
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
  ///
  /// 同时把它登记为兜底句柄 [_zoneControl]：调用方在 runWithControl
  /// 之外（同步上下文）读 control 时也能命中本次下载的句柄，
  /// 不会再另建一个永远不会被回调的「孤儿句柄」——
  /// 这正是「进度条不动」的根因。
  DownloadControl beginDownload() {
    final ctrl = DownloadControl();
    _zoneControl = ctrl;
    return ctrl;
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

  /// 手动指定的站点类型（自定义站点由用户归类时传入，null = 按域名推断）
  String? _manualSiteType;

  CrawlerCore({
    required this.baseUrl,
    this.imgBaseUrl,
    Dio? dio,
    this.externalDbPath,
    String? siteType,
  }) : _dio = dio ?? Dio() {
    // 重要：先检测站点类型，再初始化Dio（请求头依赖站点类型）
    _manualSiteType = siteType != null
        ? CrawlerConfig.normalizeSiteType(siteType)
        : null;
    _detectSiteType();
    _initDio();
    // 网络请求日志：只挂一次。
    // 不能放进 _initDio —— 它每次都会重建 options，但拦截器挂在
    // _dio.interceptors 上不会随 options 清空，重复挂会出现多条重复记录。
    // 无条件挂上：拦截器内部自己判断 logger.enabled。
    // 若按「创建时是否已开启日志」决定挂不挂，用户中途打开 Debug 后
    // 已存在的 CrawlerCore 就再也记不到网络请求了。
    final hasNetLog = _dio.interceptors.any((i) => i is NetworkLogInterceptor);
    if (!hasNetLog) {
      _dio.interceptors.add(NetworkLogInterceptor(name: _siteType));
    }
  }
  
  /// 检测站点类型
  ///
  /// 自定义站点的域名不在 CrawlerConfig.siteTypes 里，纯按域名推断只能得到
  /// original。用户手动归类后由 [_manualSiteType] 优先，否则解析模板、
  /// 请求头、解密分支全都套错，站点一条也解析不出来。
  void _detectSiteType() {
    _siteType = _manualSiteType ?? CrawlerConfig.detectSiteType(baseUrl);
    Logger().logSync('Crawler', '站点类型检测: domain=${Uri.parse(baseUrl).host}, type=$_siteType'
        '${_manualSiteType != null ? ' (手动指定)' : ''}');
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

  /// 上一次 jiuse 列表解析出的 id 序列。
  ///
  /// jiuse 页面不渲染任何分页控件（分页块、page= 链接、下一页文本全为 0），
  /// 只能靠「本页是否与上一页完全相同」来判断是否已经到底：站点在越界时
  /// 有的会返回空列表，有的会原样回放最后一页，后者必须靠内容比对拦下。
  String _lastJiuseSignature = '';

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

  /// 计算并写入本页的分页判断结果
  ///
  /// jiuse 优先看分区页的路径式分页链接，拿不到再退回「条数 + 与上一页比对」
  /// 的专用判据；其余站点沿用 [_detectHasNextPage] 的通用策略。
  void _applyPagination(String html, int page, List<VideoInfo> videos) {
    if (_siteType == 'jiuse') {
      final signature = videos.map((v) => v.id).join(',');

      // 分区页（/video/category/*）页脚有真实分页控件，直接用页码链接判断，
      // 比「条数 + 内容比对」准确得多（分区页每页条数不固定，条数判据会误判）。
      final fromLinks = CrawlerConfig.jiusePaginationHasMore(html, page);
      if (fromLinks != null) {
        _lastPaginationParsed = true;
        _lastJiuseSignature = signature;
        _lastRequestHasMore = fromLinks;
        _logPagination(
          fromLinks
              ? 'jiuse 分页控件命中：存在大于第 $page 页的链接'
              : 'jiuse 分页控件命中：没有更靠后的页码链接，判定为最后一页',
          fromLinks,
        );
        return;
      }

      final hasMore = CrawlerConfig.jiusePageHasMore(
        itemCount: videos.length,
        page: page,
        signature: signature,
        lastSignature: _lastJiuseSignature,
      );
      _lastPaginationParsed = true;
      _lastJiuseSignature = signature;
      _lastRequestHasMore = hasMore;
      _logPagination(
          'jiuse 无分页控件，按条数与重复内容判断：${videos.length} 条', hasMore);
      return;
    }
    if (_siteType == 'hifuli') {
      // 嗨碰只有 /hot、/recommend、/tag、/s 带分页控件，且它的
      // data-last-page 数字并不可信（/hot 标 15307，实际 page/15124 仍有内容），
      // 唯一可靠的判据是 data-next-url 是否为空。
      final hasMore = CrawlerConfig.hifuliHasNextPage(html);
      if (hasMore == null) {
        // 首页 / 最新视频：没有分页控件，且每次请求内容都会随机重排，
        // 条数兜底在这里恒为真，会让无限滚动永远停不下来 —— 直接当单页。
        _lastPaginationParsed = true;
        _lastRequestHasMore = false;
        _logPagination('hifuli 页面无分页控件，按单页信息流处理', false);
        return;
      }
      _lastPaginationParsed = true;
      _lastRequestHasMore = hasMore;
      _logPagination(
        hasMore
            ? 'hifuli 分页控件命中：data-next-url 不为空，还有下一页'
            : 'hifuli 分页控件命中：data-next-url 为空，已是最后一页',
        hasMore,
      );
      return;
    }
    _lastRequestHasMore = _detectHasNextPage(html, page, videos.length);
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
    
    // jiuse 有两种分页格式，交给 config 判断；别的站点是路径占位符
    String url;
    if (_siteType == 'jiuse') {
      url = CrawlerConfig.buildJiuseListUrl(baseUrl, urlPattern, page);
    } else if (_siteType == 'hifuli') {
      // 首页与「最新视频」是无页码的单页信息流，其余分区走 /xxx/page/N
      url = CrawlerConfig.buildHifuliListUrl(baseUrl, urlPattern, page);
    } else {
      url = '$baseUrl/${urlPattern.replaceAll('{page}', page.toString())}';
    }
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
      if (_siteType == "jiuse") {
        videos = _parseVideoListJiuse(html);
      } else if (_siteType == "hifuli") {
        videos = _parseVideoListHifuli(html);
      } else if (_siteType == "porn91") {
        videos = _parseVideoListPorn91(html);
      } else {
        videos = _parseVideoListOriginal(html);
      }
      
      // ✅ 关键调试日志：记录 URL 和解析结果的对应关系
      await logger.log('Crawler', '解析结果: URL=$urlWithCache -> ${videos.length} 个视频');

      // 依据站点分页控件判断是否还有下一页（jiuse 无控件，走专用判据）
      _applyPagination(html, page, videos);

      return videos;
      
    } catch (e) {
      await logger.log('Crawler', '获取视频列表失败: $e (URL=$urlWithCache)');
      _lastPaginationParsed = false;
      return [];
    }
  }

  /// 供测试直接调用 jiuse 列表解析（解析器是私有的，测试在另一个 library）
  @visibleForTesting
  List<VideoInfo> parseJiuseListForTest(String html) =>
      _parseVideoListJiuse(html);

  /// 供测试直接调用嗨碰列表解析
  @visibleForTesting
  List<VideoInfo> parseHifuliListForTest(String html) =>
      _parseVideoListHifuli(html);

  /// 供测试直接调用嗨碰「从卡片提炼作者」的解析
  @visibleForTesting
  List<AuthorInfo> parseHifuliAuthorsForTest(String html) =>
      _parseHifuliAuthorsFromCards(html);

  /// 供测试直接调用分页判据（jiuse 无分页控件，走条数 + 重复内容比对）
  @visibleForTesting
  void applyPaginationForTest(String html, int page, List<VideoInfo> videos) =>
      _applyPagination(html, page, videos);

  /// 供测试直接调用 m3u8 切片解析
  @visibleForTesting
  List<String> parseM3u8ForTest(String content, String baseUrl) =>
      _parseM3u8(content, baseUrl);

  /// 解析 jiuse 站点（91porny / jiuse.icu）的视频列表
  ///
  /// 卡片结构见 [CrawlerConfig.jiuseCardPattern] 的注释。
  /// 三个要点：
  /// 1. 卡片区混着整段是站外跳转的广告，必须只认站内 /xxx/view/yyy 链接；
  /// 2. 作者写在「作者:」文本里，且可能是纯文本也可能是 <a>；
  /// 3. 封面在 style="background-image: url('...')" 里，不是 img[src]。
  List<VideoInfo> _parseVideoListJiuse(String html) {
    final videos = <VideoInfo>[];
    final seenIds = <String>{};
    var hdSkipped = 0;
    Logger().logSync('Parse', '解析 jiuse HTML, 长度: ${html.length}');

    for (final m in CrawlerConfig.jiuseCardPattern.allMatches(html)) {
      final card = m.group(1)!;

      // 必须是站内视频详情链接，站外广告直接跳过
      final hrefMatch =
          CrawlerConfig.jiuseVideoHrefPattern.firstMatch(card);
      if (hrefMatch == null) continue;
      final href = hrefMatch.group(1)!;

      // 高清（/video/viewhd/）整条跳过：未登录时该路径恒返回 12 秒样片，
      // 所有视频共用同一段画面，下载下来必是同一个文件；同一 id 改走
      // /video/view/ 又只给 6 秒 VIP 占位。所以高清不进列表。
      if (CrawlerConfig.jiuseIsHdPath(href)) {
        hdSkipped++;
        continue;
      }

      // 取详情 id 作为唯一键：
      //   /vod/view/SxeO                              -> SxeO
      //   /videos/view/127663/410ed2e1f969cb2d3125/   -> 127663（取第一段）
      final id = CrawlerConfig.jiuseVideoId(href);
      if (id == null || id.isEmpty) continue;
      if (seenIds.contains(id)) continue;
      seenIds.add(id);

      // 标题：优先取 title 链接的文本，取不到再退回任意 title= 属性
      String? title;
      final titleLink = RegExp(
        r'<a[^>]*class="[^"]*\btitle\b[^"]*"[^>]*>([^<]+)</a>',
        caseSensitive: false,
      ).firstMatch(card);
      if (titleLink != null) {
        title = CrawlerConfig.stripInvisible(titleLink.group(1)!).trim();
      }
      title ??=
          RegExp(r'title="([^"]+)"').firstMatch(card)?.group(1)?.trim();
      if (title == null || title.isEmpty) continue;

      // 封面
      String? cover;
      final coverMatch = RegExp(
        r"""background-image:\s*url\(\s*['"]?([^)'"]+)""",
      ).firstMatch(card);
      if (coverMatch != null) {
        // 封面有两种相对写法：//cdn.../1.jpg（协议相对）与 /static/1.jpg（站内相对），
        // 早期统一 '$baseUrl$u' 会把协议相对地址拼成 https://host//cdn...
        cover = CrawlerConfig.resolveJiuseAssetUrl(baseUrl, coverMatch.group(1)!);
      }

      // 时长：
      // <small class="layer">00:22:08</small>
      String? duration;
      final durMatch = RegExp(
        r'<small[^>]*class="[^"]*\blayer\b[^"]*"[^>]*>\s*([0-9:]+)\s*</small>',
        caseSensitive: false,
      ).firstMatch(card);
      if (durMatch != null) duration = durMatch.group(1);

      // 作者：作者: <a ...>名字</a> 或 作者: 名字
      String? author;
      String? authorId;
      final authorLink =
          CrawlerConfig.jiuseAuthorLinkPattern.firstMatch(card);
      if (authorLink != null) {
        // 站点有两套作者主页：/author/xxx 与 /dashen/xxx。
        // 记住前缀，取作者视频时才能拼对路径（dashen 系拼成 /author/ 会 404）。
        authorId = CrawlerConfig.jiuseAuthorId(
            authorLink.group(1)!, authorLink.group(2)!);
        author = CrawlerConfig.stripInvisible(authorLink.group(3)!).trim();
      } else {
        final plain = RegExp(r'作者[:：]\s*([^<\n\r]+)', caseSensitive: false)
            .firstMatch(card);
        if (plain != null) {
          author = CrawlerConfig.stripInvisible(plain.group(1)!).trim();
        }
      }

      // 日期 + 播放数：2026-11-05&nbsp;|&nbsp;1351次播放
      String? uploadDate;
      String? views;
      final dateMatch =
          RegExp(r'(\d{4}-\d{2}-\d{2})').firstMatch(card);
      if (dateMatch != null) uploadDate = dateMatch.group(1);
      final viewMatch =
          RegExp(r'([\d.]+\s*[万wW]?)\s*次播放').firstMatch(card);
      if (viewMatch != null) views = viewMatch.group(1)!.trim();

      Logger().logSync('Parse',
          'jiuse 视频: ID=$id, 作者=$author, 时长=$duration, 标题=${title.length > 20 ? title.substring(0, 20) + "..." : title}');

      videos.add(VideoInfo(
        id: id,
        url: '$baseUrl$href',
        title: title,
        cover: cover,
        author: author,
        authorId: authorId,
        duration: duration,
        uploadDate: uploadDate,
        views: views,
      ));
    }

    Logger().logSync('Parse',
        'jiuse 解析完成: ${videos.length} 个视频（跳过高清 $hdSkipped 条）');
    return videos;
  }

  /// 解析嗨碰（hifuli.com / hiporn.net）的视频列表
  ///
  /// 首页与列表页是两套 DOM（首页卡片直接挂在 grid 下，列表页外面多一层
  /// article.hiporn-list-card 和 meta 行），但卡片本身的 class 一致，
  /// 所以统一按卡片切片取字段：
  ///   a.hiporn-video-card[href=/video/{数字id}-{slug}]
  ///     ├ div.hiporn-video-card-thumb > img[data-original=封面] + span.…duration
  ///     └ h3.hiporn-video-card-title 标题
  ///
  /// 注意：封面只在 data-original，src 恒为占位图 /dist/notfound.jpg。
  List<VideoInfo> _parseVideoListHifuli(String html) {
    final videos = <VideoInfo>[];
    final seenIds = <String>{};
    Logger().logSync('Parse', '解析 hifuli HTML, 长度: ${html.length}');

    for (final m in CrawlerConfig.hifuliCardPattern.allMatches(html)) {
      final card = m.group(0)!;

      final hrefMatch = CrawlerConfig.hifuliHrefPattern.firstMatch(card);
      if (hrefMatch == null) continue;
      final href = hrefMatch.group(1)!;
      final id = hrefMatch.group(2)!;
      if (seenIds.contains(id)) continue;
      seenIds.add(id);

      // 标题：卡片标题节点优先，取不到退回图片 alt
      String? title;
      final titleMatch = CrawlerConfig.hifuliTitlePattern.firstMatch(card);
      if (titleMatch != null) title = titleMatch.group(1);
      if (title == null || title.trim().isEmpty) {
        final alt = RegExp(r'alt="([^"]*)"', caseSensitive: false)
            .firstMatch(card)
            ?.group(1);
        if (alt != null && alt.trim().isNotEmpty) title = alt;
      }
      if (title == null || title.trim().isEmpty) continue;
      title = CrawlerConfig.stripInvisible(
              CrawlerConfig.unescapeHtml(title))
          .trim();

      // 封面：只认 data-original，src 是占位图
      String? cover;
      final coverMatch =
          CrawlerConfig.hifuliCoverPattern.firstMatch(card);
      if (coverMatch != null) {
        cover = CrawlerConfig.resolveAbsoluteUrl(
            baseUrl, coverMatch.group(1)!.trim());
      }

      // 时长：span.hiporn-video-card-duration（形如 41:11）
      String? duration;
      final durMatch =
          CrawlerConfig.hifuliDurationPattern.firstMatch(card);
      if (durMatch != null) {
        final d = durMatch.group(1)!.trim();
        if (d.isNotEmpty && d != '--:--') duration = d;
      }

      // 作者与上传时间都在卡片下方的 meta 行里（列表/搜索/推荐/热榜页专有）：
      //   div.hiporn-list-card-meta
      //     ├ a.hiporn-list-card-author[href=/u/{urlencode 名字}] > span 名字
      //     └ time.hiporn-list-card-time 「3天前」
      //
      // 作者 id 优先取站点给的 href：把显示名重新编码在「显示名 ≠ URL 名」
      // 时（含空格、emoji、大小写变体）会拼出打不开的主页地址。
      // meta 行只有 a/img/span/time，不含嵌套 div，所以切块不会截断。
      String? author;
      String? authorId;
      String? uploadDate;
      final metaMatch = CrawlerConfig.hifuliCardMetaPattern.firstMatch(card);
      if (metaMatch != null) {
        final meta = metaMatch.group(1)!;

        final hrefMatch =
            CrawlerConfig.hifuliCardAuthorHrefPattern.firstMatch(meta);
        final idFromHref = hrefMatch == null
            ? ''
            : CrawlerConfig.normalizeHifuliAuthorId(hrefMatch.group(1)!);

        final authorMatch =
            CrawlerConfig.hifuliCardAuthorPattern.firstMatch(meta);
        if (authorMatch != null) {
          final name = CrawlerConfig.stripInvisible(
                  CrawlerConfig.unescapeHtml(authorMatch.group(1)!))
              .trim();
          if (name.isNotEmpty) {
            author = name;
            // 「匿名」是站点给未登录/匿名投稿占的位，点进去只有一页无关视频，
            // 不提供跳转（保持原有行为）；有真实 href 时其余作者一律可跳。
            if (name != '匿名') {
              authorId = idFromHref.isNotEmpty
                  ? idFromHref
                  : Uri.encodeComponent(name);
            }
          }
        }

        final timeMatch =
            CrawlerConfig.hifuliCardTimePattern.firstMatch(meta);
        if (timeMatch != null) {
          final t = CrawlerConfig.stripInvisible(
                  CrawlerConfig.unescapeHtml(timeMatch.group(1)!))
              .trim();
          if (t.isNotEmpty) uploadDate = t;
        }
      }

      videos.add(VideoInfo(
        id: id,
        url: '$baseUrl$href',
        title: title,
        cover: cover,
        author: author,
        authorId: authorId,
        duration: duration,
        // 相对时间（3天前 / 4小时前），与详情页的绝对日期是同一件事
        uploadDate: uploadDate,
      ));
    }

    Logger().logSync('Parse', 'hifuli 解析完成: ${videos.length} 个视频');
    return videos;
  }

  /// 从嗨碰的视频列表/搜索页里提炼作者（去重后按命中条数排序）
  ///
  /// 站点没有独立的「搜索到用户」区块，作者信息只存在于每张卡片的 meta 行，
  /// 所以搜索作者只能复用它。这里刻意和 [_parseVideoListHifuli] 用同一套
  /// 正则与 id 规范，保证「列表里能点的作者」与「搜索出来的作者」是同一批、
  /// 同一个 authorId，否则点进主页会 404。
  List<AuthorInfo> _parseHifuliAuthorsFromCards(String html) {
    final counts = <String, int>{};
    final names = <String, String>{};

    // 显示名与 href 不一致时以 href 为准，所以用 href 派生的 id 做去重键。
    for (final card in CrawlerConfig.hifuliCardPattern.allMatches(html)) {
      final metaMatch =
          CrawlerConfig.hifuliCardMetaPattern.firstMatch(card.group(0)!);
      if (metaMatch == null) continue;
      final meta = metaMatch.group(1)!;

      final nameMatch = CrawlerConfig.hifuliCardAuthorPattern.firstMatch(meta);
      if (nameMatch == null) continue;
      final name = CrawlerConfig.stripInvisible(
              CrawlerConfig.unescapeHtml(nameMatch.group(1)!))
          .trim();
      // 「匿名」是站点给匿名投稿占的位，主页里没有作者维度内容，不收录。
      if (name.isEmpty || name == '匿名') continue;

      final hrefMatch =
          CrawlerConfig.hifuliCardAuthorHrefPattern.firstMatch(meta);
      final id = hrefMatch == null
          ? Uri.encodeComponent(name)
          : CrawlerConfig.normalizeHifuliAuthorId(hrefMatch.group(1)!);
      if (id.isEmpty) continue;

      names[id] = name;
      counts[id] = (counts[id] ?? 0) + 1;
    }

    final authors = names.entries
        .map((e) => AuthorInfo(
              id: e.key,
              name: e.value,
              // 站点不给作者总投稿数，这里用「本次结果里命中的视频条数」代替：
              // 它是一个真实数字，比硬编码 0 有信息量，也能用来排序。
              videoCount: counts[e.key] ?? 0,
              profileUrl: '$baseUrl/u/${e.key}',
            ))
        .toList();

    // 命中数多的排前面：搜索时作者的相关性和这个基本成正比。
    authors.sort((a, b) => b.videoCount.compareTo(a.videoCount));
    return authors;
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
      
      // 站点把标题逐字拆开并插入变体选择符（U+FE00~U+FE0F），
      // 这些字符没有字形但占位，不剔除的话界面上看着就是字间多了空格。
      final title = CrawlerConfig.stripInvisible(titleMatch.group(1)!).trim();
      if (title.isEmpty) continue;
      
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

      // 格式2b: <span class="info">From:</span> 后紧跟作者名。
      // 91porn 卡片里作者的写法是 From:，不是「作者：」，
      // 只认中文标签会漏掉一半视频的作者。
      if (author == null || author.isEmpty) {
        final fromMatch = RegExp(
          r'From[：:]\s*</span>\s*([^<\n\r]+)',
          caseSensitive: false,
        ).firstMatch(wellContent);
        if (fromMatch != null) {
          author = fromMatch.group(1)?.trim();
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
        // 作者名和标题一样被塞了变体选择符，必须一并剔除；
        // 放在 whitespacePattern 之前，否则这些字符会被当成空白折叠成空格。
        author = CrawlerConfig.stripInvisible(author);
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
      if (_siteType == "jiuse") {
        videos = _parseVideoListJiuse(html);
      } else if (_siteType == "hifuli") {
        videos = _parseVideoListHifuli(html);
      } else if (_siteType == "porn91") {
        videos = _parseVideoListPorn91(html);
      } else {
        videos = _parseVideoListOriginal(html);
      }
      
      await logger.log('Crawler', '搜索结果: ${videos.length} 个视频');

      // 依据站点分页控件判断是否还有下一页（jiuse 无控件，走专用判据）
      _applyPagination(html, page, videos);

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
    } else if (_siteType == "jiuse") {
      // jiuse 没有独立的作者搜索接口：「搜索到用户」区块就在同一个
      // /search?keywords=xxx 结果页里（排在视频区块之前）
      url = CrawlerConfig.buildSearchUrl(baseUrl, _siteType, keyword);
    } else if (_siteType == "hifuli") {
      // 嗨碰没有独立的「搜索到用户」区块：/s/{关键词} 只返回视频卡片，
      // 作者信息只存在于每张卡片下方的 meta 行（a.hiporn-list-card-author）。
      // 所以这里照常请求搜索页，再按视频卡片的同源规则把作者抽出来去重。
      url = CrawlerConfig.buildSearchUrl(baseUrl, _siteType, keyword);
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

      // ---- jiuse：结果页里「搜索到用户」区块 ----
      //
      // 该站没有独立作者搜索接口，用户区块和视频区块在同一个 /search 页里。
      // 用户链接带 badge class，视频卡片里的作者链接只有 text-dark，
      // 按 badge 过滤即可只拿用户。
      if (_siteType == "jiuse") {
        for (final match
            in CrawlerConfig.jiuseAuthorBadgePattern.allMatches(html)) {
          final path = match.group(1)!;            // /author/Testgogogo
          final authorParam = match.group(2)!.trim(); // Testgogogo
          final namePart = (match.group(3) ?? '').trim();
          final count = int.tryParse(match.group(4) ?? '0') ?? 0;
          if (authorParam.isEmpty) continue;
          if (seenNames.contains(authorParam)) continue;
          seenNames.add(authorParam);
          authors.add(AuthorInfo(
            id: authorParam,
            name: namePart.isNotEmpty ? namePart : authorParam,
            videoCount: count,
            profileUrl: '$baseUrl$path',
          ));
        }
        await logger.log('Crawler', 'jiuse 作者搜索结果: ${authors.length} 个');
        return authors;
      }

      // ---- hifuli：搜索页没有用户区块，作者只能从视频卡片的 meta 行提炼 ----
      //
      // 和 _parseVideoListHifuli 用同一套正则，保证「列表里能点的作者」
      // 和「搜索结果里的作者」是同一批人、同一个 authorId（否则点进主页会 404）。
      if (_siteType == "hifuli") {
        final fromCards = _parseHifuliAuthorsFromCards(html);
        await logger.log('Crawler', 'hifuli 作者搜索结果: ${fromCards.length} 个');
        return fromCards;
      }
      
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
    } else if (_siteType == "jiuse") {
      // jiuse 作者主页：/author/{id} 或 /dashen/{id}
      //
      // 站点有两套作者主页，解析卡片时把前缀记进 authorId（dashen/xxx），
      // 这里原样拼路径即可；缺前缀的默认按 /author/ 处理。
      //
      // authorId 可能已是 URL 编码（%E9%85%92%E7%A5%9E）、也可能带尾随空格的
      // 编码形式（%20），原样拼进路径即可，不能再编码一次。
      final id = authorId.trim();
      final path = id.startsWith('author/') || id.startsWith('dashen/')
          ? id
          : 'author/$id';
      url = page <= 1
          ? '$baseUrl/$path'
          : '$baseUrl/$path?page=$page';
    } else if (_siteType == "hifuli") {
      // 嗨碰作者主页：/u/{urlencode 名字}，第 2 页起 /u/{名字}/page/{page}
      //
      // authorId 有两个来源：列表卡片 href 里的 /u/xxx（已编码，原样可用）、
      // 详情页按名字编码的兜底值。调用方也可能直接把 profileUrl 的
      // "/u/xxx" 整段传进来，所以统一剥掉前缀再拼，避免 /u/u/xxx。
      final id = CrawlerConfig.normalizeHifuliAuthorId(authorId);
      url = page <= 1 ? '$baseUrl/u/$id' : '$baseUrl/u/$id/page/$page';
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
      } else if (_siteType == "jiuse") {
        // 作者主页与列表页是同一套 colVideoList 卡片，此前落到 original
        // 解析器（找 video-item），必然 0 条
        videos = _parseVideoListJiuse(html);
      } else if (_siteType == "hifuli") {
        // 嗨碰作者页 /u/{名字} 与列表页共用 hiporn-video-card 卡片
        videos = _parseVideoListHifuli(html);
      } else {
        videos = _parseVideoListOriginal(html);
      }

      // 依据站点分页控件判断是否还有下一页（jiuse 无控件，走专用判据）
      _applyPagination(html, page, videos);

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
      // 每次请求前复位，避免上一次的失败标记残留到这一次
      lastDetailError = null;
      lastDetailBlockedByChallenge = false;
      lastDetailSampleOnly = false;
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

      // 嗨碰详情页的标题/作者/时长/日期/播放数（在下面的专用分支里填）
      String? hipornTitle;
      String? hipornAuthor;
      // 详情页只有作者名、没有 /u/ 主页链接，这里是「列表没带 id 时」的兜底
      String? hipornAuthorId;
      String? hipornDuration;
      String? hipornDate;
      String? hipornViews;
      
      // ===== porn91 专用策略 =====
      if (_siteType == "porn91") {
        
        // ✅ 从播放页 poster 属性提取视频ID（如 poster="https://.../thumb/848765.jpg"）
        // 注意：列表页封面ID与视频ID无关，必须用播放页poster ID
        String? posterVideoId;
        // 站点同时存在 .jpg / .webp 两种封面后缀，两种都要认，
        // 否则 poster ID 取不到，下面按 ID 匹配真实视频地址那步会失效。
        final posterMatch =
            RegExp(r'poster="[^"]*thumb/(\d+)\.(?:jpe?g|webp|png)"')
                .firstMatch(html);
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
                // 广告片也可能被站点塞进 strencode2。取「首个」时若不排掉，
                // 用户下到的就是那条几十秒的推广片（与正片完全无关）。
                if (CrawlerConfig.knownAdVideoIds.any(src.contains)) {
                  await logger.log('Debug', '跳过广告视频地址(strencode2): ${src.substring(0, 60)}...');
                  continue;
                }
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
                //
                // 91porn 的播放页里 <source> 常常整段就是广告片（358999），
                // 真实地址只藏在下面的 strencode2 里。这里必须认出来，
                // 否则会拿广告地址去下载，用户下到的是几十秒的推广片。
                if (CrawlerConfig.knownAdVideoIds.any(src.contains)) {
                  await logger.log('Debug', '跳过广告视频地址: ${src.substring(0, 60)}...');
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
      
      // ===== jiuse 站点（91porny / jiuse.icu）=====
      //
      // 详情页把播放地址放在 <video data-src="..."> 上（不是 <source src>），
      // 由前端 JS 在播放时才塞进播放器；纯 HTTP 抓取必须自己读 data-src。
      if (videoUrl == null && _siteType == "jiuse") {
        final dataSrc = RegExp(
          r'<video[^>]*\bdata-src="([^"]+)"',
          caseSensitive: false,
        ).firstMatch(html);
        if (dataSrc != null) {
          // 站点常给协议相对地址（//cdn2.jiuse2.cloud/...）。
          // 原样交给 Dio 会抛 Unsupported scheme ''，任务 0% 直接失败。
          videoUrl = CrawlerConfig.resolveAbsoluteUrl(
              baseUrl, dataSrc.group(1)!.replaceAll('&amp;', '&'));
          extractionMethod = 'jiuse-data-src';
          await logger.log('Debug', 'jiuse data-src: ${videoUrl.length > 120 ? videoUrl.substring(0, 120) + "..." : videoUrl}');
        }
        // 兜底：有些页面把地址写在 video 的 source 子节点里
        if (videoUrl == null) {
          final srcMatch = RegExp(
            r'<video[^>]*>[\s\S]{0,400}?src="([^"]+\.m3u8[^"]*)"',
            caseSensitive: false,
          ).firstMatch(html);
          if (srcMatch != null) {
            videoUrl = CrawlerConfig.resolveAbsoluteUrl(
                baseUrl, srcMatch.group(1)!.replaceAll('&amp;', '&'));
            extractionMethod = 'jiuse-video-src';
          }
        }

        // data-src 有时指向站点内置的 12 秒样片（/hlsd/<名字>/index.m3u8），
        // 直接下载/播放就只有 11 秒，而且**所有视频都是同一段画面**——
        // 用户下载多个视频得到相同文件就是这么来的。
        // 真实地址有两条来路，按成功率依次尝试：
        //   1) GET {baseUrl}/apiDownloadUrl/{data-id}（未登录常回 422）
        //   2) GET {baseUrl}/video/embed/{id}（HTML 内联一条带 token 的地址）
        if (videoUrl == null || CrawlerConfig.isJiuseSampleUrl(videoUrl)) {
          if (videoUrl != null) {
            await logger.log('Debug',
                'jiuse 命中站点样片地址（所有视频共用），尝试换真实地址');
          }
          var real = await _fetchJiuseRealUrl(baseUrl, html);
          if (real != null) {
            extractionMethod = 'jiuse-apiDownloadUrl';
          } else {
            real = await _fetchJiuseEmbedUrl(baseUrl, video.id);
            if (real != null) extractionMethod = 'jiuse-embed';
          }
          if (real != null) {
            videoUrl = real;
          } else {
            // 换不到就退回样片，但必须让用户知道这是「12 秒预览」，
            // 不能静默下成一段和别的视频一模一样的 11 秒画面。
            lastDetailSampleOnly = true;
            await logger.log('Warning',
                'jiuse 未能换到真实地址，只能拿到站点样片（约 12 秒，所有视频相同）');
          }
        }
      }

      // ===== 嗨碰（hifuli.com / hiporn.net）=====
      //
      // 页面里既没有 <video> 也没有 <source>，播放地址写在前端配置对象上：
      //   window.HIPORN_WATCH = { ..., player: { url: 'https://....m3u8?sign=...&t=...',
      //                                          pic: '...', durationSec: 300, type: 'hls' } }
      // 同一份地址在 JSON-LD 的 contentUrl 里也有一份，互为兜底。
      //
      // 注意 sign/t 是带时效的签名（每次请求都变），所以这个地址不能缓存，
      // 每次播放/下载都必须重新抓详情页。
      if (videoUrl == null && _siteType == "hifuli") {
        final playerMatch =
            CrawlerConfig.hifuliPlayerUrlPattern.firstMatch(html);
        if (playerMatch != null) {
          videoUrl = CrawlerConfig.resolveAbsoluteUrl(
              baseUrl, playerMatch.group(1)!.replaceAll('&amp;', '&'));
          extractionMethod = 'hifuli-HIPORN_WATCH';
        }
        if (videoUrl == null) {
          final contentMatch =
              CrawlerConfig.hifuliContentUrlPattern.firstMatch(html);
          if (contentMatch != null) {
            videoUrl = CrawlerConfig.resolveAbsoluteUrl(
                baseUrl, contentMatch.group(1)!.replaceAll('&amp;', '&'));
            extractionMethod = 'hifuli-jsonld';
          }
        }
        if (videoUrl != null) {
          await logger.log('Debug',
              'hifuli 播放地址($extractionMethod): ${videoUrl.length > 120 ? videoUrl.substring(0, 120) + "..." : videoUrl}');
        } else {
          await logger.log('Warning', 'hifuli 详情页未找到 player.url / contentUrl');
        }

        final titleMatch =
            CrawlerConfig.hifuliDetailTitlePattern.firstMatch(html);
        if (titleMatch != null) {
          final t = CrawlerConfig.stripInvisible(
                  CrawlerConfig.unescapeHtml(titleMatch.group(1)!))
              .trim();
          if (t.isNotEmpty) hipornTitle = t;
        }
        final authorMatch =
            CrawlerConfig.hifuliDetailAuthorPattern.firstMatch(html);
        if (authorMatch != null) {
          final a = CrawlerConfig.stripInvisible(
                  CrawlerConfig.unescapeHtml(authorMatch.group(1)!))
              .trim();
          if (a.isNotEmpty) {
            hipornAuthor = a;
            // 详情页作者块没有 /u/ 链接（全文 0 命中），只能按站点路径规则
            // 把名字编码成 /u/{urlencode 名字}。列表页带来的 authorId 优先，
            // 这里是「直接从详情页打开、没有列表上下文」时的兜底。
            if (a != '匿名') hipornAuthorId = Uri.encodeComponent(a);
          }
        }
        final durMatch =
            CrawlerConfig.hifuliIsoDurationPattern.firstMatch(html);
        if (durMatch != null) {
          hipornDuration =
              CrawlerConfig.formatIsoDuration(durMatch.group(0));
        }
        final dateMatch =
            CrawlerConfig.hifuliUploadDatePattern.firstMatch(html);
        if (dateMatch != null) {
          // 站点给的是 ISO 串（2018-08-11T00:00:00+08:00），
          // 原样上屏会带着时分秒和时区，播放页的胶囊放不下。
          hipornDate =
              CrawlerConfig.formatHifuliDate(dateMatch.group(1)!.trim());
        }
        final viewsMatch =
            CrawlerConfig.hifuliViewsPattern.firstMatch(html);
        if (viewsMatch != null) hipornViews = viewsMatch.group(1)!.trim();
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
        // 统一补全 scheme：各条提取策略都可能拿到协议相对地址
        // （//cdn2.jiuse2.cloud/...），而 Dio 与 Uri.parse 都会抛
        // 「Unsupported scheme ''」，下载任务会在 0% 处立刻失败。
        videoUrl = CrawlerConfig.resolveAbsoluteUrl(baseUrl, videoUrl);

        // ===== porn91：解密页面里藏起来的真实标题 / 作者 / 时长 =====
        //
        // 播放页给纯 HTTP 抓取看到的是「掺了变体选择符的占位文本」，
        // 真实值要等 JS 随机延迟 2~6 秒后才写进 DOM。不自己解密的话，
        // 拿到的标题、作者都带着隐形字符，界面上看就是名字里有空格。
        Porn91Secret? secret;
        if (_siteType == "porn91") {
          secret = CrawlerConfig.decodePorn91Secret(html);
          if (secret != null && !secret.isEmpty) {
            await logger.log('Debug',
                '解密成功: 标题=${secret.title}, 作者=${secret.author}, 时长=${secret.duration}');
          } else {
            await logger.log('Debug', '未找到可解密的标题/作者节点，回退到页面文本');
          }
        }

        // 提取作者信息
        String? author = hipornAuthor ?? video.author;
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
        String? duration = hipornDuration ?? video.duration;
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
        //
        // 两种精度并存：详情页 JSON-LD 是绝对日期（yyyy-MM-dd），
        // 列表卡片 meta 是相对时间（3天前）。绝对日期更准，优先用它；
        // 拿不到才退回列表带来的相对时间，不能因为「有相对时间」就不取详情。
        String? uploadDate = hipornDate ?? video.uploadDate;
        if (uploadDate == null) {
          final dateMatch = RegExp(r'日期[：:]\s*(.+?)</div>').firstMatch(html);
          if (dateMatch != null) {
            uploadDate = dateMatch.group(1)!.trim();
          }
        }
        String? views = hipornViews ?? video.views;
        if (views == null) {
          final viewMatch = RegExp(r'观看[：:]\s*(\d+)').firstMatch(html);
          if (viewMatch != null) {
            views = viewMatch.group(1)!.trim();
          }
        }

        return VideoInfo(
          id: video.id,
          url: video.url,
          // porn91 解密出来的标题优先：页面文本是掺了变体选择符的占位值，
          // 直接用会让标题里凭空多出空格。
          title: (secret?.title?.isNotEmpty ?? false)
              ? secret!.title!
              : (hipornTitle ?? video.title),
          cover: video.cover,
          author: (secret?.author?.isNotEmpty ?? false)
              ? secret!.author
              : author,
          // 列表带来的 /u/ 真实地址优先，其次才是详情页按名字编码的兜底；
          // 两处都没有时保持 null，播放页就不会显示「查看主页」。
          authorId: (video.authorId?.isNotEmpty ?? false)
              ? video.authorId
              : hipornAuthorId,
          duration: (secret?.duration?.isNotEmpty ?? false)
              ? secret!.duration
              : duration,
          uploadDate: uploadDate,
          views: views,
          // 按用户选择的播放线路改写域名（「自动」时不改）
          m3u8Url: applyCdnHost(videoUrl),
        );
      }
      
      return null;
    } catch (e, stack) {
      // 以前这里直接 `return null`，异常和堆栈全丢。
      // 结果是「解析失败」和「页面确实没有视频」在调用方看来完全一样，
      // 用户只能看到一句模糊的失败提示，日志里也查不到任何线索。
      //
      // 特别处理 Cloudflare 人机验证：站点对 /video-*.htm 单独开了
      // 浏览器完整性检查时会返回 403 + "Just a moment..."，
      // 这不是「视频下架」也不是「站点改版」，报错必须说清楚，
      // 否则用户会一直重试、完全无从下手。
      lastDetailError = _describeDetailError(e);
      lastDetailBlockedByChallenge = _isCloudflareChallenge(e);
      await logger.log('Error', '解析视频详情失败 (${video.id}): $e');
      if (lastDetailBlockedByChallenge) {
        await logger.log(
            'Error',
            '站点返回 Cloudflare 人机验证页（HTTP 403 / "Just a moment..."）。'
            '这不是视频下架或站点改版，纯 HTTP 请求无法通过该验证。');
      }
      await logger.log('Error', '$stack');
      return null;
    }
  }

  /// 九色系：用详情页的 data-id 调站点下载接口，换出真实播放/下载地址。
  ///
  /// 站点前端（videoShow.js）的下载按钮就是：
  ///   e = $(this).attr('data-id');
  ///   requestGet('/apiDownloadUrl/' + e, url => window.open(url))
  /// 接口是纯 GET、无签名，所以这里能直接拿同样的结果。
  ///
  /// 失败（无 data-id / 接口 403 / 返回不是 URL）一律返回 null，
  /// 由调用方保留原地址——宁可播样片，也不要整条链路失败。
  Future<String?> _fetchJiuseRealUrl(String baseUrl, String html) async {
    try {
      final dataId = CrawlerConfig.jiuseDataIdFromHtml(html);
      if (dataId == null || dataId.isEmpty) {
        await logger.log('Debug', 'jiuse 详情页未找到 data-id，跳过下载接口');
        return null;
      }
      final api = CrawlerConfig.jiuseApiDownloadUrl(baseUrl, dataId);
      await logger.log('Debug', 'jiuse 下载接口: $api');
      final resp = await _dio.get(api,
          options: Options(
            headers: {
              'Cookie': _dio.options.headers['Cookie']?.toString() ??
                  'language=cn_CN',
              'Cache-Control': 'no-cache, no-store, must-revalidate',
              'Pragma': 'no-cache',
              'Expires': '0',
            },
            extra: {'cache': false},
          ));
      final real =
          CrawlerConfig.parseJiuseDownloadApiResponse(resp.data.toString());
      if (real == null) {
        await logger.log('Warning', 'jiuse 下载接口返回的不是可下载地址');
        return null;
      }
      // 接口可能返回站内相对地址（/2026/11/05/<hash>/index.m3u8）
      final abs = CrawlerConfig.resolveAbsoluteUrl(baseUrl, real);
      await logger.log('Debug',
          'jiuse 真实地址: ${abs.length > 120 ? abs.substring(0, 120) + "..." : abs}');
      return abs;
    } catch (e) {
      await logger.log('Warning', 'jiuse 下载接口失败: $e');
      return null;
    }
  }

  /// 九色系：从 /video/embed/{id} 页面里挖一条真实播放地址。
  ///
  /// /apiDownloadUrl 对未登录一律 422，而 embed 页无需登录也会返回
  /// 一条带 token 的 m3u8（形如 https://cdn3.jiuse3.cloud/s/<ts>/<token>/...）。
  /// VIP 专属视频即使拿到这条地址，播放列表本身仍会是 6 秒占位，
  /// 这一步只负责「换到不是样片的地址」，能不能播由下载阶段的
  /// [CrawlerConfig.jiusePlaylistIsPlaceholder] 判定。
  Future<String?> _fetchJiuseEmbedUrl(String baseUrl, String videoId) async {
    try {
      final embed = CrawlerConfig.jiuseEmbedUrl(baseUrl, videoId);
      await logger.log('Debug', 'jiuse embed 兜底: $embed');
      final resp = await _dio.get(embed, options: _noCacheOptions);
      final html = resp.data.toString();
      final direct = RegExp(r'''https?://[^\s"'<>]+\.m3u8[^\s"'<>]*''')
          .firstMatch(html);
      if (direct != null) {
        final abs = CrawlerConfig.resolveAbsoluteUrl(baseUrl, direct.group(0)!);
        await logger.log('Debug', 'jiuse embed 命中真实地址');
        return abs;
      }
      final rel = RegExp(r'''["'](//[^\s"']+?/[^\s"']*\.m3u8[^\s"']*)["']''')
          .firstMatch(html);
      if (rel != null) {
        return CrawlerConfig.resolveAbsoluteUrl(baseUrl, rel.group(1)!);
      }
      await logger.log('Debug', 'jiuse embed 页里没有 m3u8');
      return null;
    } catch (e) {
      await logger.log('Debug', 'jiuse embed 兜底失败: $e');
      return null;
    }
  }

  /// 最近一次 [getVideoDetail] 失败的原因，供 UI 展示更具体的提示。
  String? lastDetailError;

  /// 上次详情页请求是否被 Cloudflare 人机验证拦下。
  ///
  /// 调用方据此避免无意义的重试，并给用户可操作的提示。
  bool lastDetailBlockedByChallenge = false;

  /// 上次解析到的地址只是站点内置的 12 秒样片。
  ///
  /// 九色系的 VIP 视频未登录时换不到真实地址，退回样片地址时置位。
  /// 调用方据此在下载前就给出「这是预览片段」的提示，
  /// 而不是让用户下完一段和别的视频一模一样的 11 秒画面。
  bool lastDetailSampleOnly = false;

  /// 判断异常是否为 Cloudflare 的浏览器完整性检查。
  ///
  /// 只按「状态码 403/503 + 响应体特征」判断，不去伪造 cf_clearance
  /// 或接入打码服务——那是对抗站点防护，既不可靠也不应该做。
  bool _isCloudflareChallenge(Object e) {
    if (e is! DioException) return false;
    final code = e.response?.statusCode ?? 0;
    if (code != 403 && code != 503) return false;
    final body = e.response?.data?.toString() ?? '';
    return body.contains('Just a moment') ||
        body.contains('cf-challenge') ||
        body.contains('challenge-platform') ||
        body.contains('cf-error-details');
  }

  /// 把详情页请求异常翻译成用户能看懂、能照做的提示。
  String _describeDetailError(Object e) {
    if (_isCloudflareChallenge(e)) {
      return '站点开启了人机验证（Cloudflare），无法自动解析该视频。'
          '这是站点的防护策略，不是 App 故障，请稍后重试或更换站点。';
    }
    if (e is DioException) {
      final code = e.response?.statusCode;
      if (code != null) {
        if (code == 404) return '视频页面不存在（HTTP 404），可能已被删除';
        if (code == 429) return '请求过于频繁（HTTP 429），请稍后再试';
        if (code >= 500) return '站点服务器异常（HTTP $code），请稍后再试';
        return '站点拒绝了请求（HTTP $code）';
      }
      final t = e.type;
      if (t == DioExceptionType.connectionTimeout ||
          t == DioExceptionType.receiveTimeout ||
          t == DioExceptionType.sendTimeout) {
        return '请求超时，请检查网络后重试';
      }
      if (t == DioExceptionType.connectionError) {
        return '网络连接失败，请检查网络或代理设置';
      }
    }
    return '获取视频地址失败，可能是站点改版或该视频已下架';
  }

  // ==================== 下载 ====================

  /// 下载视频
  ///
  /// [ctrl] 可由调用方先行创建并挂好 onProgress / onOverallProgress，
  /// 再传进来；不传时内部自建一份（旧调用方式仍然可用）。
  /// 关键点：调用方拿到的那份句柄，必须就是本次下载真正在用的那份，
  /// 否则回调会被挂到一个永远不会被触发的句柄上。
  Future<bool> downloadVideo(VideoInfo video, String savePath,
      {DownloadControl? ctrl}) async {
    // 本次下载独占的控制句柄：暂停/停止/进度回调都挂在它上面，
    // 避免与并发的其它任务互相干扰。
    final handle = ctrl ?? beginDownload();
    return runWithControl(
        handle, () => _downloadVideoInner(video, savePath, handle));
  }

  Future<bool> _downloadVideoInner(
      VideoInfo video, String savePath, DownloadControl ctrl) async {
    if (video.m3u8Url == null) {
      // 先获取 m3u8 地址
      final detail = await getVideoDetail(video);
      if (detail == null || detail.m3u8Url == null) {
        ctrl.onLog?.call('获取视频地址失败', 'error');
        // 优先用解析阶段记录的真实原因（Cloudflare 验证 / 404 / 超时…），
        // 而不是一律甩给用户一句「站点改版或已下架」。
        final reason = lastDetailError;
        String message;
        if (lastDetailBlockedByChallenge) {
          message = '站点要求人机验证，暂时无法解析该视频（稍后重试或更换站点）';
        } else if (reason != null && reason.isNotEmpty) {
          message = reason;
        } else {
          message = '获取视频地址失败，可能是站点改版或该视频已下架';
        }
        ctrl.failureReason = message;
        ctrl.retryable = !lastDetailBlockedByChallenge;
        return false;
      }
      video = detail;
    }
    
    // 兜底改写：重试续传时 m3u8Url 可能来自任务里保存的旧地址，
    // 用户切换线路后应当按新线路走。
    // 老任务在数据库里可能存着协议相对地址（//cdn.../index.m3u8），
    // 不补 scheme 会让 Dio 在 Uri.parse 阶段抛 Unsupported scheme ''。
    var videoUrl = applyCdnHost(
        CrawlerConfig.resolveAbsoluteUrl(baseUrl, video.m3u8Url!));
    
    // 检查是否是直接 MP4 链接（porn91 等站点使用）
    final isDirectMp4 = videoUrl.endsWith('.mp4') || videoUrl.contains('.mp4?');
    
    if (isDirectMp4) {
      // 直接下载 MP4 文件
      return await _downloadDirectMp4(video, videoUrl, savePath, ctrl);
    }
    
    ctrl.onLog?.call('开始下载: ${video.title}', 'info');
    
    
    try {
      // 下载 m3u8 文件（禁用缓存）
      final m3u8Resp = await _dio.get(
        videoUrl,
        options: _noCacheOptions.copyWith(
          receiveTimeout: const Duration(minutes: 2),
        ),
      );
      final m3u8Content = m3u8Resp.data.toString();
      
      // 九色系：先看播放列表本身是不是「样片/占位」。
      // 站点的 VIP 视频未登录时无论从哪条路拿地址，播放列表都只有同一段：
      //   - 12 秒样片（12 个切片、总字节恒为 15,847,272）
      //   - 6 秒占位（单片 index0.ts?__vnotice=1002、91,932 字节）
      // 这两种下载下来对任何视频都一模一样，正是用户反馈的
      //「下的两个视频点进去内容相同」。宁可明确失败，也不给一份假文件。
      if (_siteType == 'jiuse') {
        if (CrawlerConfig.jiusePlaylistIsPlaceholder(m3u8Content)) {
          ctrl.onLog?.call('该视频为 VIP 专属，未登录只能拿到占位片段', 'error');
          ctrl.failureReason = '该视频需要 VIP 登录才能下载（未登录只能拿到占位片段）';
          ctrl.retryable = false;
          return false;
        }
        if (CrawlerConfig.jiusePlaylistIsSample(m3u8Content)) {
          ctrl.onLog?.call('只拿到站点公开的 12 秒试看片段，不是完整视频', 'error');
          ctrl.failureReason = '只拿到 12 秒试看片段（所有视频都是同一段），完整地址需要 VIP 登录';
          ctrl.retryable = false;
          return false;
        }
        // 第三种假片源：地址形态和播放列表结构都「正常」，
        // 但它是站点给未登录用户统一发的降级片源——多条不同视频下下来
        // 逐字节相同。这类片源只能靠时长识别：站点自报几分钟，
        // 播放列表却只有几十秒。宁可明确失败，也不给用户一份假文件。
        // 唯一失败模式的提示要写清是「站点限制」，别让用户以为是本地问题。
        if (CrawlerConfig.jiusePlaylistDurationMismatch(
                m3u8Content, video.duration) ==
            true) {
          final declared = CrawlerConfig.parseDurationSeconds(video.duration);
          final actual =
              CrawlerConfig.playlistDurationSeconds(m3u8Content).round();
          ctrl.onLog?.call(
              '播放列表只有 ${actual}s，与站点标注的 ${declared}s 不符', 'error');
          ctrl.failureReason =
              '站点只返回了 ${actual} 秒的降级片源（标注 ${declared} 秒，多个视频会是同一份），'
              '完整片源需要 VIP 登录';
          ctrl.retryable = false;
          return false;
        }
      }

      // 解析 TS 切片列表
      // 加密流必须在动手下载前拦住：不做解密的拼接结果一定是坏文件，
      // 而失败要趁早，不能让用户等下载完才发现播不了。
      if (_isEncryptedM3u8(m3u8Content)) {
        ctrl.onLog?.call('该视频受加密保护（AES-128），暂不支持下载', 'error');
        ctrl.failureReason = '该视频受加密保护，暂不支持下载';
        return false;
      }

      // m3u8 里的切片可能是绝对地址（指回默认线路），同样按选定线路改写。
      final tsUrls =
          _parseM3u8(m3u8Content, videoUrl).map(applyCdnHost).toList();
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
      
      // 协议相对地址（//cdn.../seg0.ts）必须补 scheme：
      // 否则会被当成站内路径拼成 https://站域名//cdn...，必然 404。
      if (line.startsWith('//')) {
        urls.add('https:$line');
      } else if (line.startsWith('http')) {
        urls.add(line);
      } else if (line.startsWith('/')) {
        // 以单斜杠开头是「站根相对」，要保留 m3u8 的 host，
        // 不能直接拼目录（会得到 .../hlsd/js10//hlsd/a.ts 这种双斜杠地址）
        final base = Uri.tryParse(baseUrl);
        if (base != null && base.hasScheme && base.host.isNotEmpty) {
          urls.add('${base.scheme}://${base.host}$line');
        } else {
          final dir = baseUrl.substring(0, baseUrl.lastIndexOf('/') + 1);
          urls.add('$dir$line');
        }
      } else {
        // 纯相对路径：拼到 m3u8 所在目录
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
        // 复用的前提：长度是 188 的整数倍（TS 包长固定 188）且首字节是 0x47。
        // 只看首字节不够：上一次下到一半被杀、或中间混进了一段 HTML 错误页，
        // 文件同样以 0x47 开头，但长度不是 188 的整数倍，
        // 复用它合并出来的成品就是整体错位的花屏文件。
        if (len >= 188 && len % 188 == 0) {
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
            // 切片单个体积不大，但热门站点高峰期首包可能很慢，
            // 30 秒的全局超时容易误杀，这里放宽到 2 分钟。
            receiveTimeout: const Duration(minutes: 2),
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

        // ✅ 完整性校验4：长度必须是 188 的整数倍
        //
        // TS 是定长包格式，一个完整切片的字节数必然是 188 的倍数。
        // 站点被风控拦截时会把 HTML 报错页混进响应体（状态码仍是 200），
        // 这种「首字节碰巧检查不到、中间却多出几字节」的数据如果被落盘并合并，
        // 成品就会从该切片之后整体错位——用户看到的是能生成文件、
        // 大小也正常，但播放器黑屏或花屏。宁可重试，也不写坏数据。
        if (bytes.length % 188 != 0) {
          Logger().logSync('Download',
              'TS切片长度不是 188 的整数倍: ${bytes.length} bytes (余 ${bytes.length % 188}), URL: $url');
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

  /// 直链 MP4 下载用的独立 Dio。
  ///
  /// 不复用 [_dio] 有两个原因：
  /// 1. 页面请求带的是「文档导航」请求头（Accept: text/html、
  ///    Sec-Fetch-Dest: document、Cookie、Upgrade-Insecure-Requests）。
  ///    实测把这些头带去媒体 CDN 会有一半概率在 1 秒内被服务器直接掐断
  ///    （模拟器 curl 复现：只带 Sec-Fetch-* 或 Sec-CH-UA* 时收到
  ///    `Empty reply from server`）。媒体文件只需要 UA + Accept: */*。
  /// 2. 页面请求与媒体请求共用连接池时，一条被挂住的媒体连接会拖住
  ///    后续所有页面请求。
  Dio get _mediaDio {
    final existing = _mediaDownloadDio;
    if (existing != null) return existing;
    final ua = CrawlerConfig.getHeaders(_siteType)["User-Agent"] ?? "";
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: CrawlerConfig.connectTimeout),
      receiveTimeout: const Duration(minutes: 10),
      headers: {
        "User-Agent": ua,
        "Accept": "*/*",
        // 分段下载必须拿原始字节：gzip 后的字节数与 Content-Range
        // 对不上，按偏移续传会错位。
        "Accept-Encoding": "identity",
        "Referer": "$baseUrl/",
      },
      followRedirects: true,
      receiveDataWhenStatusError: false,
      extra: {"cache": false},
    ));
    // 媒体请求同样进 [Net] 日志，否则下载失败时看不出到底请求了什么。
    dio.interceptors.add(NetworkLogInterceptor(name: "$_siteType-media"));
    _mediaDownloadDio = dio;
    return dio;
  }
  Dio? _mediaDownloadDio;

  /// 直接下载 MP4 文件（用于 porn91 等提供直链的站点）
  ///
  /// 不用 dio.download 的三个原因（历史遗留）：默认 FileAccessMode.write 会
  /// 截断续传文件、拿到响应头就开始写盘会把 HTML 错误页存成 .mp4、
  /// 没有 CancelToken 导致暂停/停止对已开始的下载完全无效。
  ///
  /// 为什么是「分段 Range」而不是「一条连接读到尾」：
  /// 真机日志（1.6.0 / Android 16）里每一条 MP4 GET 都在 45 秒停滞看门狗
  /// 触发时一个字节都没收到，4 个任务全部 0.0% 失败；而同一个地址在别处
  /// 3 秒就能取到 1 MB。对 la.btc620.com 实测：
  ///   bare GET（不带 Range）        -> 45 秒 0 字节（真机）
  ///   GET + Range: bytes=0-1048575 -> 206 / 1048576 B / 3.0 秒，连续 6 次全中
  /// 即「长连接大流量 GET」会被挂住，「短小的带 Range 请求」稳定。
  /// 分段还有附带好处：一段废了只损失这一段，换条连接从同一偏移续上，
  /// 进度只增不减，不会再出现「卡在某个百分比不动」。
  Future<bool> _downloadDirectMp4(
      VideoInfo video, String mp4Url, String savePath,
      DownloadControl ctrl) async {
    ctrl.onLog?.call("开始下载 MP4: ${video.title}", "info");
    ctrl.onLog?.call("MP4 URL: $mp4Url", "debug");

    final dio = _mediaDio;

    // 直链下载同样要把字节数上报给 onOverallProgress，
    // 否则 DownloadTask 拿不到速度（downloadSpeed 恒为 0 → 界面不显示速度）。
    DateTime? lastSpeedReport;
    const speedReportIntervalMs = 300; // 节流，避免高频刷新界面
    void reportBytes(int downloaded, int total) {
      final now = DateTime.now();
      final due = lastSpeedReport == null ||
          now.difference(lastSpeedReport!).inMilliseconds >=
              speedReportIntervalMs;
      if (!due) return;
      lastSpeedReport = now;
      ctrl.receivedBytes = downloaded;
      ctrl.onOverallProgress?.call(downloaded, total);
    }

    // ── 断点续传 ──
    // 先下到 .part，成功后原子改名；失败保留 .part 供下次续传。
    final partFile = File("$savePath.part");
    var alreadyBytes = 0;
    if (await partFile.exists()) {
      alreadyBytes = await partFile.length();
      if (alreadyBytes > 0) {
        ctrl.onLog?.call(
            "断点续传：已下载 ${(alreadyBytes / 1024 / 1024).toStringAsFixed(1)} MB",
            "info");
      }
    }

    // 每段 4 MB：在 300~500 KB/s 的线路上约 10 秒一段，
    // 一段被掐也只损失这一段的等待时间。
    const chunkSize = 4 * 1024 * 1024;
    const stallTimeout = Duration(seconds: 20); // 段内 20 秒无新字节就换连接
    const maxChunkRetries = 5; // 单个分块写盘失败的重试次数
    const maxAttempts = 1000; // 总请求次数上限（4MB/次≈4GB），防服务器异常时空转
    const maxIdleRounds = 24; // 连续这么多轮毫无进展才放弃

    var totalBytes = 0;
    var attempts = 0;
    var idleRounds = 0;
    var rangeSupported = true;
    var sizeLogged = false;

    while (true) {
      if (ctrl.isStopped) {
        ctrl.onLog?.call("下载已停止", "warn");
        ctrl.failureReason = "下载已停止";
        try {
          await partFile.delete();
        } catch (_) {}
        return false;
      }
      if (ctrl.isPaused) {
        final wantStop = await ctrl.awaitIfPaused();
        if (wantStop) {
          ctrl.failureReason = "下载已停止";
          try {
            await partFile.delete();
          } catch (_) {}
          return false;
        }
        idleRounds = 0; // 暂停不算失败，恢复后不消耗重试次数
      }

      if (totalBytes > 0 && alreadyBytes >= totalBytes) break;
      if (attempts >= maxAttempts) {
        final mb = (alreadyBytes / 1024 / 1024).toStringAsFixed(1);
        ctrl.failureReason = "下载多次中断（已下 $mb MB），重试会从断点继续";
        return false;
      }

      final start = alreadyBytes;
      final end = totalBytes > 0
          ? (start + chunkSize - 1).clamp(start, totalBytes - 1)
          : start + chunkSize - 1;
      final requestedLen = end - start + 1;

      attempts++;
      Timer? stallTimer;
      final cancelToken = CancelToken();
      RandomAccessFile? raf;
      var stopThisAttempt = false;
      var wroteThisAttempt = 0;

      // ── 停滞看门狗 ──
      // dio 的 receiveTimeout 是 10 分钟，CDN 掐连接时经常既不报错也不再
      // 吐数据，界面就会「进度不动、也不失败」地卡着。这里自己盯：
      // 20 秒没收到任何字节就掐掉本轮，立刻换一条连接从同一偏移续上。
      void armWatchdog() {
        stallTimer?.cancel();
        stallTimer = Timer(stallTimeout, () {
          if (!cancelToken.isCancelled) cancelToken.cancel("stalled");
        });
      }

      try {
        armWatchdog();
        final resp = await dio.get<ResponseBody>(
          mp4Url,
          options: Options(
            responseType: ResponseType.stream,
            headers: {
              "Accept": "*/*",
              "Accept-Encoding": "identity",
              if (rangeSupported) "Range": "bytes=$start-$end",
            },
            receiveTimeout: const Duration(minutes: 10),
            sendTimeout: const Duration(seconds: 10),
          ),
          cancelToken: cancelToken,
        );

        final status = resp.statusCode ?? 0;
        final lengthHeader =
            int.tryParse(resp.headers.value("content-length") ?? "0") ?? 0;
        final contentType =
            (resp.headers.value("content-type") ?? "").toLowerCase();
        final contentRange = resp.headers.value("content-range");

        var resumed = status == 206 && start > 0;

        if (status != 206) {
          // 服务器忽略了 Range（或本来就不支持）：body 从第 0 字节开始，
          // 前面已下的部分必须丢掉重写，否则会接成半截文件。
          if (start > 0) {
            ctrl.onLog?.call("服务器忽略了 Range，从头重新下载", "warn");
          }
          rangeSupported = false;
          resumed = false;
          alreadyBytes = 0;
          try {
            if (await partFile.exists()) await partFile.delete();
          } catch (_) {}
          if (lengthHeader > 0) totalBytes = lengthHeader;
        } else {
          final rangeTotal = _contentRangeTotal(contentRange);
          if (rangeTotal != null && rangeTotal > 0) {
            totalBytes = rangeTotal;
          } else if (lengthHeader > 0 && totalBytes <= 0) {
            totalBytes = start + lengthHeader;
          }
          // 本地残留的 .part 比服务器上的文件还大（站点换源或上次写坏），
          // 继续按偏移续传只会一直 416，只能重来。
          if (totalBytes > 0 && alreadyBytes > totalBytes) {
            ctrl.onLog?.call("本地临时文件大于服务器文件，重新下载", "warn");
            try {
              await partFile.delete();
            } catch (_) {}
            alreadyBytes = 0;
            resumed = false;
          }
        }

        if (totalBytes > 0 && !sizeLogged) {
          sizeLogged = true;
          ctrl.onLog?.call(
              "文件大小: ${(totalBytes / 1024 / 1024).toStringAsFixed(2)} MB",
              "info");
        }

        final file = await partFile
            .open(mode: resumed ? FileMode.append : FileMode.write);
        raf = file;

        var headChecked = resumed;
        await for (final chunk in resp.data!.stream) {
          armWatchdog();
          if (ctrl.isStopped) {
            stopThisAttempt = true;
            break;
          }
          if (ctrl.isPaused) {
            // 暂停期间本来就收不到数据，别让看门狗把这条连接掐掉
            stallTimer?.cancel();
            final wantStop = await ctrl.awaitIfPaused();
            if (wantStop) {
              stopThisAttempt = true;
              break;
            }
            armWatchdog();
          }

          if (!headChecked && chunk.isNotEmpty) {
            headChecked = true;
            // 拿到第一段就先判断这到底是不是视频：
            // 签名过期或触发风控时站点会回 200 + 一个 HTML 页面，
            // 旧实现会把它原样存成 .mp4，任务显示「下载完成」但文件放不出来。
            //
            // 判据必须是「像文本」而不是「首字符是 < 或 {」：视频头几个字节
            // 完全可能是随机的 { 或 <，只看首字符会把正常片子误杀。
            final head = chunk.take(512).toList();
            var printable = 0;
            for (final b in head) {
              if ((b >= 32 && b < 127) || b == 9 || b == 10 || b == 13) {
                printable++;
              }
            }
            // 页面正文里只要有中文（UTF-8 三字节），可打印字符比例就会掉到
            // 0.4 左右，所以不能只靠比例；再补一条「content-type 说是文本
            // 且首字符是 < 或 {」的判定，两者取并集。
            final looksText =
                head.length >= 16 && printable / head.length > 0.9;
            final textType = contentType.contains("text/html") ||
                contentType.contains("application/json") ||
                contentType.contains("text/plain");
            final preview = String.fromCharCodes(
                head.take(120).map((b) => (b >= 32 && b < 127) ? b : 32));
            final lower = preview.toLowerCase().trimLeft();
            final looksMarkup =
                lower.startsWith("<") || lower.startsWith("{");
            if (looksText || (textType && looksMarkup)) {
              ctrl.onLog?.call("服务器返回的是网页而不是视频: $preview", "error");
              ctrl.failureReason = "站点返回的是网页而不是视频文件（链接已失效或被风控拦截）。"
                  "请重试；若一直失败，到设置里把播放节点切回「自动（跟随站点）」。";
              ctrl.retryable = false;
              await file.close();
              raf = null;
              if (!resumed) {
                try {
                  await partFile.delete();
                } catch (_) {}
              }
              return false;
            }
          }

          // 分块写盘：偶发的一次写入失败不该整单作废，重试几次再往上抛。
          var written = false;
          for (var i = 0; i < maxChunkRetries; i++) {
            try {
              await file.writeFrom(chunk);
              written = true;
              break;
            } catch (e) {
              ctrl.onLog?.call("写入分块失败（第 ${i + 1} 次）: $e", "warn");
              await Future.delayed(Duration(milliseconds: 200 * (i + 1)));
            }
          }
          if (!written) {
            throw FileSystemException("分块写入磁盘失败", partFile.path);
          }

          wroteThisAttempt += chunk.length;
          final overall = alreadyBytes + wroteThisAttempt;
          reportBytes(overall, totalBytes);
          if (totalBytes > 0) {
            final progress = (overall / totalBytes).clamp(0.0, 1.0);
            final downloadedMB = (overall / 1024 / 1024).toStringAsFixed(1);
            final totalMB = (totalBytes / 1024 / 1024).toStringAsFixed(1);
            ctrl.onProgress?.call(progress, "$downloadedMB/$totalMB MB");
          }
        }

        await file.close();
        raf = null;
      } catch (e) {
        if (raf != null) {
          try {
            await raf.close();
          } catch (_) {}
          raf = null;
        }
        // 把已写进 .part 的部分算进断点，下一轮从这里接着要
        try {
          if (await partFile.exists()) {
            final len = await partFile.length();
            if (len > alreadyBytes) alreadyBytes = len;
          }
        } catch (_) {}
        if (ctrl.isStopped) {
          ctrl.failureReason = "下载已停止";
          try {
            await partFile.delete();
          } catch (_) {}
          return false;
        }

        final code = e is DioException ? e.response?.statusCode : null;
        // 416 = 请求的偏移越过了文件末尾。通常是本地 .part 已经完整，
        // 或者服务器上的文件变了。用响应里的 Content-Range 校正总长度。
        if (code == 416) {
          final rangeHeader =
              e is DioException ? e.response?.headers.value("content-range") : null;
          final realTotal = _contentRangeTotal(rangeHeader);
          if (realTotal != null && realTotal > 0) {
            totalBytes = realTotal;
            if (alreadyBytes >= realTotal) break;
          }
          ctrl.onLog?.call("请求偏移越界（416），重新下载", "warn");
          try {
            await partFile.delete();
          } catch (_) {}
          alreadyBytes = 0;
          continue;
        }
        // 4xx（签名过期 / 无权限 / 文件没了）重连没有意义，直接给出原因。
        if (code != null && code >= 400 && code < 500) {
          final msg = _describeDirectDownloadError(e);
          ctrl.onLog?.call("下载失败: $msg", "error");
          ctrl.failureReason = msg;
          return false;
        }

        final progressed = alreadyBytes > start;
        if (progressed) {
          idleRounds = 0;
        } else {
          idleRounds++;
        }
        // 看门狗主动断开也是一种「中断」，文案不能套用 dio 的
        // 「The request was manually cancelled by the user」，
        // 否则用户看到的会是莫名其妙的一句话。
        final stalled =
            e is DioException && e.type == DioExceptionType.cancel;
        if (stalled) {
          ctrl.onLog?.call(
              "${stallTimeout.inSeconds}s 没收到任何数据，正在换一条连接继续",
              "warn");
        }
        if (idleRounds >= maxIdleRounds) {
          final msg = stalled
              ? "线路长时间不返回数据（停滞不动），请换播放节点或稍后重试"
              : _describeDirectDownloadError(e);
          ctrl.onLog?.call(
              "连续 $maxIdleRounds 轮没取到数据，停止重连: $msg", "error");
          final mb = (alreadyBytes / 1024 / 1024).toStringAsFixed(1);
          ctrl.failureReason = "$msg（已下载 $mb MB，重试会从断点继续）";
          return false;
        }

        var waitSeconds = progressed ? 1 : 2;
        if (stalled) waitSeconds = 0; // 停滞多半是这条连接废了，立刻换一条
        if (waitSeconds > 0) {
          await Future.delayed(Duration(seconds: waitSeconds));
        }
        continue;
      } finally {
        stallTimer?.cancel();
        stallTimer = null;
      }

      if (stopThisAttempt) {
        if (ctrl.isStopped) {
          ctrl.onLog?.call("下载已停止", "warn");
          ctrl.failureReason = "下载已停止";
          try {
            await partFile.delete();
          } catch (_) {}
        } else {
          try {
            if (await partFile.exists()) {
              final len = await partFile.length();
              if (len > alreadyBytes) alreadyBytes = len;
            }
          } catch (_) {}
          final mb = (alreadyBytes / 1024 / 1024).toStringAsFixed(1);
          ctrl.onLog?.call("已暂停，已保留 $mb MB，恢复后可续传", "info");
          ctrl.failureReason = "已暂停";
        }
        return false;
      }

      // 这一轮正常结束：把落盘长度同步为断点
      try {
        if (await partFile.exists()) {
          final len = await partFile.length();
          if (len > alreadyBytes) alreadyBytes = len;
        }
      } catch (_) {}

      if (totalBytes > 0 && alreadyBytes >= totalBytes) break;

      // 不知道总长度时（服务器既不给 Content-Range 也不给 Content-Length）：
      // 整文件那条路读完即完成；分段路则「本段没要满」视为文件结束。
      if (totalBytes <= 0) {
        if (!rangeSupported) break;
        if (wroteThisAttempt < requestedLen) break;
      }

      final progressed = alreadyBytes > start;
      if (progressed) {
        idleRounds = 0;
      } else {
        idleRounds++;
        if (idleRounds >= maxIdleRounds) {
          final mb = (alreadyBytes / 1024 / 1024).toStringAsFixed(1);
          ctrl.failureReason =
              "下载中断（$mb MB 后长时间取不到数据），重试会从断点继续";
          return false;
        }
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    // 下载完成：原子改名到最终路径
    await partFile.rename(savePath);
    await _saveToHistory(video, savePath);
    ctrl.onLog?.call("下载完成: ${video.title}", "info");
    return true;
  }

  /// 从 Content-Range 头里取文件总长度
  ///
  /// 形如 `bytes 0-1048575/16776721`（206）或 `bytes */16776721`（416）。
  /// 这个数字比 HEAD 的 Content-Length 可靠得多：HEAD 走的是同一条会被
  /// 挂住的连接，实测同一地址两次 HEAD 报过 16.00 MB 与 3.24 MB，
  /// 而且一个 HEAD 就能让任务白等 30~52 秒。
  static int? _contentRangeTotal(String? value) {
    if (value == null || value.isEmpty) return null;
    final slash = value.lastIndexOf("/");
    if (slash < 0 || slash == value.length - 1) return null;
    return int.tryParse(value.substring(slash + 1).trim());
  }

  /// 把直链下载的异常翻译成人能看懂的一句话
  String _describeDirectDownloadError(Object e) {
    if (e is DioException) {
      final code = e.response?.statusCode;
      if (code == 403) {
        return '服务器拒绝访问（403）：porn91 的视频地址带时效签名，'
            '签名只在签发它的那条线路上有效。请到设置里把播放节点切回'
            '「自动（跟随站点）」后重试。';
      }
      if (code == 404) return '视频文件不存在（404），可能已被站点删除';
      if (code != null) return '服务器返回 HTTP $code';
      if (e.type == DioExceptionType.receiveTimeout) {
        return '接收数据超时，线路太慢或被限速；重试会从断点继续';
      }
      if (e.type == DioExceptionType.connectionTimeout) {
        return '连接服务器超时，请检查网络或更换播放节点';
      }
      if (e.type == DioExceptionType.connectionError) {
        return '连接不上服务器（${e.message ?? e}），请检查网络或更换播放节点';
      }
    }
    return '下载失败: $e';
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
  ///
  /// [newSiteType] 传入时表示用户手动归类（自定义站点），传 null 则回到
  /// 按域名推断。
  void changeSite(String newBaseUrl, {String? newSiteType}) {
    baseUrl = newBaseUrl;
    _manualSiteType =
        newSiteType != null ? CrawlerConfig.normalizeSiteType(newSiteType) : null;
    // 先检测新站点类型（_initDio 内部依赖 _siteType 选择请求头）
    _detectSiteType();
    // 清除旧站点的 Cookie，避免跨站点干扰（特别是从 original 切到 porn91 时）
    _dio.options.headers.remove('Cookie');
    // 媒体下载 Dio 单独持有旧站点的 UA / Referer，换站点必须一并丢弃重建
    _mediaDownloadDio?.close(force: true);
    _mediaDownloadDio = null;
    // 再用新站点类型初始化请求头
    _initDio();
  }
}
