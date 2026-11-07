import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/logger.dart';

/// 版本号模型
///
/// 版本号来源统一为 pubspec.yaml，CI 只覆写 build number：
///   pubspec: version: 1.0.6+<run_number>
///   tag:     v1.0.6.<run_number>
/// 因此 [version] 为 1.0.6，[buildNumber] 为 run_number，两者可直接比较。
class VersionInfo {
  /// 语义化版本号，如 1.0.6
  final String version;

  /// 构建序号（CI run_number），单调递增
  final int buildNumber;

  final String downloadUrl;

  /// Release 发布时间（ISO8601），可能为空
  final String publishedAt;

  final List<String> releaseNotes;

  /// Release 页面的原始 tag（如 v1.0.6.458），用于展示
  final String tagName;

  /// 安装包字节数，来自 GitHub Release API 的 asset.size。
  /// 为 null 表示未知（例如从 HTML 页面兜底解析时拿不到）。
  final int? size;

  VersionInfo({
    required this.version,
    required this.buildNumber,
    required this.downloadUrl,
    this.publishedAt = '',
    this.releaseNotes = const [],
    this.tagName = '',
    this.size,
  });

  @override
  String toString() => 'v$version.$buildNumber';

  String get fullVersion => 'v$version.$buildNumber';
}

/// 版本服务 —— 基于 GitHub Release API
///
/// 设计要点：
/// 1. **版本号唯一来源是 pubspec.yaml**。CI 只把 `+N` 换成 run_number，
///    并据此生成 tag `v<版本>.<run_number>`，保证 tag 与 APK 内嵌版本一致。
/// 2. 使用 GitHub 官方 Release API 获取结构化 JSON，不再爬 HTML
///    （HTML 会随 GitHub 改版失效，且容易误抓页面中其它 vX.Y.Z 字符串）。
///    匿名调用限额 60 次/小时，检查更新属低频操作，足够使用。
/// 3. 比较逻辑分层：先比语义化版本，相同再比 build number。
class VersionService {
  static const _owner = 'BiliNico-com';
  static const _repo = '91Download-Mobile';

  /// GitHub Release API（latest 返回最新正式版，自动排除 draft / prerelease）
  static const _apiUrl = 'https://api.github.com/repos/$_owner/$_repo/releases/latest';

  /// 本地版本信息（来自 PackageInfo，即 APK 编译时 pubspec.yaml 的值）
  static VersionInfo localVersion =
      VersionInfo(version: '0.0.0', buildNumber: 0, downloadUrl: '');

  /// 远程版本信息（来自 GitHub Release API）
  static VersionInfo? remoteVersion;

  /// 是否正在检查更新
  static bool isCheckingUpdate = false;

  /// 最近一次检查失败的原因（供 UI 展示，null 表示无错误）
  static String? lastError;

  /// 完整版本字符串（用于 UI 展示）
  static String get fullVersion => 'v${localVersion.version}.${localVersion.buildNumber}';

  /// 初始化 —— 从 PackageInfo 获取本地版本并持久化
  static Future<void> init() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();

      // PackageInfo.version 形如 "1.0.6"，buildNumber 形如 "458"。
      // 某些 Flutter 版本会把 buildNumber 拼成 "1.0.6+458" 的形式，
      // 因此这里对两种形态都做兼容。
      String version = packageInfo.version;
      int buildNumber = int.tryParse(packageInfo.buildNumber) ?? 0;

      if (packageInfo.buildNumber.contains('+')) {
        final parts = packageInfo.buildNumber.split('+');
        buildNumber = int.tryParse(parts.last) ?? 0;
      }
      if (version.contains('+')) {
        version = version.split('+').first;
      }

