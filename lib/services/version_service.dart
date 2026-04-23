import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 版本信息
class VersionInfo {
  final String version;      // 如 "1.0.5"
  final int buildNumber;     // 如 340（对应 CI run_number）
  final String downloadUrl;  // APK下载地址
  final String releaseNotes; // 更新说明
  final String releaseDate;  // 发布日期

  VersionInfo({
    required this.version,
    required this.buildNumber,
    required this.downloadUrl,
    this.releaseNotes = '',
    this.releaseDate = '',
  });

  factory VersionInfo.fromJson(Map<String, dynamic> json) {
    return VersionInfo(
      version: json['version'] ?? '1.0.0',
      buildNumber: json['build_number'] ?? 0,
      downloadUrl: json['download_url'] ?? '',
      releaseNotes: json['release_notes'] ?? '',
      releaseDate: json['release_date'] ?? '',
    );
  }

  /// 完整版本标识，如 v1.0.5.340
  String get fullVersion => 'v$version.$buildNumber';
}

/// 版本服务
class VersionService {
  // 从 GitHub Releases API 获取最新版本信息
  static const String _releasesUrl = 'https://api.github.com/repos/BiliNico-com/91Download-Mobile/releases/latest';
  // 备用：直接读取 version.json
  static const String _versionJsonUrl = 'https://raw.githubusercontent.com/BiliNico-com/91Download-Mobile/main/version.json';

  static String _currentVersion = '1.0.5';
  static int _currentBuild = 0;
  static bool _initialized = false;

  /// 初始化版本信息（从已安装的APK本身获取）
  static Future<void> init() async {
    if (_initialized) return;
    try {
      final info = await PackageInfo.fromPlatform();
      _currentVersion = info.version;          // 来自 pubspec.yaml 的 version 字段
      _currentBuild = int.tryParse(info.buildNumber) ?? 0;  // 来自 pubspec.yaml +后的数字（CI 同步为 run_number）
      _initialized = true;
      debugPrint('[VersionService] 本地版本: v$_currentVersion.$_currentBuild');
    } catch (e) {
      debugPrint('获取版本信息失败: $e');
    }
  }

  static String get currentVersion => _currentVersion;
  static int get currentBuild => _currentBuild;
  static String get fullVersion => 'v$_currentVersion.$_currentBuild';

  final Dio _dio = Dio();

  /// 检查更新，返回远程版本信息（返回 null 表示无更新或检查失败）
  Future<VersionInfo?> checkUpdate() async {
    // 方案A：GitHub Releases API（主方案）
    try {
      final response = await _dio.get(_releasesUrl, options: Options(
        receiveTimeout: Duration(seconds: 10),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
        },
      ));

      if (response.statusCode == 200) {
        final data = response.data;
        final tagName = data['tag_name'] as String? ?? '';
        final assets = data['assets'] as List? ?? [];
        final body = data['body'] as String? ?? '';
        final publishedAt = data['published_at'] as String? ?? '';

        // 从 tag_name 解析版本号和 build number
        // CI 生成的格式: v1.0.{run_number} （如 v1.0.340）
        String remoteVersion = '';
        int buildNumber = 0;

        if (tagName.startsWith('v')) {
          final verStr = tagName.substring(1); // 去掉 'v' 前缀，如 "1.0.340"
          final parts = verStr.split('.');
          if (parts.length >= 3) {
            // 最后一段是 build number，前面的是语义化版本
            buildNumber = int.tryParse(parts.last) ?? 0;
            // 版本号取前 N-1 段拼接（如 parts=["1","0","340"] → version="1.0"）
            // 但如果格式是 "1.0.5.340" 则取前3段
            final versionParts = parts.length > 3 ? parts.sublist(0, 3) : parts.sublist(0, parts.length - 1);
            remoteVersion = versionParts.join('.');
          }
        } else if (tagName.startsWith('build')) {
          buildNumber = int.tryParse(tagName.substring(5)) ?? 0;
          remoteVersion = _currentVersion; // fallback 用本地版本号
        }

        // 获取 APK 下载链接
        String downloadUrl = '';
        for (final asset in assets) {
          final name = asset['name'] as String? ?? '';
          if (name.endsWith('.apk')) {
            downloadUrl = asset['browser_download_url'] as String? ?? '';
            break;
          }
        }
        if (downloadUrl.isEmpty) {
          downloadUrl = 'https://github.com/BiliNico-com/91Download-Mobile/releases/latest/download/app-release.apk';
        }

        debugPrint('[VersionService] 远程版本: v$remoteVersion.$buildNumber');

        return VersionInfo(
          version: remoteVersion,   // ✅ 使用解析出的远端版本号（不再是本地值）
          buildNumber: buildNumber,
          downloadUrl: downloadUrl,
          releaseNotes: body,
          releaseDate: publishedAt.split('T').first,
        );
      }
    } catch (e) {
      debugPrint('GitHub API 检查更新失败: $e，尝试备用方案...');
    }

