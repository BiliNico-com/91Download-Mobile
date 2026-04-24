import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/logger.dart';

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
      
      Logger().logSync('Version', '初始化完成: $fullVersion');
    } catch (e, stackTrace) {
      Logger().logSync('Version', 'init error: $e');
      Logger().logSync('Version', '$stackTrace');
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
      Logger().logSync('Version', '正在检查更新...');
      
      // 方案1：GitHub Release API（唯一真实来源）
      final release = await _fetchLatestRelease();
      if (release != null) {
        remoteVersion = release;
        
        // 比较 build number
        final storedBuild = await getStoredBuildNumber();
        if (release.buildNumber > storedBuild || 
            (release.buildNumber == 0 && release.version != localVersion.version)) {
          Logger().logSync('Version', '发现新版本: ${release} > v${localVersion.version}.$storedBuild');
          return release;
        }
        
        Logger().logSync('Version', '当前已是最新版本');
        return null;
      }
      
      Logger().logSync('Version', '未获取到远程版本信息');
      return null;
    } catch (e, stackTrace) {
      Logger().logSync('Version', 'checkUpdate error: $e');
      Logger().logSync('Version', '$stackTrace');
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

  /// 从 GitHub Release 页面获取最新版本（爬取页面，不受 API 限制）
  static Future<VersionInfo?> _fetchLatestRelease() async {
    const releaseUrl = 'https://github.com/$_owner/$_repo/releases/latest';
    Logger().logSync('Version', '开始请求: $releaseUrl');
    
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        headers: {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'},
      ));

      final response = await dio.get(releaseUrl);
      
      Logger().logSync('Version', '响应状态码: ${response.statusCode}');

      if (response.statusCode == 200) {
        final html = response.data.toString();
        final result = _parseReleasePage(html);
        if (result != null) {
          Logger().logSync('Version', '解析成功: version=${result.version}, buildNumber=${result.buildNumber}');
        } else {
          Logger().logSync('Version', '解析失败，请检查HTML格式');
        }
        return result;
      } else {
        Logger().logSync('Version', '请求失败: ${response.statusCode}');
        return null;
      }
    } on DioException catch (e) {
      Logger().logSync('Version', '❌ DioException:');
      Logger().logSync('Version', '  type: ${e.type}');
      Logger().logSync('Version', '  message: ${e.message}');
      Logger().logSync('Version', '  error: ${e.error}');
      if (e.response != null) {
        Logger().logSync('Version', '  statusCode: ${e.response?.statusCode}');
        Logger().logSync('Version', '  responseData: ${e.response?.data}');
      }
      return null;
    } catch (e, stackTrace) {
      Logger().logSync('Version', '❌ fetch error: $e');
      return null;
    }
  }

  /// 解析 GitHub Release 页面 HTML
  static VersionInfo? _parseReleasePage(String html) {
    try {
      // 从标题或标签解析版本号，格式：v1.0.5.389
      final tagMatch = RegExp(r'v1\.0\.5\.(\d+)').firstMatch(html);
      if (tagMatch == null) {
        Logger().logSync('Version', '未找到版本号');
        return null;
      }

      final buildNumber = int.tryParse(tagMatch.group(1)!) ?? 0;
      
      return VersionInfo(
        version: '1.0.5',
        buildNumber: buildNumber,
        downloadUrl: 'https://github.com/$_owner/$_repo/releases/latest/download/app-release.apk',
        releaseDate: '',
        releaseNotes: [],
      );
    } catch (e) {
      Logger().logSync('Version', 'parse release page error: $e');
      return null;
    }
  }

  /// 下载并安装更新
  static Future<bool> downloadAndInstall(VersionInfo version, void Function(double) onProgress) async {
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
          if (total > 0) {
            onProgress(received / total);
          }
        },
      );

      Logger().logSync('Version', 'Download complete: ${apkFile.path}');

      // 调用系统安装器
      final result = await OpenFilex.open(apkFile.path);
      if (result.type != ResultType.done) {
        Logger().logSync('Version', 'Open installer result: ${result.type} ${result.message}');
      }
      return true;
    } on DioException catch (e) {
      Logger().logSync('Version', 'download error (${e.type}): ${e.message}');
      return false;
    } catch (e, stackTrace) {
      Logger().logSync('Version', 'downloadAndInstall error: $e');
      Logger().logSync('Version', '$stackTrace');
      return false;
    }
  }
}