      localVersion = VersionInfo(
        version: version,
        buildNumber: buildNumber,
        downloadUrl: '',
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('app_build_number', buildNumber);
      await prefs.setString('app_version', version);

      Logger().logSync('Version', '初始化完成: $fullVersion');
    } catch (e, stackTrace) {
      Logger().logSync('Version', 'init error: $e');
      Logger().logSync('Version', '$stackTrace');
    }
  }

  /// 获取本地记录的 build number
  static Future<int> getStoredBuildNumber() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt('app_build_number') ?? localVersion.buildNumber;
    } catch (e) {
      return localVersion.buildNumber;
    }
  }

  /// 检查更新
  ///
  /// 返回值语义：
  ///   - 非 null：成功获取到远端最新版本（需再用 [hasNewVersion] 判断是否更新）
  ///   - null  ：检查失败，原因见 [lastError]；若 [lastError] 也为 null，
  ///             说明是「已有一次检查正在进行中」，不是失败。
  static Future<VersionInfo?> checkUpdate() async {
    if (isCheckingUpdate) {
      // 以前直接返回 null，调用方一律显示「检查更新失败：请检查网络连接」，
      // 用户点两下按钮就会看到莫名其妙的网络错误。
      lastError = '正在检查中，请稍候';
      Logger().logSync('Version', '已有检查在进行中，忽略本次请求');
      return null;
    }
    isCheckingUpdate = true;
    lastError = null;

    try {
      Logger().logSync('Version', '正在检查更新...');

      final release = await _fetchLatestRelease();
      if (release == null) {
        Logger().logSync('Version', '未获取到远程版本信息: ${lastError ?? "未知原因"}');
        return null;
      }

      remoteVersion = release;

      if (hasNewVersion(release)) {
        Logger().logSync('Version', '发现新版本: ${release.fullVersion} > $fullVersion');
      } else {
        Logger().logSync('Version', '当前已是最新版本 ($fullVersion)');
      }
      return release;
    } catch (e, stackTrace) {
      lastError = '检查更新失败: $e';
      Logger().logSync('Version', 'checkUpdate error: $e');
      Logger().logSync('Version', '$stackTrace');
      return null;
    } finally {
      isCheckingUpdate = false;
    }
  }

  /// 语义化版本号比较：返回 >0 表示 v1 更新，<0 表示 v2 更新，0 表示相同
  /// 例：1.0.6 > 1.0.5，1.1.0 > 1.0.10
  static int compareSemver(String v1, String v2) {
    final parts1 = v1.split('.').map((p) => int.tryParse(p.trim()) ?? 0).toList();
    final parts2 = v2.split('.').map((p) => int.tryParse(p.trim()) ?? 0).toList();
    final maxLen = parts1.length > parts2.length ? parts1.length : parts2.length;
    for (int i = 0; i < maxLen; i++) {
      final a = i < parts1.length ? parts1[i] : 0;
      final b = i < parts2.length ? parts2[i] : 0;
      if (a != b) return a.compareTo(b);
    }
    return 0;
  }

  /// 是否有新版本可用
  ///
  /// 分层比较：先比版本号，相同再比 build number。
  /// 这样既能识别 "1.0.6 → 1.0.7"，也能识别同一版本内的重建
  /// （如 1.0.6.100 → 1.0.6.101）。
  static bool hasNewVersion(VersionInfo? remote) {
    if (remote == null) return false;

    final cmp = compareSemver(remote.version, localVersion.version);
    if (cmp > 0) return true;
    if (cmp < 0) return false;

    // 版本号相同，比较 build number
    return remote.buildNumber > localVersion.buildNumber;
  }

  /// GitHub Release 页面（网页端，不走 API 限额）
  static const _releasePageUrl =
      'https://github.com/$_owner/$_repo/releases/latest';

  /// 获取最新 Release 信息
  ///
  /// 采用「爬页面为主、API 兜底」的策略：
  ///
  /// 1. **优先请求 `releases/latest` 网页**。网页端不计入 GitHub API 限额，
  ///    而匿名 API 限制为 **每 IP 每小时 60 次**——移动网络下大量用户共享出口 IP，
  ///    极易被打满（实测会返回 403），因此不能把 API 作为唯一来源。
  ///
  /// 2. 网页解析失败时（GitHub 改版等）再回退到 Release API，
  ///    此时才可能碰到限流，失败则给出明确提示。
  static Future<VersionInfo?> _fetchLatestRelease() async {
    // ── 方式 1：网页（不受 API 限额） ──
    final fromPage = await _fetchFromReleasePage();
    if (fromPage != null) return fromPage;

    Logger().logSync('Version', '网页解析未成功，回退到 Release API');

    // ── 方式 2：API 兜底 ──
    return await _fetchFromApi();
  }

  /// 从 GitHub Release 网页解析版本信息
  ///
  /// 关键点：请求 `releases/latest` 会 302 重定向到具体 tag 页面
  /// （如 `/releases/tag/v1.0.6.458`），我们既可以从重定向后的 URL 取 tag，
  /// 也可以从页面内容里取。这里两者都尝试，提高健壮性。
  static Future<VersionInfo?> _fetchFromReleasePage() async {
    Logger().logSync('Version', '请求 Release 页面: $_releasePageUrl');

    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml',
        },
        validateStatus: (status) => status != null && status < 500,
      ));

      final response = await dio.get(_releasePageUrl);

      // 重定向后的最终地址通常形如 .../releases/tag/v1.0.6.458
      final finalUrl = response.realUri.toString();
      Logger().logSync('Version', '页面状态: ${response.statusCode}, 最终地址: $finalUrl');

      if (response.statusCode != 200) {
        // 403 多为 GitHub 的网页风控/限流
        if (response.statusCode == 403) {
          lastError = 'GitHub 访问受限，请稍后再试';
        } else if (response.statusCode == 404) {
          lastError = '尚未发布任何 Release';
        } else {
          lastError = '请求失败: HTTP ${response.statusCode}';
        }
        Logger().logSync('Version', lastError!);
        return null;
      }

      final html = response.data.toString();

      // 优先从最终 URL 里取 tag，最准确
      String? tagName;
      final tagFromUrl =
          RegExp(r'/releases/tag/([^/?#]+)').firstMatch(finalUrl)?.group(1);
      if (tagFromUrl != null && tagFromUrl.isNotEmpty) {
        tagName = Uri.decodeComponent(tagFromUrl);
      }

      // URL 里没有就从页面内容找（新版 GitHub 把 tag 放在 title/og:title 等处）
      tagName ??= _extractTagFromHtml(html);

      if (tagName == null || tagName.isEmpty) {
        lastError = '无法从页面识别版本号';
        Logger().logSync('Version', lastError!);
        return null;
      }

      final parsed = _parseTag(tagName);
      if (parsed == null) return null;

      return VersionInfo(
        version: parsed.$1,
        buildNumber: parsed.$2,
        // 固定链接指向最新 release 的附件，与版本天然对应
        downloadUrl:
            'https://github.com/$_owner/$_repo/releases/latest/download/app-release.apk',
        publishedAt: _extractPublishedAt(html) ?? '',
        releaseNotes: _extractNotesFromHtml(html),
        tagName: tagName,
      );
    } on DioException catch (e) {
      lastError = _describeDioError(e);
      Logger().logSync('Version', '网页请求失败: ${e.type} / ${lastError!}');
      return null;
    } catch (e) {
      lastError = '页面解析异常: $e';
      Logger().logSync('Version', lastError!);
      return null;
    }
  }

  /// 从 HTML 中提取 tag 名
  ///
  /// 实测（2026-08 抓取 GitHub 页面）标题形如
  ///   `<title>Release Build 468 · BiliNico-com/91Download-Mobile · GitHub</title>`
  /// **标题里并不含版本号**，而页面正文中存在 `/releases/tag/v1.0.6.468` 链接。
  /// 因此优先匹配 tag 链接，标题只作为兜底。
  static String? _extractTagFromHtml(String html) {
    // 1) 页面中的 tag 链接（最可靠）
    //    注意：页面里可能先出现 "*name" 这类模板占位符，
    //    因此必须遍历找到第一个「合法版本号」，不能只取首个匹配。
    for (final m in RegExp(r'/releases/tag/([^"''\s&#?]+)').allMatches(html)) {
      final raw = Uri.decodeComponent(m.group(1)!.trim());
      if (RegExp(r'^v?\d+\.\d+\.\d+').hasMatch(raw)) return raw;
    }

    // 2) 正文中直接出现的版本号（如 asset 链接、release 标题文本）
    final versionMatch = RegExp(r'\bv(\d+\.\d+\.\d+\.\d+)\b').firstMatch(html);
    if (versionMatch != null) return 'v${versionMatch.group(1)}';

    // 3) 标题兜底：部分仓库会把 tag 写进 title / og:title
    final titleMatch = RegExp(r'<title>([^<]*)</title>').firstMatch(html);
    if (titleMatch != null) {
      final v = RegExp(r'(v?\d+\.\d+\.\d+(?:\.\d+)?)').firstMatch(titleMatch.group(1)!);
      if (v != null) return v.group(1);
    }

    final ogMatch =
        RegExp(r'property="og:title"\s+content="([^"]*)"').firstMatch(html);
    if (ogMatch != null) {
      final v = RegExp(r'(v?\d+\.\d+\.\d+(?:\.\d+)?)').firstMatch(ogMatch.group(1)!);
      if (v != null) return v.group(1);
    }

    return null;
  }

  /// 解析 tag 为 (version, buildNumber)
  ///
  /// 支持：
  ///   v1.0.6.458 → (1.0.6, 458)
  ///   v1.0.6     → (1.0.6, 0)   旧格式，仅比语义版本
  static (String, int)? _parseTag(String tagName) {
    final newFormat =
        RegExp(r'^v?(\d+\.\d+\.\d+)\.(\d+)$').firstMatch(tagName.trim());
    if (newFormat != null) {
      return (
        newFormat.group(1)!,
        int.tryParse(newFormat.group(2)!) ?? 0,
      );
    }

    final oldFormat = RegExp(r'^v?(\d+\.\d+\.\d+)$').firstMatch(tagName.trim());
    if (oldFormat != null) {
      return (oldFormat.group(1)!, 0);
    }

    lastError = '无法识别 Release tag: $tagName';
    Logger().logSync('Version', lastError!);
    return null;
  }

  /// 从页面提取发布时间
  static String? _extractPublishedAt(String html) {
    final m = RegExp(r'datetime="([^"]+)"').firstMatch(html);
    return m?.group(1);
  }

  /// 从 Release 页面 HTML 提取更新说明
  ///
  /// 优先取 markdown-body 区域内的列表项，取不到则回退整段文本。
  static List<String> _extractNotesFromHtml(String html) {
    final bodyMatch = RegExp(
      r'class="markdown-body[^"]*"[^>]*>([\s\S]*?)</div>',
    ).firstMatch(html);

    if (bodyMatch == null) return [];

    final bodyHtml = bodyMatch.group(1)!;

    final notes = <String>[];
    for (final li in RegExp(r'<li[^>]*>([\s\S]*?)</li>').allMatches(bodyHtml)) {
      final text = _stripHtmlTags(li.group(1)!).trim();
      if (text.isNotEmpty) notes.add(text);
      if (notes.length >= 8) break;
    }

    if (notes.isEmpty) {
      final text = _stripHtmlTags(bodyHtml).trim();
      for (final line in text.split('\n')) {
        final t = line.trim();
        if (t.isNotEmpty) notes.add(t);
        if (notes.length >= 8) break;
      }
    }

    return notes;
  }

  /// 去除 HTML 标签与实体
  static String _stripHtmlTags(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .trim();
  }

  /// 从 GitHub Release API 获取（兜底路径，可能受匿名限额影响）
  static Future<VersionInfo?> _fetchFromApi() async {
    Logger().logSync('Version', '请求 Release API: $_apiUrl');

    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        headers: {
          // GitHub API 要求带 User-Agent，并显式声明期望的 API 版本
          'User-Agent': '91Download-Mobile',
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
        },
        // 由本方法自行判断状态码，避免非 200 直接抛异常丢失错误信息
        validateStatus: (status) => status != null && status < 500,
      ));

      final response = await dio.get(_apiUrl);
      Logger().logSync('Version', 'API 状态码: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = response.data is String
            ? jsonDecode(response.data as String)
            : response.data;
        if (data is! Map) {
          lastError = 'Release API 返回格式异常';
          Logger().logSync('Version', lastError!);
          return null;
        }
        final result = _parseReleaseJson(Map<String, dynamic>.from(data));
        if (result != null) {
          Logger().logSync('Version',
              '解析成功: ${result.fullVersion} (tag=${result.tagName})');
        }
        return result;
      }

      if (response.statusCode == 404) {
        lastError = '尚未发布任何 Release';
        Logger().logSync('Version', lastError!);
        return null;
      }
      if (response.statusCode == 403) {
        // 匿名限额 60 次/小时（按 IP 计），移动网络下极易打满
        lastError = 'GitHub 访问受限（API 限额已满），请稍后再试';
        Logger().logSync('Version', lastError!);
        return null;
      }

      lastError = '请求失败: HTTP ${response.statusCode}';
      Logger().logSync('Version', lastError!);
      return null;
    } on DioException catch (e) {
      lastError = _describeDioError(e);
      Logger().logSync('Version', '❌ DioException: ${e.type} / ${lastError!}');
      return null;
    } catch (e) {
      lastError = '网络异常: $e';
      Logger().logSync('Version', '❌ fetch error: $e');
      return null;
    }
  }

  /// 把 DioException 转成用户可读的提示
  ///
  /// 注意：调用方均为 static 方法，此处必须是 static，
  /// 否则实例方法在静态上下文中不可见（编译报 Method not found）。
  static String _describeDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接超时，请检查网络';
      case DioExceptionType.connectionError:
        return '无法连接服务器，请检查网络';
      case DioExceptionType.badCertificate:
        return '证书校验失败';
      case DioExceptionType.cancel:
        return '请求已取消';
      default:
        return '网络请求失败: ${e.message ?? e.type.name}';
    }
  }

  /// 解析 Release API 返回的 JSON
  static VersionInfo? _parseReleaseJson(Map<String, dynamic> json) {
    try {
      final tagName = (json['tag_name'] ?? '').toString();
      final body = (json['body'] ?? '').toString();
      final publishedAt = (json['published_at'] ?? '').toString();

      // 复用统一的 tag 解析（与网页路径保持一致）
      final parsed = _parseTag(tagName);
      if (parsed == null) return null;
      final version = parsed.$1;
      final buildNumber = parsed.$2;

      // 下载地址优先取 Release 附件，保证与当前 Release 版本严格对应；
      // 取不到时回退到 releases/latest 的固定链接。
      String downloadUrl =
          'https://github.com/$_owner/$_repo/releases/latest/download/app-release.apk';
      int? assetSize;
      final assets = json['assets'];
      if (assets is List) {
        for (final asset in assets) {
          if (asset is Map && asset['name'] == 'app-release.apk') {
            final url = asset['browser_download_url']?.toString();
            if (url != null && url.isNotEmpty) downloadUrl = url;
            // size 字段本来就在 API 响应里，顺手取来用于展示与下载后校验
            final rawSize = asset['size'];
            if (rawSize is int && rawSize > 0) {
              assetSize = rawSize;
            } else if (rawSize is String) {
              assetSize = int.tryParse(rawSize);
            }
            break;
          }
        }
      }

      return VersionInfo(
        version: version,
        buildNumber: buildNumber,
        downloadUrl: downloadUrl,
        publishedAt: publishedAt,
        releaseNotes: _parseReleaseNotes(body),
        tagName: tagName,
        size: assetSize,
      );
    } catch (e) {
      lastError = '解析 Release 数据失败: $e';
      Logger().logSync('Version', lastError!);
      return null;
    }
  }

  /// 把 Release 正文（markdown）按行拆成更新条目
  ///
  /// 做了长度与条数限制：更新日志面向用户，正文若混入开发者细节会很长，
  /// 这里截断到最多 [maxNotes] 条、每条 [maxLen] 字，避免对话框被撑爆。
  static List<String> _parseReleaseNotes(String body) {
    if (body.trim().isEmpty) return [];

    const maxNotes = 8;
    const maxLen = 100;

    final lines = body
        .split('\n')
        .map((line) => line.trim())
        // 去掉 markdown 列表符号与标题符号
        .map((line) => line.replaceFirst(RegExp(r'^[-*+]\s+'), ''))
        .map((line) => line.replaceFirst(RegExp(r'^#{1,6}\s+'), ''))
        .map((line) => line.replaceAll('`', '').trim())
        // 过滤掉分隔线和空行
        .where((line) => line.isNotEmpty && !RegExp(r'^-{3,}$').hasMatch(line))
        .toList();

    final result = <String>[];
    for (var line in lines) {
      if (result.length >= maxNotes) break;
      if (line.length > maxLen) {
        line = '${line.substring(0, maxLen)}…';
      }
      result.add(line);
    }
    return result;
  }

  /// 下载进度快照
  ///
  /// [total] 为 0 表示服务器未返回 content-length，此时无法计算百分比，
  /// UI 应退化为「不限量滚动 + 已下载字节」而不是停在 0%。
  static bool wasCancelled = false;

  /// 下载并安装更新
  ///
  /// [onProgress] 每次回调给出 (已接收字节, 总字节)；总字节为 0 表示未知。
  /// [cancelToken] 用于真正中断下载 —— 仅关闭弹窗不会停止网络传输。
  ///
  /// 返回值语义：true 成功；false 失败或取消（取消时 [wasCancelled] 为 true，
  /// 调用方据此区分「用户主动取消」与「真的出错」，避免误报失败）。
  static Future<bool> downloadAndInstall(
    VersionInfo version,
    void Function(int received, int total) onProgress, {
    CancelToken? cancelToken,
  }) async {
    wasCancelled = false;
    lastError = null;
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 120),
      ));

      final tempDir = await Directory.systemTemp.createTemp('update_');
      final apkFile = File('${tempDir.path}/update.apk');

      await dio.download(
        version.downloadUrl,
        apkFile.path,
        cancelToken: cancelToken,
        onReceiveProgress: onProgress,
      );

      // 完整性校验：APK 本质是 zip，合法文件至少有数百 KB。
      // 另外检查文件头 magic number —— GitHub 在限流或 404 时可能返回一个
      // HTML 错误页，体积也可能超过 100KB，光看长度会把网页当 APK 交给安装器。
      final length = await apkFile.length();
      if (length < 100 * 1024) {
        lastError = '安装包下载不完整（${(length / 1024).toStringAsFixed(0)} KB）';
        Logger().logSync('Version', lastError!);
        await _safeDeleteDir(tempDir);
        return false;
      }

      if (!await _looksLikeZip(apkFile)) {
        lastError = '下载到的不是安装包（可能被网络拦截或限流），请稍后重试';
        Logger().logSync('Version', lastError!);
        await _safeDeleteDir(tempDir);
        return false;
      }

      // 服务器给了 content-length 时，比对实际大小，防止静默截断
      final expected = version.size;
      if (expected != null && expected > 0 && length != expected) {
        lastError = '安装包大小不符（期望 ${(expected / 1024 / 1024).toStringAsFixed(1)} MB，'
            '实际 ${(length / 1024 / 1024).toStringAsFixed(1)} MB）';
        Logger().logSync('Version', lastError!);
        await _safeDeleteDir(tempDir);
        return false;
      }

      Logger().logSync('Version', 'Download complete: ${apkFile.path} ($length bytes)');

      final result = await OpenFilex.open(apkFile.path);
      if (result.type != ResultType.done) {
        lastError = '无法启动安装器: ${result.message}';
        Logger().logSync('Version', 'Open installer result: ${result.type} ${result.message}');
        return false;
      }
      // 注意：这里**不删** tempDir —— 安装器是异步读取该文件的，
      // 提前删掉会导致安装失败或「解析软件包时出现问题」。
      // 残留由 _pruneOldUpdateDirs() 在下次启动时清理。
      return true;
    } on DioException catch (e) {
      // 取消是用户主动行为，不是错误，不要写 lastError
      if (e.type == DioExceptionType.cancel) {
        wasCancelled = true;
        Logger().logSync('Version', 'download cancelled by user');
        return false;
      }
      lastError = _describeDioError(e);
      Logger().logSync('Version', 'download error (${e.type}): ${e.message}');
      return false;
    } catch (e, stackTrace) {
      lastError = '下载失败: $e';
      Logger().logSync('Version', 'downloadAndInstall error: $e');
      Logger().logSync('Version', '$stackTrace');
      return false;
    }
  }

  /// 校验文件头是不是 zip（PK\x03\x04）。
  ///
  /// APK 就是 zip，头 4 字节固定是 50 4B 03 04。GitHub 限流时返回的
  /// HTML 错误页体积可能过 100KB，只查长度会把网页塞给安装器。
  static Future<bool> _looksLikeZip(File file) async {
    RandomAccessFile? raf;
    try {
      if (await file.length() < 4) return false;
      raf = await file.open();
      final header = await raf.read(4);
      return header.length == 4 &&
          header[0] == 0x50 &&
          header[1] == 0x4B &&
          header[2] == 0x03 &&
          header[3] == 0x04;
    } catch (e) {
      Logger().logSync('Version', '校验文件头失败: $e');
      return false;
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  /// 删除临时目录，失败只记日志（不能因为清理失败掩盖真正的错误）
  static Future<void> _safeDeleteDir(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      Logger().logSync('Version', '清理临时目录失败: $e');
    }
  }

  /// 清理历史遗留的 update_* 临时目录
  ///
  /// 安装成功后临时目录必须保留给安装器读取，所以只能在下次启动时清。
  /// 保留最近 1 小时内创建的目录，避免误删正在被安装器读取的那份。
  static Future<void> pruneOldUpdateDirs() async {
    try {
      final tmp = Directory.systemTemp;
      if (!await tmp.exists()) return;
      final cutoff = DateTime.now().subtract(const Duration(hours: 1));
      await for (final entity in tmp.list()) {
        if (entity is! Directory) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (!name.startsWith('update_')) continue;
        try {
          final stat = await entity.stat();
          if (stat.modified.isAfter(cutoff)) continue;
          await entity.delete(recursive: true);
          Logger().logSync('Version', '清理旧更新包目录: ${entity.path}');
        } catch (e) {
          Logger().logSync('Version', '清理 ${entity.path} 失败: $e');
        }
      }
    } catch (e) {
      Logger().logSync('Version', 'pruneOldUpdateDirs 失败: $e');
    }
  }
}
