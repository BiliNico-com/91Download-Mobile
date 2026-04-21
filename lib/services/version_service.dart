import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

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

  String get fullVersion => 'v$version build$buildNumber';
}

/// 版本服务
class VersionService {
  static const String _versionUrl = 'https://raw.githubusercontent.com/BiliNico-com/91Download-Mobile/main/version.json';
  static const String _currentVersion = '1.0.5';
  static const int _currentBuild = 300;  // 自动更新：git rev-list --count HEAD

  static String get currentVersion => _currentVersion;
  static int get currentBuild => _currentBuild;
  static String get fullVersion => 'v$_currentVersion build$_currentBuild';

  final Dio _dio = Dio();

  /// 检查更新
  Future<VersionInfo?> checkUpdate() async {
    try {
      final response = await _dio.get(_versionUrl, options: Options(
        receiveTimeout: Duration(seconds: 10),
      ));
      
      if (response.statusCode == 200) {
        final json = response.data;
        if (json is String) {
          json = jsonDecode(json);
        }
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
        await OpenFilex.open(filePath);
        return true;
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
      
      // 安装APK
      await OpenFilex.open(filePath);
      return true;
    } catch (e) {
      debugPrint('下载更新失败: $e');
      return false;
    }
  }
}
