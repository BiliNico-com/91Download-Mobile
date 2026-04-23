import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class VersionInfo {
  final String version;
  final int buildNumber;
  final String downloadUrl;
  final String releaseDate;
  final List<String> releaseNotes;

  VersionInfo({
    required this.version,
    required this.buildNumber,
    required this.downloadUrl,
    this.releaseDate = '',
    this.releaseNotes = const [],
  });

  @override
  String toString() => 'v$version.$buildNumber';

  String get fullVersion => 'v$version.$buildNumber';
}

/// 版本服务 - 基于GitHub Release API的版本检查
/// 
/// 工作流程：
/// 1. App启动时从PackageInfo获取当前版本，持久化到SharedPreferences
/// 2. 点击"检查更新"时从GitHub Release API获取最新release
/// 3. 比较：远端buildNumber > 本地SP中记录的buildNumber → 有更新
/// 
/// 不再依赖version.json静态文件，Release API是唯一真实来源
class VersionService {
  static const _owner = 'BiliNico-com';
  static const _repo = '91Download-Mobile';
  
  /// 本地版本信息（来自 PackageInfo，即 APK 编译时 pubspec.yaml 的值）
  static VersionInfo localVersion = VersionInfo(version: '0.0.0', buildNumber: 0, downloadUrl: '');
  
  /// 远程版本信息（来自 GitHub Release API）
  static VersionInfo? remoteVersion;
  
  /// 是否正在检查更新
  static bool isCheckingUpdate = false;

  /// 完整版本字符串（用于UI展示）
  static String get fullVersion => 'v${localVersion.version}.${localVersion.buildNumber}';

  /// 初始化 - 从 PackageInfo 获取本地版本并持久化到 SharedPreferences
  static Future<void> init() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final parts = packageInfo.buildNumber.split('+');
      
      // 解析版本号和构建号
      String version = packageInfo.version;  // 如 "1.0.5"
      int buildNumber = 0;
      
      if (parts.length > 1) {
        buildNumber = int.tryParse(parts[1]) ?? int.tryParse(packageInfo.buildNumber) ?? 0;
      } else {
        buildNumber = int.tryParse(packageInfo.buildNumber) ?? 0;
      }
      
      localVersion = VersionInfo(
        version: version,
        buildNumber: buildNumber,
        downloadUrl: '',
      );
      
      // 写入 SharedPreferences 作为持久化记录
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('app_build_number', buildNumber);
      await prefs.setString('app_version', version);
      
