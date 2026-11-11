/// 爬虫核心类
/// 严格参照 Python 版本 _src/lib/__init__.py

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max, min;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'config.dart';
import 'sites/site_handler.dart';
import 'sites/porn91_site.dart';
import 'sites/jiuse_site.dart';
import 'sites/hifuli_site.dart';
import 'sites/original_site.dart';
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

/// 「强制合并」的结果
///
/// 合并是下载收尾的一步，成败只需要一句话 + 是否需要提示用户，
/// 单独建模比抛异常好处理（UI 侧直接弹提示即可）。
class ForceMergeResult {
  const ForceMergeResult(this.ok, this.message, [this.filePath]);

  /// 是否合并成功
  final bool ok;

  /// 给用户看的一句话（失败时就是原因）
  final String message;

  /// 成功时的最终文件路径
  final String? filePath;
}

/// 直链 MP4 单块一次请求的结果（[_fetchMp4ChunkOnce] 永不抛出，全部折算成结果）
enum _Mp4ChunkKind {
  done, // 本块拿满（或未知总长的串行块正常读到 EOF）
  partial, // 连接提前断流但有字节落盘，整块重下
  stalled, // 看门狗掐掉：20 秒零字节，应当场换连接重试
  failed, // 其它网络错误，退避后重试
  fatal, // 4xx / HTML 嗅探命中等，重试无意义
  rangeLost, // 服务器开始忽略 Range（响应 200），必须退回单连接从头下
  replan, // 416 且响应带了新的文件总长，需要按新总长重排
}

class _Mp4ChunkOutcome {
  const _Mp4ChunkOutcome(
    this.kind, {
    this.newTotal,
    this.message,
    this.bytesWritten = 0,
    this.retryable = true,
  });

  final _Mp4ChunkKind kind;

  /// replan：服务器上的新文件总长
  final int? newTotal;

  /// fatal：给用户看的失败原因
  final String? message;

  /// partial：本次尝试已落盘的字节数
  final int bytesWritten;

  /// fatal：是否值得重试（HTML 嗅探命中 → false）
  final bool retryable;
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

  /// MP4 直连分块的并发数，与 TS 切片并发分开可调。
  ///
  /// 两类下载的特性完全不同：TS 切片是几百 KB 的独立文件，靠请求数堆速度；
  /// MP4 每块 256 KB~1 MB 且带 Range 头，CDN 按连接分配配额，
  /// 两者用同一个数字时会互相迁就（调高切片并发会连带把 MP4 的块切得过碎）。
  /// 默认值与切片并发一致，用户不改就还是老行为。
  int _mp4MaxConcurrentDownloads = 32;
  set mp4MaxConcurrentDownloads(int value) =>
      _mp4MaxConcurrentDownloads = value.clamp(1, 64);
  int get mp4MaxConcurrentDownloads => _mp4MaxConcurrentDownloads;
  
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

  /// 该任务当前残留的可合并临时目录：'mp4' / 'ts' / null
  ///
  /// 两种临时目录都由 savePath 派生（见 _downloadDirectMp4 / _downloadTs），
  /// 所以只看目录在不在，就能判断「有没有下了一半的切片可以救」。
  Future<String?> pendingTempKind(String savePath) async {
    if (await Directory("$savePath.chunks").exists()) return 'mp4';
    if (await Directory("${savePath}_temp").exists()) return 'ts';
    return null;
  }

  /// 同步版：列表每帧都要判断一次按钮是否显示，走 IO 的 Future 太贵
  ///
  /// 只做两次 existsSync（stat 系统调用），对一屏十几个任务来说开销可忽略。
  String? pendingTempKindSync(String savePath) {
    try {
      if (Directory("$savePath.chunks").existsSync()) return 'mp4';
      if (Directory("${savePath}_temp").existsSync()) return 'ts';
    } catch (_) {}
    return null;
  }

  /// 用户主动触发的「强制合并」：把已下好的切片拼成最终文件。
  ///
  /// 正常流程里合并是下载的收尾步骤，只有全部切片到位才会跑。但有两种
  /// 情况需要它：① 切片早已下完，合并那一步被系统杀掉，任务停在失败态；
  /// ② 少量切片反复失败，用户不想再等，愿意接受不完整的文件。
  /// 因此这里不复用下载时的 downloaded 位图，直接扫目录按序号拼。
  Future<ForceMergeResult> forceMerge(
    String savePath,
    VideoInfo video,
    DownloadControl ctrl, {
    bool allowIncomplete = false,
  }) async {
    final kind = await pendingTempKind(savePath);
    if (kind == null) {
      return const ForceMergeResult(
          false, '没有找到未合并的切片目录，可能已经合并过了');
    }

    if (kind == 'ts') {
      final tempDir = Directory("${savePath}_temp");
      ctrl.onLog?.call('强制合并 TS 切片：${tempDir.path}', 'info');
      final ok = await _mergeTsFiles(tempDir.path, savePath, null, ctrl);
      if (!ok) {
        return const ForceMergeResult(false, '合并失败：切片目录里没有可用的数据');
      }
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    } else {
      final result =
          await _forceMergeMp4(savePath, ctrl, allowIncomplete: allowIncomplete);
      if (!result.ok) return result;
    }

    await _saveToHistory(video, savePath);
    ctrl.onLog?.call('强制合并完成: ${video.title}', 'info');
    return ForceMergeResult(true, '已合并为视频文件', savePath);
  }

