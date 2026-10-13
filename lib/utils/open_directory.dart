import 'dart:io';
import 'package:flutter/services.dart';

/// 打开系统文件管理器并跳转到指定目录
///
/// 为什么需要原生实现：
/// Flutter 层没有直接"打开目录"的能力。Android 需要构造
/// `ACTION_VIEW` + `DocumentsContract.buildDocumentUri` 的 Intent，
/// 才能在文件管理器中定位到具体目录（而不是只打开文件管理器的根界面）。
class OpenDirectoryPlugin {
  static const _channel = MethodChannel('com.bilinico.download_91/open_directory');

  /// 打开指定目录，返回是否成功调起
  static Future<bool> openDirectory(String path) async {
    // 非 Android 平台暂不支持，直接返回 false 走兜底提示
    if (!Platform.isAndroid) return false;

    try {
      final result = await _channel.invokeMethod<bool>(
        'openDirectory',
        {'path': path},
      );
      return result ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // 原生侧未注册（例如未重新构建 Android 工程）
      return false;
    }
  }
}