      debugPrint('[VersionService] 初始化完成: $fullVersion');
    } catch (e, stackTrace) {
      debugPrint('[VersionService] init error: $e');
      debugPrint('[VersionService] $stackTrace');
    }
  }

  /// 获取本地存储的 build number
  static Future<int> getStoredBuildNumber() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt('app_build_number') ?? localVersion.buildNumber ?? 0;
    } catch (e) {
      return localVersion.buildNumber;
    }
  }

  /// 检查更新 - 只走 GitHub Release API
  /// 返回 null 表示无更新或检查失败
  static Future<VersionInfo?> checkUpdate() async {
    if (isCheckingUpdate) return null;
    isCheckingUpdate = true;
    
    try {
      debugPrint('[VersionService] 正在检查更新...');
      
      // 方案1：GitHub Release API（唯一真实来源）
      final release = await _fetchLatestRelease();
      if (release != null) {
        remoteVersion = release;
        
        // 比较 build number
        final storedBuild = await getStoredBuildNumber();
        if (release.buildNumber > storedBuild || 
            (release.buildNumber == 0 && release.version != localVersion.version)) {
          debugPrint('[VersionService] 发现新版本: ${release} > v${localVersion.version}.$storedBuild');
          return release;
        }
        
        debugPrint('[VersionService] 当前已是最新版本');
        return null;
      }
      
      debugPrint('[VersionService] 未获取到远程版本信息');
      return null;
    } catch (e, stackTrace) {
      debugPrint('[VersionService] checkUpdate error: $e');
      debugPrint('[VersionService] $stackTrace');
      return null;
    } finally {
      isCheckingUpdate = false;
    }
  }
  
  /// 是否有新版本可用
  static bool hasNewVersion(VersionInfo? remote) {
    if (remote == null) return false;
    return remote.buildNumber > localVersion.buildNumber ||
           remote.version != localVersion.version;
  }

  /// 从 GitHub Release API 获取最新版本
  static Future<VersionInfo?> _fetchLatestRelease() async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        headers: {'User-Agent': '91Download-App/$fullVersion'},
      ));

      final response = await dio.get(
        'https://api.github.com/repos/$_owner/$_repo/releases/latest',
      );

      if (response.statusCode == 200) {
        return _parseRelease(response.data is String
            ? response.data as String
            : jsonEncode(response.data));
      } else if (response.statusCode == 404) {
        debugPrint('[VersionService] No releases found (404)');
        return null;
      } else {
        debugPrint('[VersionService] API error: ${response.statusCode}');
        return null;
      }
    } on DioException catch (e) {
      debugPrint('[VersionService] network error (${e.type}): ${e.message}');
      return null;
    } catch (e, stackTrace) {
      debugPrint('[VersionService] fetch error: $e');
      debugPrint('[VersionService] $stackTrace');
      return null;
    }
  }

  /// 解析 GitHub Release JSON
  static VersionInfo? _parseRelease(String jsonBody) {
    try {
      // 简单JSON解析（避免引入额外依赖）
      final tagMatch = RegExp(r'"tag_name"\s*:\s*"([^"]+)"').firstMatch(jsonBody);
      final nameMatch = RegExp(r'"name"\s*:\s*"([^"]+)"').firstMatch(jsonBody);
      final dateMatch = RegExp(r'"published_at"\s*:\s*"([^"]+)"').firstMatch(jsonBody);
      final bodyMatch = RegExp(r'"body"\s*:\s*"((?:[^"\\]|\\.)*)"', dotAll: true).firstMatch(jsonBody);

      // 提取下载URL
      String? downloadUrl;
      final assetRegex = RegExp(r'"browser_download_url"\s*:\s*"([^"]+\.apk[^"]*)"');
      final assetMatch = assetRegex.firstMatch(jsonBody);
      if (assetMatch != null) {
        downloadUrl = assetMatch.group(1);
      } else {
        // 默认使用 latest release 页面
        downloadUrl = 'https://github.com/$_owner/$_repo/releases/latest/download/app-release.apk';
      }

      // 解析 tag_name 为 version + buildNumber
      // 格式: "v1.0.352" 或 "1.0.5+352"
      String tagName = tagMatch?.group(1) ?? '';
      if (!tagName.startsWith('v')) tagName = 'v$tagName';
      
      // 尝试提取数字作为 buildNumber
      final digits = RegExp(r'(\d+)').allMatches(tagName).map((m) => m.group(1)).toList();
      int buildNumber = 0;
      String version = '0.0.0';
      
      if (digits.length >= 3) {
        version = '${digits[0]}.${digits[1]}.${digits[2]}';
        buildNumber = int.parse(digits.length > 3 ? (digits.last ?? '0') : (digits[2] ?? '0'));
      } else if (digits.length == 2) {
        version = '1.${digits[0]}';
        buildNumber = int.parse(digits[1] ?? '0');
      } else if (digits.length == 1) {
        buildNumber = int.parse(digits[0] ?? '0');
        version = '1.0.0';
      }
      
      // 如果tag格式是 v1.0.352，最后一段就是buildNumber
      final dotParts = tagName.replaceAll('v', '').split('.');
      if (dotParts.length >= 3) {
        buildNumber = int.tryParse(dotParts.last) ?? buildNumber;
      }
      
      // 解析 release notes
      List<String>? notes;
      if (bodyMatch != null) {
        final bodyText = bodyMatch.group(1)?.replaceAll('\\n', '\n') ?? '';
        notes = bodyText.split('\n')
            .where((l) => l.trim().isNotEmpty)
            .map((l) => l.replaceAll(RegExp(r'^-\s*'), '').trim())
            .where((l) => l.isNotEmpty)
            .toList();
      }

      return VersionInfo(
        version: version,
        buildNumber: buildNumber,
        downloadUrl: downloadUrl ?? '',
        releaseDate: dateMatch?.group(1) ?? '',
        releaseNotes: notes ?? const [],
      );
    } catch (e) {
      debugPrint('[VersionService] parse release error: $e');
      return null;
    }
  }

  /// 下载并安装更新
  static Future<bool> downloadAndInstall(VersionInfo version, void Function(double) onProgress) async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
      ));

      final tempDir = await Directory.systemTemp.createTemp('update_');
      final apkFile = File('${tempDir.path}/update.apk');

      await dio.download(
        version.downloadUrl,
        apkFile.path,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            onProgress(received / total);
          }
        },
      );

      debugPrint('[VersionService] Download complete: ${apkFile.path}');
      return true;
    } on DioException catch (e) {
      debugPrint('[VersionService] download error (${e.type}): ${e.message}');
      return false;
    } catch (e, stackTrace) {
      debugPrint('[VersionService] downloadAndInstall error: $e');
      debugPrint('[VersionService] $stackTrace');
      return false;
    }
  }
}