  /// MP4 分块的强制合并：先盘点块文件，再交给 _mergeMp4Chunks 逐块拼接。
  ///
  /// 默认要求「不缺块、长度符合网格」，否则拒绝合并——拼一个中间空一段的
  /// 文件只会播放到断点就花屏，还不如提示用户先补齐。
  /// allowIncomplete 为 true 时跳过全部校验，按现有块顺序硬拼。
  Future<ForceMergeResult> _forceMergeMp4(
    String savePath,
    DownloadControl ctrl, {
    bool allowIncomplete = false,
  }) async {
    final partDir = Directory("$savePath.chunks");

    // meta.json 记着下载时的总长与块长，用来判断每块是否完整
    var total = 0;
    var chunkLen = 0;
    try {
      final meta = File("${partDir.path}/meta.json");
      if (await meta.exists()) {
        final decoded = jsonDecode(await meta.readAsString());
        if (decoded is Map) {
          final t = decoded["total"];
          final c = decoded["chunkLen"];
          if (t is num) total = t.toInt();
          if (c is num) chunkLen = c.toInt();
        }
      }
    } catch (_) {}

    final chunkPattern = RegExp(r'chunk_(\d+)$');
    final files = <int, File>{};
    await for (final entity in partDir.list()) {
      if (entity is! File) continue;
      final segments = entity.uri.pathSegments;
      final name = segments.isEmpty ? entity.path : segments.last;
      final match = chunkPattern.firstMatch(name);
      if (match == null) continue;
      final idx = int.tryParse(match.group(1) ?? '');
      if (idx == null) continue;
      files[idx] = entity;
    }
    if (files.isEmpty) {
      return const ForceMergeResult(false, '分块目录里没有块文件');
    }

    final count = files.keys.reduce(max) + 1;
    final expectedLens = List<int>.filled(count, 0);
    final missing = <int>[];
    final mismatched = <int>[];
    for (var i = 0; i < count; i++) {
      final file = files[i];
      if (file == null) {
        missing.add(i);
        continue;
      }
      final len = await file.length();
      expectedLens[i] = len;
      if (chunkLen > 0 && total > 0) {
        final expect = _mp4ExpectedLen(i, chunkLen, total);
        if (expect > 0 && len != expect) mismatched.add(i);
      }
    }

    if (!allowIncomplete && (missing.isNotEmpty || mismatched.isNotEmpty)) {
      final detail = StringBuffer('分块不完整：共 $count 块');
      if (missing.isNotEmpty) {
        detail.write('，缺 ${missing.length} 块（如 #${missing.first + 1}）');
      }
      if (mismatched.isNotEmpty) {
        detail.write(
            '，有 ${mismatched.length} 块长度不符（如 #${mismatched.first + 1}）');
      }
      detail.write('。可继续下载补齐后再合并');
      return ForceMergeResult(false, detail.toString());
    }

    ctrl.onLog?.call('强制合并 MP4 分块：$count 块', 'info');
    final ok = await _mergeMp4Chunks(
      partDir,
      allowIncomplete ? List<int>.filled(count, 0) : expectedLens,
      savePath,
      ctrl,
    );
    if (!ok) return const ForceMergeResult(false, '合并失败，详见日志');
    return ForceMergeResult(true, 'MP4 分块已合并', savePath);
  }

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