    // 方案B：读取 version.json（备用方案）
    try {
      final response = await _dio.get(_versionJsonUrl, options: Options(
        receiveTimeout: Duration(seconds: 10),
      ));

      if (response.statusCode == 200) {
        final jsonData = response.data;
        final json = jsonData is String ? jsonDecode(jsonData) : jsonData;
        final info = VersionInfo.fromJson(json);
        debugPrint('[VersionService] 远程版本(version.json): ${info.fullVersion}');
        return info;
      }
    } catch (e) {
      debugPrint('备用方案检查更新失败: $e');
    }

    return null;
  }

  /// 比较版本，返回 true 表示有新版本可用
  bool hasNewVersion(VersionInfo remote) {
    // 第一步：比较语义化版本号 (major.minor.patch)
    final localParts = _currentVersion.split('.');
    final remoteParts = remote.version.split('.');

    for (int i = 0; i < 3; i++) {
      final local = localParts.length > i ? int.tryParse(localParts[i]) ?? 0 : 0;
      final remoteVal = remoteParts.length > i ? int.tryParse(remoteParts[i]) ?? 0 : 0;

      if (remoteVal > local) return true;
      if (remoteVal < local) return false;
    }

    // 第二步：语义版本相同则比较 build number（CI run_number）
    return remote.buildNumber > _currentBuild;
  }

  /// 下载并安装APK
  Future<bool> downloadAndInstall(VersionInfo version, void Function(double)? onProgress) async {
    try {
      // 获取下载目录
      final dir = await getExternalStorageDirectory();
      if (dir == null) return false;

      final filePath = '${dir.path}/91Download_${version.version}_build${version.buildNumber}.apk';
      final file = File(filePath);

      // 如果文件已存在且大小合理(>1MB)，直接打开安装
      if (await file.exists()) {
        final fileSize = await file.length();
        if (fileSize > 1024 * 1024) {
          debugPrint('[VersionService] 文件已存在，直接安装: $filePath (${(fileSize / 1024 / 1024).toStringAsFixed(1)}MB)');
          final result = await OpenFilex.open(filePath);
          return result.type == ResultType.done;
        } else {
          // 文件不完整，删除重新下载
          await file.delete();
        }
      }

      debugPrint('[VersionService] 开始下载: ${version.downloadUrl}');

      // 下载APK
      await _dio.download(
        version.downloadUrl,
        filePath,
        options: Options(receiveTimeout: Duration(minutes: 10)),
        onReceiveProgress: (received, total) {
          if (onProgress != null) {
            if (total > 0) {
              onProgress(received / total);
            } else {
              // 没有 total 时用负数标记，UI层显示已下载大小
              onProgress(-received / (100 * 1024 * 1024));
            }
          }
        },
      );

      debugPrint('[VersionService] 下载完成，准备安装: $filePath');

      // 安装APK - 系统包安装器会处理权限请求
      final result = await OpenFilex.open(filePath);
      return result.type == ResultType.done;
    } catch (e) {
      debugPrint('下载更新失败: $e');
      return false;
    }
  }
}
