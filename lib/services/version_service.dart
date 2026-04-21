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
  static const String _versionUrl = 'https://raw.githubusercontent.com/BiliNico-com/91Download-Mobile/main/version.json';
  
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
    try {
      final response = await _dio.get(_versionUrl, options: Options(
        receiveTimeout: Duration(seconds: 10),
      ));
      
      if (response.statusCode == 200) {
        final data = response.data;
        final json = data is String ? jsonDecode(data) : data;
        return VersionInfo.fromJson(json);
      }
    } catch (e) {
      debugPrint('检查更新失败: $e');
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
        onReceiveProgress: (received, total) {
          if (total > 0 && onProgress != null) {
            onProgress(received / total);
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
