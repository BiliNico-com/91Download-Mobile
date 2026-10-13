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

  VersionInfo({
    required this.version,
    required this.buildNumber,
    required this.downloadUrl,
    this.publishedAt = '',
    this.releaseNotes = const [],
    this.tagName = '',
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
  ///   - null  ：检查失败，原因见 [lastError]
  static Future<VersionInfo?> checkUpdate() async {
    if (isCheckingUpdate) return null;
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

  /// 从 GitHub Release API 获取最新版本
  ///
  /// 使用官方 API 而非爬 HTML：返回结构化 JSON，不受页面改版影响。
  static Future<VersionInfo?> _fetchLatestRelease() async {
    Logger().logSync('Version', '开始请求: $_apiUrl');

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
      Logger().logSync('Version', '响应状态码: ${response.statusCode}');

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
        // 匿名 API 限额 60 次/小时，超限会返回 403
        lastError = 'GitHub API 访问受限，请稍后再试';
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

      // 从 tag 解析版本号，支持两种格式：
      //   新格式（推荐）：v1.0.6.458   → version=1.0.6, build=458
      //   旧格式（兼容）：v1.0.5     → version=1.0.5, build=0
      final newFormat = RegExp(r'^v?(\d+\.\d+\.\d+)\.(\d+)$').firstMatch(tagName);
      final oldFormat = RegExp(r'^v?(\d+\.\d+\.\d+)$').firstMatch(tagName);

      String version;
      int buildNumber;

      if (newFormat != null) {
        version = newFormat.group(1)!;
        buildNumber = int.tryParse(newFormat.group(2)!) ?? 0;
      } else if (oldFormat != null) {
        version = oldFormat.group(1)!;
        buildNumber = 0;
      } else {
        lastError = '无法识别 Release tag: $tagName';
        Logger().logSync('Version', lastError!);
        return null;
      }

      // 下载地址优先取 Release 附件，保证与当前 Release 版本严格对应；
      // 取不到时回退到 releases/latest 的固定链接。
      String downloadUrl =
          'https://github.com/$_owner/$_repo/releases/latest/download/app-release.apk';
      final assets = json['assets'];
      if (assets is List) {
        for (final asset in assets) {
          if (asset is Map && asset['name'] == 'app-release.apk') {
            final url = asset['browser_download_url']?.toString();
            if (url != null && url.isNotEmpty) downloadUrl = url;
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

  /// 下载并安装更新
  static Future<bool> downloadAndInstall(
      VersionInfo version, void Function(double) onProgress) async {
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
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress(received / total);
        },
      );

      // 基本完整性校验：APK 本质是 zip，合法文件至少有数百 KB。
      // 避免网络中断时把残缺文件交给安装器。
      final length = await apkFile.length();
      if (length < 100 * 1024) {
        lastError = '安装包下载不完整（${(length / 1024).toStringAsFixed(0)} KB）';
        Logger().logSync('Version', lastError!);
        return false;
      }

      Logger().logSync('Version', 'Download complete: ${apkFile.path} ($length bytes)');

      final result = await OpenFilex.open(apkFile.path);
      if (result.type != ResultType.done) {
        lastError = '无法启动安装器: ${result.message}';
        Logger().logSync('Version', 'Open installer result: ${result.type} ${result.message}');
        return false;
      }
      return true;
    } on DioException catch (e) {
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
}
