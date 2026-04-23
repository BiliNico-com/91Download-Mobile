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
  final int buildNumber;     // 如 300
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
  
  /// 初始化版本信息（从app本身获取）
  static Future<void> init() async {
    if (_initialized) return;
    try {
      final info = await PackageInfo.fromPlatform();
      _currentVersion = info.version;
      // buildNumber从pubspec.yaml的version字段获取，格式：1.0.5+310
      _currentBuild = int.tryParse(info.buildNumber) ?? 0;
      _initialized = true;
    } catch (e) {
      debugPrint('获取版本信息失败: $e');
    }
  }
  
  static String get currentVersion => _currentVersion;
  static int get currentBuild => _currentBuild;
  static String get fullVersion => 'v$_currentVersion.$_currentBuild';

  final Dio _dio = Dio();

  /// 检查更新
  Future<VersionInfo?> checkUpdate() async {
    // 先尝试 GitHub Releases API
    try {
      final response = await _dio.get(_releasesUrl, options: Options(
        receiveTimeout: Duration(seconds: 10),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
        },
      ));
      
      if (response.statusCode == 200) {
        final data = response.data;
        // 解析 GitHub Release API 响应
        final tagName = data['tag_name'] as String? ?? '';
        final assets = data['assets'] as List? ?? [];
        final body = data['body'] as String? ?? '';
        final publishedAt = data['published_at'] as String? ?? '';
        
        // 解析版本号，格式: v1.0.5.322 或 build322
        String version = '1.0.5';
        int buildNumber = 0;
        
        if (tagName.startsWith('v')) {
          // 格式: v1.0.5.322
          final parts = tagName.substring(1).split('.');
          if (parts.length >= 3) {
            version = '${parts[0]}.${parts[1]}.${parts[2]}';
          }
          if (parts.length >= 4) {
            buildNumber = int.tryParse(parts[3]) ?? 0;
          }
        } else if (tagName.startsWith('build')) {
          // 格式: build322
          buildNumber = int.tryParse(tagName.substring(5)) ?? 0;
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
          // 使用默认链接
          downloadUrl = 'https://github.com/BiliNico-com/91Download-Mobile/releases/latest/download/app-release.apk';
        }
        
        return VersionInfo(
          version: version,
          buildNumber: buildNumber,
          downloadUrl: downloadUrl,
          releaseNotes: body,
          releaseDate: publishedAt.split('T').first,
        );
      }
    } catch (e) {
      debugPrint('GitHub API 检查更新失败: $e，尝试备用方案...');
    }
    
    // 备用：读取 version.json
    try {
      final response = await _dio.get(_versionJsonUrl, options: Options(
        receiveTimeout: Duration(seconds: 10),
      ));
      
      if (response.statusCode == 200) {
        final data = response.data;
        final json = data is String ? jsonDecode(data) : data;
        return VersionInfo.fromJson(json);
      }
    } catch (e) {
      debugPrint('备用方案检查更新失败: $e');
    }
    
    return null;
  }

  /// 比较版本，返回 true 表示有新版本
  bool hasNewVersion(VersionInfo remote) {
    // 先比较版本号
    final localParts = _currentVersion.split('.');
    final remoteParts = remote.version.split('.');
    
    for (int i = 0; i < 3; i++) {
      final local = int.tryParse(localParts.length > i ? localParts[i] : '0') ?? 0;
      final remoteVal = int.tryParse(remoteParts.length > i ? remoteParts[i] : '0') ?? 0;
      
      if (remoteVal > local) return true;
      if (remoteVal < local) return false;
    }
    
    // 版本号相同，比较build号
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
      
      // 如果文件已存在，直接安装
      if (await file.exists()) {
        final result = await OpenFilex.open(filePath);
        return result.type == ResultType.done;
      }
      
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
              // 如果没有 total，显示已下载大小（MB）
              // 这里用负数标记，让 UI 知道
              onProgress(-received / (100 * 1024 * 1024)); // 转换为假百分比
            }
          }
        },
      );
      
      // 安装APK - 系统会自动处理安装权限请求
      final result = await OpenFilex.open(filePath);
      return result.type == ResultType.done;
    } catch (e) {
      debugPrint('下载更新失败: $e');
      return false;
    }
  }
}