  /// 站点差异（URL 拼装 / HTML 解析 / 分页判据）全部委托给这个 handler。
  ///
  /// 它只做纯字符串处理、不发 HTTP，所以每个站点可以单独读、单独改、
  /// 单独测；网络、分页状态与下载仍集中在 CrawlerCore。
  SiteHandler _handler = const OriginalSite();

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
    _handler = _resolveHandler(_siteType);
    Logger().logSync(
        'Crawler',
        '站点类型检测: domain=${Uri.parse(baseUrl).host}, type=$_siteType'
        '${_manualSiteType != null ? ' (手动指定)' : ''}');
  }

  /// 按站点类型取对应的实现；未知类型一律落到通用原创系模板
  static SiteHandler _resolveHandler(String siteType) {
    switch (siteType) {
      case 'porn91':
        return const Porn91Site();
      case 'jiuse':
        return const JiuseSite();
      case 'hifuli':
        return const HifuliSite();
      default:
        return const OriginalSite();
    }
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
  /// 站点各有一套分页控件（jiuse 是路径式页码链接、hifuli 是 data-next-url、
  /// 其余是页码 +「下一页」），具体判据由 handler 提供；handler 说自己
  /// 没有判据（返回 null）时才退回通用的「分页控件 + 条数兜底」。
  void _applyPagination(String html, int page, List<VideoInfo> videos) {
    final signature = videos.map((v) => v.id).join(',');
    final bySite = _handler.decidePagination(
      html: html,
      page: page,
      itemCount: videos.length,
      signature: signature,
      lastSignature: _lastJiuseSignature,
    );
    if (bySite != null) {
      _lastPaginationParsed = bySite.parsed;
      _lastRequestHasMore = bySite.hasMore;
      if (bySite.rememberSignature) _lastJiuseSignature = signature;
      _logPagination(bySite.log, bySite.hasMore);
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
    
    // 分页格式各站不同（jiuse 路径式、hifuli 单页信息流、其余占位符），
    // 交给站点类拼；防缓存时间戳只有 porn91 需要。
    final url = _handler.buildListUrl(baseUrl, urlPattern, page);
    final ts = DateTime.now().millisecondsSinceEpoch;
    final urlWithCache = _handler.addCacheBuster
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
      
      // 四套 DOM 的差异留在各自的 site 文件里
      final videos = _handler.parseVideoList(html, baseUrl);
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

  /// 供测试直接调用 jiuse 列表解析（解析器已搬到 sites/jiuse_site.dart）
  @visibleForTesting
  List<VideoInfo> parseJiuseListForTest(String html) =>
      const JiuseSite().parseVideoList(html, baseUrl);

  /// 供测试直接调用嗨碰列表解析（解析器在 sites/hifuli_site.dart）
  @visibleForTesting
  List<VideoInfo> parseHifuliListForTest(String html) =>
      const HifuliSite().parseVideoList(html, baseUrl);

  /// 供测试直接调用嗨碰「从卡片提炼作者」的解析
  @visibleForTesting
  List<AuthorInfo> parseHifuliAuthorsForTest(String html) =>
      const HifuliSite().parseAuthors(html, baseUrl) ?? const <AuthorInfo>[];

  /// 供测试直接调用分页判据（jiuse 无分页控件，走条数 + 重复内容比对）
  @visibleForTesting
  void applyPaginationForTest(String html, int page, List<VideoInfo> videos) =>
      _applyPagination(html, page, videos);

  /// 供测试直接调用 m3u8 切片解析
  @visibleForTesting
  List<String> parseM3u8ForTest(String content, String baseUrl) =>
      _parseM3u8(content, baseUrl);

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
      
      // 四套 DOM 的差异留在各自的 site 文件里
      final videos = _handler.parseVideoList(html, baseUrl);
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
    // 各站的作者搜索入口不同（porn91 用 search_result.php、九色系与
    // 嗨碰共用 /search、原创系用 search.htm），URL 规则交给站点类。
    final url = _handler.buildAuthorSearchUrl(baseUrl, keyword);
    // ✅ 修复：搜索URL不再追加 _t 时间戳参数（与 searchVideos 保持一致）
    // 作者搜索 URL 同样是 search.htm，`&_t=` 与 `&sort=` 组合可能触发站点 404，
    // 防缓存已有 _noCacheOptions 兜底，因此不拼接 _t。
    final urlWithCache = url;
    
    // ✅ 修复：日志记录实际请求的 URL
    await logger.log('Crawler', '网络请求: 搜索作者 $urlWithCache');
    
    try {
      final resp = await _dio.get(urlWithCache, options: _noCacheOptions);
      final html = resp.data.toString();
      
      // 九色系的用户徽章、嗨碰的卡片 meta 行各有自己的解析；
      // 站点说自己没有专用解析（返回 null）时才走下面的通用正则。
      final bySite = _handler.parseAuthors(html, baseUrl);
      if (bySite != null) {
        await logger.log('Crawler', '$_siteType 作者搜索结果: ${bySite.length} 个');
        return bySite;
      }

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
    // 各站作者主页路径不同（porn91 /author.php、九色系 /author|dashen/xxx、
    // 嗨碰 /u/{名字}、原创系 user-N.htm），交给站点类拼。
    final url = _handler.buildAuthorUrl(baseUrl, authorId, page);
    // ✅ 修复：使用更轻量的参数格式
    final ts = DateTime.now().millisecondsSinceEpoch;
    // original 站点对 _t 参数敏感（首页/搜索带 _t 会 404），仅 porn91 保留 _t 防缓存
    final urlWithCache = _handler.addCacheBuster
        ? (url.contains('?') ? '$url&_t=$ts' : '$url?_t=$ts')
        : url;
    
    // ✅ 修复：日志记录实际请求的 URL
    await logger.log('Crawler', '网络请求: 获取作者视频 $urlWithCache (siteType=$_siteType)');
    
    try {
      final resp = await _dio.get(urlWithCache, options: _noCacheOptions);
      final html = resp.data.toString();
      
      final videos = _handler.parseVideoList(html, baseUrl);

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
      final urlWithCache = _handler.addCacheBuster
          ? (video.url.contains('?')
              ? '${video.url}&_t=$ts'
              : '${video.url}?_t=$ts')
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
      
      // ===== 站点差异交给 lib/crawler/sites/ 下各自的实现 =====
      //
      // porn91 的 strencode2 三部曲、九色系 video[data-src]、嗨碰的
      // HIPORN_WATCH / JSON-LD，都在站点类里；这里只取结果。
      final siteDetail = await _handler.extractDetail(html, video, baseUrl);
      String? videoUrl = siteDetail.videoUrl;
      final hipornTitle = siteDetail.title;
      final hipornAuthor = siteDetail.author;
      final hipornAuthorId = siteDetail.authorId;
      final hipornDuration = siteDetail.duration;
      final hipornDate = siteDetail.uploadDate;
      final hipornViews = siteDetail.views;

      // 九色系：data-src 有时指向站点内置的 12 秒样片（所有视频共用），
      // 真实地址要走站点的联网接口换，这一步需要发 HTTP，所以留在核心。
      if (siteDetail.needsRealUrl) {
        if (videoUrl != null) {
          await logger.log('Debug',
              'jiuse 命中站点样片地址（所有视频共用），尝试换真实地址');
        }
        var real = await _fetchJiuseRealUrl(baseUrl, html);
        if (real == null) {
          real = await _fetchJiuseEmbedUrl(baseUrl, video.id);
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

      // ===== 通用策略 (original CMS) =====
      if (videoUrl == null) {
        
        // 策略1: 从 <source> 标签提取 m3u8
        final sourceMatch = RegExp(r'''<source[^>]+src="([^"]+\.m3u8[^"]*)"''', caseSensitive: false).firstMatch(html);
        if (sourceMatch != null) {
          videoUrl = sourceMatch.group(1);
        }
        
        // 策略2: 搜索任何 .m3u8 URL
        if (videoUrl == null) {
          final m3u8Match = CrawlerConfig.m3u8Pattern.firstMatch(html);
          if (m3u8Match != null) {
            videoUrl = m3u8Match.group(1);
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
        // 去重：没连代理时整片视频的切片会齐齐失败，几百片 × 3 次重试
        // 就是上千行完全相同的报错，把真正有用的那几行全淹了。
        // key 用「主机 + 异常类型」，同一片源的失败聚合成一条 + 计数。
        Logger().logDeduped(
          'Download',
          '下载切片失败(retry ${retry + 1}): $e',
          level: LogLevel.warn,
          dedupeKey: 'seg|' +
              (Uri.tryParse(url)?.host ?? 'unknown') +
              '|' +
              e.runtimeType.toString(),
          offline: e is DioException &&
              (e.type == DioExceptionType.connectionError ||
                  e.type == DioExceptionType.connectionTimeout ||
                  e.type == DioExceptionType.receiveTimeout),
        );
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
  ///
  /// 为什么还要「多连接并发」（2026-11-12，修「卡 4 MB / 卡 70%」）：
  /// CDN 按「连接」给配额——单连接起步爆发 0.8~4 MB 后被压到 20~30 KB/s，
  /// 串行下载的上限就是单连接速度；第 1 个 4 MB 分块用完配额后，下一段
  /// 永远拿不到响应头，进度停在 4 MB；小文件单连接只能拿到全长的
  /// 70~80%，剩下的靠 1 KB/s 滴水。实测同一地址并发拉不同区间可以线性
  /// 叠加：×4=61.8、×8=125.2、×32=284.5 KB/s——这正是「迅雷能下、
  /// App 下不了」的全部差别。并发结构复用 HLS 切片的滑动窗口，并发度走
  /// [_maxConcurrentDownloads]（设置页「切片并发数」直接生效）。
  ///
  /// 分块落盘用「每块一个临时文件 + 完成后合并」（与 HLS 切片同一模式），
  /// 而不是 RandomAccessFile 定位写：dart:io 的 FileMode.append 是 O_APPEND
  ///（setPosition 会被忽略）、FileMode.write 打开即截断，都做不了
  /// 「续传时按偏移改写旧文件」；分块文件还天然规避多连接写盘冲突，
  /// 块文件长度本身就是续传进度，配 meta.json 记网格即可断点续传。
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

    // ── 临时目录：每块一个文件（与 HLS 切片同模式）──
    // 成功后合并、改名到最终路径；失败保留供续传。
    // 旧实现（v1.6.1 串行版）的 "$savePath.part" 单文件与新结构不兼容，
    // 见到就删：宁可整片重下，也不接出错位的文件。
    final partDir = Directory("$savePath.chunks");
    try {
      final legacy = File("$savePath.part");
      if (await legacy.exists()) await legacy.delete();
    } catch (_) {}

    // 单块 256 KB ~ 1 MB：
    // - 下限 256 KB：电脑端 32×256 KB 实测能线性叠满；且块越小越稳——
    //   CDN 每条连接先爆发 0.8~4 MB 再断流，块在爆发额度内必定拿满，
    //   不会出现「半块卡死、反复重试同一块」的空转。
    // - 上限 1 MB：控制单块的握手与重试成本。
    const chunkCap = 1024 * 1024;
    const chunkFloor = 256 * 1024;
    const stallTimeout = Duration(seconds: 20); // 块内 20 秒无新字节 → 掐掉换连接
    const maxIdleRounds = 24; // 连续这么多「零进展请求」才放弃

    // ── 分块网格与进度账本 ──
    var totalBytes = 0; // 0 = 还不知道（探测后回填）
    var chunkLen = 0; // 0 = 串行模式（单块、不带 Range，读到 EOF 为止）
    var chunkCount = 0;
    var chunkDone = <bool>[];
    var inflightBytes = <int>[]; // 每块本次尝试已落盘字节（进度瞬时值）
    var completedBytes = 0; // 已完成块的合计
    var received = 0; // 完成块 + 在途瞬时（真实账本，用于失败文案）
    var displayHigh = 0; // 界面进度只增不减：整块重试期间瞬时值回落，显示取历史高点

    void recalcReceived() {
      var sum = completedBytes;
      for (final b in inflightBytes) {
        sum += b;
      }
      received = sum;
    }

    void reportProgress() {
      if (received > displayHigh) displayHigh = received;
      reportBytes(displayHigh, totalBytes);
      if (totalBytes > 0) {
        final progress = (displayHigh / totalBytes).clamp(0.0, 1.0);
        ctrl.onProgress?.call(
            progress,
            "${(displayHigh / 1024 / 1024).toStringAsFixed(1)}/"
            "${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB");
      }
    }

    // ── 续传元数据：只记网格（total/chunkLen），块完成与否看块文件长度 ──
    var metaTotal = 0;
    var metaChunkLen = 0;
    try {
      final mf = File("${partDir.path}/meta.json");
      if (await mf.exists()) {
        final m = jsonDecode(await mf.readAsString()) as Map<String, dynamic>;
        metaTotal = (m["total"] as num?)?.toInt() ?? 0;
        metaChunkLen = (m["chunkLen"] as num?)?.toInt() ?? 0;
      }
    } catch (_) {
      metaTotal = 0;
      metaChunkLen = 0;
    }

    var sizeLogged = false;
    var rangeOk = true; // 服务器是否接受 Range（探测返回 200 时转串行）

    // ── 全局中止标记：任一 worker 置位后，其余 worker 与调度全部让路 ──
    String? fatalMsg;
    var fatalRetryable = true;
    var rangeLostFlag = false;
    var replanTotal = 0;
    var replanStreak = 0;
    final activeTokens = <CancelToken>{};
    void cancelAllActive() {
      for (final t in activeTokens.toList()) {
        if (!t.isCancelled) t.cancel("abort");
      }
    }

    var attempts = 0;
    var maxAttempts = 1000;
    var idleStreak = 0;
    var maxIdleAttempts = maxIdleRounds;
    var workers = 1;
    DateTime? lastStallLog; // 多条连接同时停滞时只记一条日志

    while (true) {
      // ── 循环顶部：停止 / 失败 / 重排的统一出口 ──
      if (ctrl.isStopped) {
        ctrl.onLog?.call("下载已停止", "warn");
        ctrl.failureReason = "下载已停止";
        try {
          if (await partDir.exists()) await partDir.delete(recursive: true);
        } catch (_) {}
        return false;
      }
      if (fatalMsg != null) {
        // 确定性失败（HTML 嗅探命中）不留半截分块；其余保留供续传
        if (!fatalRetryable) {
          try {
            if (await partDir.exists()) await partDir.delete(recursive: true);
          } catch (_) {}
        }
        ctrl.retryable = fatalRetryable;
        ctrl.failureReason = fatalMsg;
        return false;
      }
      if (rangeLostFlag) {
        rangeLostFlag = false;
        await _mp4WipeChunks(
            partDir, "服务器开始忽略 Range，退回单连接从头下载", ctrl);
        totalBytes = 0;
        chunkLen = 0;
        chunkCount = 0;
        continue;
      }
      if (replanTotal > 0) {
        if (replanTotal != totalBytes) {
          replanStreak = 0;
          totalBytes = replanTotal;
          await _mp4WipeChunks(partDir, "服务器文件总长已变为 $totalBytes，重新分块", ctrl);
        } else {
          // 总长没变却一直 416：连续 3 次就放弃，防止无意义空转
          replanStreak++;
          if (replanStreak >= 3) {
            fatalMsg = "服务器对分块请求持续返回 416（文件可能已被更换），请稍后重试";
          }
        }
        replanTotal = 0;
        chunkCount = 0;
        continue;
      }

      // ── 探测文件总长（Range: bytes=0-0）──
      if (totalBytes <= 0 && rangeOk) {
        var probed = false;
        while (!probed && fatalMsg == null && !ctrl.isStopped) {
          if (await ctrl.awaitIfPaused()) break; // 暂停中被 stop 叫醒
          attempts++;
          final o = await _probeMp4Total(dio, mp4Url, ctrl, stallTimeout, activeTokens);
          if (o.kind == _Mp4ChunkKind.done) {
            totalBytes = o.newTotal ?? 0; // 206：Content-Range 总长
          } else if (o.kind == _Mp4ChunkKind.rangeLost) {
            rangeOk = false; // 200：服务器忽略 Range，转串行
            totalBytes = o.newTotal ?? 0;
          } else if (o.kind == _Mp4ChunkKind.replan) {
            totalBytes = o.newTotal ?? 0; // 416：用 Content-Range 校正
          } else if (o.kind == _Mp4ChunkKind.fatal) {
            fatalMsg = o.message ?? "下载失败";
          } else if (o.kind == _Mp4ChunkKind.stalled) {
            idleStreak++;
            if (idleStreak >= maxIdleAttempts) {
              fatalMsg = "线路长时间不返回数据（停滞不动），请换播放节点或稍后重试";
            }
          } else {
            idleStreak++;
            if (idleStreak >= maxIdleAttempts) {
              fatalMsg = "连接不上服务器，请检查网络或更换播放节点";
            } else {
              await Future.delayed(const Duration(seconds: 2));
            }
          }
          if (o.kind == _Mp4ChunkKind.done ||
              o.kind == _Mp4ChunkKind.rangeLost ||
              o.kind == _Mp4ChunkKind.replan) {
            probed = true;
          }
        }
        if (fatalMsg != null || ctrl.isStopped) continue;
        if (rangeOk && totalBytes == 0) {
          // 探测确认服务器上就是空文件：直接落一个空文件收尾
          try {
            await File(savePath).writeAsBytes(const <int>[], flush: true);
          } catch (e) {
            ctrl.failureReason = "创建文件失败: $e";
            return false;
          }
          await _saveToHistory(video, savePath);
          ctrl.onLog?.call("下载完成: ${video.title}", "info");
          return true;
        }
      }

      // ── 建分块网格（首轮；replan / rangeLost 后 chunkCount 归零重建）──
      if (chunkCount == 0) {
        if (!rangeOk) {
          chunkLen = 0;
          chunkCount = 1;
        } else if (totalBytes <= 0) {
          // 连总长都拿不到（206 却没有 Content-Range）：串行兜底
          rangeOk = false;
          chunkLen = 0;
          chunkCount = 1;
        } else {
          final ideal = totalBytes ~/ max(_mp4MaxConcurrentDownloads, 1);
          chunkLen =
              ideal < chunkFloor ? chunkFloor : (ideal > chunkCap ? chunkCap : ideal);
          if (chunkLen > totalBytes) chunkLen = totalBytes;
          chunkCount = (totalBytes + chunkLen - 1) ~/ chunkLen;
          // 上次的网格还适用时沿用旧块长：改了并发数不该丢掉已完成块
          if (metaTotal == totalBytes &&
              metaChunkLen > 0 &&
              metaChunkLen != chunkLen) {
            chunkLen = metaChunkLen;
            chunkCount = (totalBytes + chunkLen - 1) ~/ chunkLen;
          }
        }
        // 服务器文件变了 / 串并行切换：旧分块全部作废
        final gridChanged = (metaTotal > 0 &&
                totalBytes > 0 &&
                metaTotal != totalBytes) ||
            (metaChunkLen > 0 && !rangeOk) ||
            (metaTotal > 0 && metaChunkLen == 0 && rangeOk);
        if (gridChanged) {
          await _mp4WipeChunks(partDir, "服务器文件或分块方案与上次不一致", ctrl);
        }
        chunkDone = List<bool>.filled(chunkCount, false);
        inflightBytes = List<int>.filled(chunkCount, 0);
        completedBytes = 0;
        workers = chunkCount == 1
            ? 1
            : min(_mp4MaxConcurrentDownloads, chunkCount);
        maxAttempts = chunkCount * 3 + 60;
        maxIdleAttempts = max(maxIdleRounds, workers * 2);
        await partDir.create(recursive: true);
        await _mp4WriteMeta(partDir, totalBytes, chunkLen);
        // 盘点已完成块（块文件存在且长度与网格一致才算完成；
        // 长度对不上的半截块留着重下即可，不用删）
        var resumedCount = 0;
        for (var i = 0; i < chunkCount; i++) {
          if (await _mp4ChunkFileDone(partDir, i, chunkLen, totalBytes)) {
            chunkDone[i] = true;
            completedBytes += _mp4ExpectedLen(i, chunkLen, totalBytes);
            resumedCount++;
          }
        }
        recalcReceived();
        reportProgress();
        if (resumedCount > 0) {
          ctrl.onLog?.call(
              "断点续传：已完成 $resumedCount/$chunkCount 块"
              "（${(completedBytes / 1024 / 1024).toStringAsFixed(1)} MB）",
              "info");
        }
        if (totalBytes > 0 && !sizeLogged) {
          sizeLogged = true;
          ctrl.onLog?.call(
              "文件大小: ${(totalBytes / 1024 / 1024).toStringAsFixed(2)} MB",
              "info");
        }
        if (chunkCount > 1) {
          ctrl.onLog?.call(
              "并发下载：$workers 条连接 × 每块 ${(chunkLen / 1024).toStringAsFixed(0)} KB"
              "（共 $chunkCount 块）",
              "info");
        }
      }

      // ── 滑动窗口并发（结构与 HLS 切片一致）──
      // 每完成一块立即补发下一块，始终保持 N 条连接在途。
      // 用「未消费的完成信号计数 + 等待者队列」实现，信号不会丢失。
      var unconsumed = 0;
      final waiters = <Completer<void>>[];

      void signalDone() {
        if (waiters.isNotEmpty) {
          waiters.removeAt(0).complete();
        } else {
          unconsumed++; // 没有等待者，先记账，稍后被消费
        }
      }

      Future<void> waitAny() {
        if (unconsumed > 0) {
          unconsumed--;
          return Future.value();
        }
        final c = Completer<void>();
        waiters.add(c);
        return c.future;
      }

      Future<void> runOne(int idx) async {
        try {
          while (true) {
            // 全局中止 / 停止：不再发新请求
            if (ctrl.isStopped ||
                fatalMsg != null ||
                rangeLostFlag ||
                replanTotal > 0) {
              return;
            }
            if (await ctrl.awaitIfPaused()) return; // 暂停中被 stop 叫醒
            if (attempts >= maxAttempts) return; // 预算兜底，收尾判定统一给文案
            attempts++;

            final start = idx * chunkLen;
            final end = chunkLen > 0
                ? min(start + chunkLen, totalBytes) - 1
                : -1; // -1 = 串行整文件，不带 Range
            inflightBytes[idx] = 0;
            final o = await _fetchMp4ChunkOnce(
              dio: dio,
              url: mp4Url,
              target: File(
                  "${partDir.path}/chunk_${idx.toString().padLeft(5, '0')}"),
              start: start,
              end: end,
              ctrl: ctrl,
              stallTimeout: stallTimeout,
              activeTokens: activeTokens,
              sniff: idx == 0,
              onWritten: (w) {
                inflightBytes[idx] = w;
                recalcReceived();
                reportProgress();
              },
            );

            if (o.kind == _Mp4ChunkKind.done) {
              inflightBytes[idx] = 0;
              if (!chunkDone[idx]) {
                chunkDone[idx] = true;
                completedBytes += _mp4ExpectedLen(idx, chunkLen, totalBytes);
              }
              recalcReceived();
              reportProgress();
              idleStreak = 0;
              return;
            } else if (o.kind == _Mp4ChunkKind.partial) {
              // 连接提前断流但有字节落盘：整块重下（块文件重写，进度只增不减）
              if (o.bytesWritten > 0) {
                idleStreak = 0;
              } else {
                idleStreak++;
              }
              await Future.delayed(const Duration(seconds: 1));
            } else if (o.kind == _Mp4ChunkKind.stalled) {
              // 20 秒零字节：这条连接的配额多半用完了，立刻换一条
              if (fatalMsg == null && !ctrl.isStopped) {
                final now = DateTime.now();
                if (lastStallLog == null ||
                    now.difference(lastStallLog!).inMilliseconds >= 1000) {
                  lastStallLog = now;
                  ctrl.onLog?.call(
                      "${stallTimeout.inSeconds}s 没收到任何数据，正在换一条连接继续",
                      "warn");
                }
              }
              idleStreak++;
              if (idleStreak >= maxIdleAttempts) {
                fatalMsg ??=
                    "线路长时间不返回数据（停滞不动），请换播放节点或稍后重试";
                cancelAllActive();
                return;
              }
            } else if (o.kind == _Mp4ChunkKind.failed) {
              idleStreak++;
              if (idleStreak >= maxIdleAttempts) {
                fatalMsg ??= "下载中断（长时间取不到数据），重试会从断点继续";
                cancelAllActive();
                return;
              }
              await Future.delayed(const Duration(seconds: 2));
            } else if (o.kind == _Mp4ChunkKind.fatal) {
              if (!o.retryable) fatalRetryable = false;
              fatalMsg ??= o.message ?? "下载失败";
              cancelAllActive();
              return;
            } else if (o.kind == _Mp4ChunkKind.rangeLost) {
              rangeLostFlag = true;
              cancelAllActive();
              return;
            } else {
              // replan
              replanTotal = o.newTotal ?? 0;
              cancelAllActive();
              return;
            }
          }
        } finally {
          inflightBytes[idx] = 0;
          signalDone();
        }
      }

      var pending = 0;
      var inFlight = 0;
      while (inFlight > 0 || pending < chunkCount) {
        if (ctrl.isStopped ||
            fatalMsg != null ||
            rangeLostFlag ||
            replanTotal > 0) {
          break;
        }
        // 暂停期间不派发新块；已派发的 worker 会在自己的循环里挂起等 resume
        while (inFlight < workers && pending < chunkCount && !ctrl.isPaused) {
          unawaited(runOne(pending));
          pending++;
          inFlight++;
        }
        if (pending >= chunkCount && inFlight == 0) break;
        if (inFlight == 0) {
          // 窗口空了但还有块没派发：在暂停里等 resume（或 stop 退出）
          if (await ctrl.awaitIfPaused()) break;
          continue;
        }
        await waitAny();
        inFlight--;
      }
      // 收尾：等在途任务全部结束（暂停/停止时同样要收尾，避免半截状态）
      while (inFlight > 0) {
        await waitAny();
        inFlight--;
      }

      // ── 本轮收尾判定（rangeLost / replan 交回循环顶部统一处理）──
      if (ctrl.isStopped) continue;
      if (fatalMsg != null) continue;
      if (rangeLostFlag || replanTotal > 0) continue;

      var allDone = true;
      for (final d in chunkDone) {
        if (!d) {
          allDone = false;
          break;
        }
      }
      if (!allDone) {
        final mb = (received / 1024 / 1024).toStringAsFixed(1);
        ctrl.failureReason = attempts >= maxAttempts
            ? "下载多次中断（已下 $mb MB），重试会从断点继续"
            : "下载中断（已下 $mb MB），重试会从断点继续";
        return false;
      }

      // ── 合并分块 → 原子改名 → 记历史 ──
      final expectedLens = <int>[
        for (var i = 0; i < chunkCount; i++)
          _mp4ExpectedLen(i, chunkLen, totalBytes)
      ];
      if (!await _mergeMp4Chunks(partDir, expectedLens, savePath, ctrl)) {
        ctrl.failureReason ??= "合并分块文件失败，重试会从断点继续";
        return false;
      }
      await _saveToHistory(video, savePath);
      ctrl.onLog?.call("下载完成: ${video.title}", "info");
      return true;
    }
  }

  /// 媒体分块请求头。
  ///
  /// Connection: close 是刻意为之：CDN 按「连接」给起步配额，刚吐完一块的
  /// 连接配额已经耗尽，复用它的下一次请求只会白等 20 秒看门狗；close 让
  /// 完成的连接不回连接池，每次分块都拿一条带新配额的连接。
  /// [end] < start 表示串行整文件下载，不带 Range。
  Map<String, String> _mp4RequestHeaders([int? start, int? end]) {
    return {
      "Accept": "*/*",
      // 分段下载必须拿原始字节：gzip 后的字节数与 Content-Range
      // 对不上，按偏移续传会错位。
      "Accept-Encoding": "identity",
      "Connection": "close",
      if (start != null && end != null && end >= start)
        "Range": "bytes=$start-$end",
    };
  }

  /// 请求一个分块并写入 [target]（块文件独占写）。
  ///
  /// 块文件里可能已有上次没下完的部分：此时只请求剩余区间并以 append
  /// 续写；整块从零开始时才用 FileMode.write 截断。
  /// 永不抛异常：所有错误都折算成 [_Mp4ChunkOutcome]，重试策略由调用方定。
  /// [end] < [start] 表示串行整文件下载（不带 Range，读到 EOF 为止）。
  Future<_Mp4ChunkOutcome> _fetchMp4ChunkOnce({
    required Dio dio,
    required String url,
    required File target,
    required int start,
    required int end,
    required DownloadControl ctrl,
    required Duration stallTimeout,
    required Set<CancelToken> activeTokens,
    required void Function(int written) onWritten,
    bool sniff = false,
  }) async {
    final expected = end >= start ? end - start + 1 : -1;
    final cancelToken = CancelToken();
    activeTokens.add(cancelToken);
    Timer? stallTimer;
    RandomAccessFile? raf;
    // 块文件可能带着上次没下完的部分：从它的实际长度接着要。
    // 块文件是纯顺序写，FileMode.append（O_APPEND）正好匹配；这样
    // 「每条连接只吐一段配额就断流」的服务器行为也能几何收敛，
    // 不会在同一块上反复从零开始空转。
    var have = 0;
    if (expected > 0 && await target.exists()) {
      have = await target.length();
      if (have > expected) {
        // 长度越过网格（服务器换源等异常）：删掉整块重来
        try {
          await target.delete();
        } catch (_) {}
        have = 0;
      }
    }
    if (expected > 0 && have >= expected) {
      return const _Mp4ChunkOutcome(_Mp4ChunkKind.done);
    }
    var written = have;

    // ── 停滞看门狗 ──
    // dio 的 receiveTimeout 是 10 分钟，CDN 掐连接时经常既不报错也不再
    // 吐数据，界面就会「进度不动、也不失败」地卡着。这里自己盯：
    // 20 秒没收到任何字节就掐掉本次请求，换一条连接重试。
    void armWatchdog() {
      stallTimer?.cancel();
      stallTimer = Timer(stallTimeout, () {
        if (!cancelToken.isCancelled) cancelToken.cancel("stalled");
      });
    }

    try {
      armWatchdog();
      final resp = await dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          // 续传块：只请求还没拿到的后半段
          headers: _mp4RequestHeaders(
              expected > 0 ? start + have : null, expected > 0 ? end : null),
          receiveTimeout: const Duration(minutes: 10),
          sendTimeout: const Duration(seconds: 10),
        ),
        cancelToken: cancelToken,
      );

      final status = resp.statusCode ?? 0;
      final contentType =
          (resp.headers.value("content-type") ?? "").toLowerCase();

      if (expected > 0 && status != 206) {
        // 服务器开始忽略 Range：响应体从第 0 字节开始，按偏移写会接出错位
        // 文件。弃流、上报，由外层清掉全部分块退回串行。
        final sub = resp.data!.stream.listen((_) {});
        await sub.cancel();
        return const _Mp4ChunkOutcome(_Mp4ChunkKind.rangeLost);
      }

      raf = await target.open(
          mode: (expected > 0 && have > 0) ? FileMode.append : FileMode.write);
      // 追写续传块时响应从文件中段开始，头部嗅探只对完整的新响应做
      var headChecked = !sniff || (expected > 0 && have > 0);
      await for (final chunk in resp.data!.stream) {
        armWatchdog();
        if (ctrl.isStopped) break;
        if (ctrl.isPaused) {
          // 暂停期间本来就收不到数据，别让看门狗把这条连接掐掉
          stallTimer?.cancel();
          final wantStop = await ctrl.awaitIfPaused();
          if (wantStop) break;
          armWatchdog();
        }

        if (!headChecked && chunk.isNotEmpty) {
          headChecked = true;
          final reason = _mp4SniffFailure(chunk, contentType, ctrl);
          if (reason != null) {
            return _Mp4ChunkOutcome(_Mp4ChunkKind.fatal,
                message: reason, retryable: false);
          }
        }

        // 分块写盘：偶发的一次写入失败不该整单作废，重试几次再放弃
        var ok = false;
        for (var i = 0; i < 5; i++) {
          try {
            await raf.writeFrom(chunk);
            ok = true;
            break;
          } catch (e) {
            ctrl.onLog?.call("写入分块失败（第 ${i + 1} 次）: $e", "warn");
            await Future.delayed(Duration(milliseconds: 200 * (i + 1)));
          }
        }
        if (!ok) {
          throw FileSystemException("分块写入磁盘失败", target.path);
        }

        written += chunk.length;
        onWritten(written);
      }

      if (ctrl.isStopped) {
        return const _Mp4ChunkOutcome(_Mp4ChunkKind.failed);
      }
      if (expected > 0) {
        if (written == expected) {
          return const _Mp4ChunkOutcome(_Mp4ChunkKind.done);
        }
        // 服务器提前断流：整块重下。已写部分不计入完成账本，进度不虚高。
        return _Mp4ChunkOutcome(_Mp4ChunkKind.partial, bytesWritten: written);
      }
      // 串行模式：读到 EOF 即完成
      return const _Mp4ChunkOutcome(_Mp4ChunkKind.done);
    } catch (e) {
      if (ctrl.isStopped) {
        return const _Mp4ChunkOutcome(_Mp4ChunkKind.failed);
      }
      final err = e is DioException ? e : null;
      final code = err?.response?.statusCode;
      if (code == 416) {
        // 请求的偏移越过了文件末尾：服务器上的文件比网格小，按新总长重排
        final realTotal =
            _contentRangeTotal(err?.response?.headers.value("content-range"));
        if (realTotal != null && realTotal > 0) {
          return _Mp4ChunkOutcome(_Mp4ChunkKind.replan, newTotal: realTotal);
        }
        return const _Mp4ChunkOutcome(_Mp4ChunkKind.failed);
      }
      if (code != null && code >= 400 && code < 500) {
        // 签名过期 / 无权限 / 文件没了：重连没有意义，直接给出原因
        return _Mp4ChunkOutcome(_Mp4ChunkKind.fatal,
            message: _describeDirectDownloadError(e));
      }
      if (err != null && err.type == DioExceptionType.cancel) {
        // 看门狗掐的；若是其它 worker 触发的全局中止，外层看共享标记区分
        return const _Mp4ChunkOutcome(_Mp4ChunkKind.stalled);
      }
      return _Mp4ChunkOutcome(_Mp4ChunkKind.failed, message: e.toString());
    } finally {
      stallTimer?.cancel();
      activeTokens.remove(cancelToken);
      if (raf != null) {
        try {
          await raf.close();
        } catch (_) {}
      }
    }
  }

  /// 探测直链文件总长（Range: bytes=0-0）。
  ///
  /// 总长只认 Content-Range（见 [_contentRangeTotal]：HEAD 的
  /// content-length 不可信，实测同一地址两次 HEAD 报过 16.00 MB 与 3.24 MB）。
  /// 206 却没有 Content-Range 时没法按网格切，退回串行。
  Future<_Mp4ChunkOutcome> _probeMp4Total(
      Dio dio,
      String url,
      DownloadControl ctrl,
      Duration stallTimeout,
      Set<CancelToken> activeTokens) async {
    final cancelToken = CancelToken();
    activeTokens.add(cancelToken);
    Timer? stallTimer;
    try {
      stallTimer = Timer(stallTimeout, () {
        if (!cancelToken.isCancelled) cancelToken.cancel("stalled");
      });
      final resp = await dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: _mp4RequestHeaders(0, 0),
          receiveTimeout: const Duration(minutes: 1),
          sendTimeout: const Duration(seconds: 10),
        ),
        cancelToken: cancelToken,
      );
      final status = resp.statusCode ?? 0;
      // 响应体只有 1 字节（或一页 HTML），立刻弃流、关连接
      final sub = resp.data!.stream.listen((_) {});
      await sub.cancel();
      final crTotal = _contentRangeTotal(resp.headers.value("content-range"));
      final lengthHeader =
          int.tryParse(resp.headers.value("content-length") ?? "") ?? 0;
      if (status == 206) {
        if (crTotal != null && crTotal > 0) {
          return _Mp4ChunkOutcome(_Mp4ChunkKind.done, newTotal: crTotal);
        }
        return const _Mp4ChunkOutcome(_Mp4ChunkKind.rangeLost);
      }
      if (status == 200) {
        // 服务器忽略 Range：退回串行；Content-Length 可当总长参考
        return _Mp4ChunkOutcome(_Mp4ChunkKind.rangeLost,
            newTotal: lengthHeader > 0 ? lengthHeader : null);
      }
      return _Mp4ChunkOutcome(_Mp4ChunkKind.failed, message: "HTTP $status");
    } catch (e) {
      if (ctrl.isStopped) {
        return const _Mp4ChunkOutcome(_Mp4ChunkKind.failed);
      }
      final err = e is DioException ? e : null;
      final code = err?.response?.statusCode;
      if (code == 416) {
        final crTotal =
            _contentRangeTotal(err?.response?.headers.value("content-range"));
        return _Mp4ChunkOutcome(_Mp4ChunkKind.replan, newTotal: crTotal ?? 0);
      }
      if (code != null && code >= 400 && code < 500) {
        return _Mp4ChunkOutcome(_Mp4ChunkKind.fatal,
            message: _describeDirectDownloadError(e));
      }
      if (err != null && err.type == DioExceptionType.cancel) {
        return const _Mp4ChunkOutcome(_Mp4ChunkKind.stalled);
      }
      return _Mp4ChunkOutcome(_Mp4ChunkKind.failed,
          message: _describeDirectDownloadError(e));
    } finally {
      stallTimer?.cancel();
      activeTokens.remove(cancelToken);
    }
  }

  /// 判断响应开头是不是网页/JSON——签名过期或触发风控时站点会回
  /// 200 + 一个 HTML 页面，旧实现会把它原样存成 .mp4，任务显示
  /// 「下载完成」但文件放不出来。
  ///
  /// 判据必须是「像文本」而不是「首字符是 < 或 {」：视频头几个字节完全
  /// 可能是随机的 { 或 <，只看首字符会把正常片子误杀。页面正文里有中文
  ///（UTF-8 三字节）会把可打印比例拉到 0.4 左右，所以比例之外再补一条
  /// 「content-type 说是文本且首字符是 < 或 {」，两者取并集。
  /// 返回 null = 像视频，继续下载；返回文案 = 给用户的失败原因。
  String? _mp4SniffFailure(
      List<int> chunk, String contentType, DownloadControl ctrl) {
    final head = chunk.take(512).toList();
    var printable = 0;
    for (final b in head) {
      if ((b >= 32 && b < 127) || b == 9 || b == 10 || b == 13) {
        printable++;
      }
    }
    final looksText = head.length >= 16 && printable / head.length > 0.9;
    final textType = contentType.contains("text/html") ||
        contentType.contains("application/json") ||
        contentType.contains("text/plain");
    final preview = String.fromCharCodes(
        head.take(120).map((b) => (b >= 32 && b < 127) ? b : 32));
    final lower = preview.toLowerCase().trimLeft();
    final looksMarkup = lower.startsWith("<") || lower.startsWith("{");
    if (looksText || (textType && looksMarkup)) {
      ctrl.onLog?.call("服务器返回的是网页而不是视频: $preview", "error");
      return "站点返回的是网页而不是视频文件（链接已失效或被风控拦截）。"
          "请重试；若一直失败，到设置里把播放节点切回「自动（跟随站点）」。";
    }
    return null;
  }

  /// 第 idx 块的期望字节数；-1 表示未知（串行且总长拿不到）
  int _mp4ExpectedLen(int idx, int chunkLen, int total) {
    if (chunkLen <= 0) return total > 0 ? total : -1;
    final start = idx * chunkLen;
    final end = min(start + chunkLen, total);
    return end - start;
  }

  /// 块文件是否已完成：存在且长度与网格一致。
  /// 长度对不上（上次写了一半被杀）不算完成，整块重下。
  Future<bool> _mp4ChunkFileDone(
      Directory dir, int idx, int chunkLen, int total) async {
    final f = File("${dir.path}/chunk_${idx.toString().padLeft(5, '0')}");
    if (!await f.exists()) return false;
    final expected = _mp4ExpectedLen(idx, chunkLen, total);
    if (expected <= 0) return false;
    return await f.length() == expected;
  }

  /// 写续传元数据。写失败只影响下次续传精度，不阻断本次下载。
  Future<void> _mp4WriteMeta(Directory dir, int total, int chunkLen) async {
    try {
      await File("${dir.path}/meta.json").writeAsString(
          jsonEncode({"v": 1, "total": total, "chunkLen": chunkLen}),
          flush: true);
    } catch (_) {}
  }

  /// 清空分块临时目录（服务器文件变化 / 串并行切换 / 确定性失败时）
  Future<void> _mp4WipeChunks(
      Directory dir, String why, DownloadControl ctrl) async {
    ctrl.onLog?.call("清空分块临时目录：$why", "warn");
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// 把分块文件按序合并成最终文件；全部通过长度校验后原子改名。
  Future<bool> _mergeMp4Chunks(Directory partDir, List<int> expectedLens,
      String savePath, DownloadControl ctrl) async {
    final merged = File("$savePath.merging");
    IOSink? sink;
    try {
      sink = merged.openWrite(mode: FileMode.write);
      var written = 0;
      for (var i = 0; i < expectedLens.length; i++) {
        final f = File("${partDir.path}/chunk_${i.toString().padLeft(5, '0')}");
        var len = 0;
        if (await f.exists()) len = await f.length();
        final expected = expectedLens[i];
        if (expected > 0 && len != expected) {
          ctrl.onLog?.call("合并中止：分块 $i 大小不符（$len / $expected）", "error");
          return false;
        }
        await sink.addStream(f.openRead());
        written += len;
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (written <= 0) {
        ctrl.onLog?.call("合并中止：所有分块都是空的", "error");
        return false;
      }
      await merged.rename(savePath);
      try {
        await partDir.delete(recursive: true);
      } catch (_) {}
      return true;
    } catch (e) {
      ctrl.onLog?.call("合并分块失败: $e", "error");
      return false;
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
    }
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
