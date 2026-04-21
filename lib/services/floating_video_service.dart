import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

/// 悬浮窗视频播放服务
/// 使用 flutter_overlay_window 插件实现悬浮窗功能
class FloatingVideoService {
  static const _channel = MethodChannel('com.bilinico.download_91/floating_video');
  
  static String? _currentVideoPath;
  static String? _currentTitle;
  static bool _isFloating = false;
  
  /// 当前是否正在悬浮窗播放
  static bool get isFloating => _isFloating;
  
  /// 当前视频路径
  static String? get currentVideoPath => _currentVideoPath;
  
  /// 检查悬浮窗权限是否可用
  static Future<bool> isPermissionGranted() async {
    try {
      final result = await FlutterOverlayWindow.isPermissionGranted();
      return result ?? false;
    } catch (e) {
      return false;
    }
  }
  
  /// 请求悬浮窗权限
  static Future<bool> requestPermission() async {
    try {
      final result = await FlutterOverlayWindow.requestPermission();
      return result ?? false;
    } catch (e) {
      debugPrint('请求悬浮窗权限失败: $e');
      return false;
    }
  }
  
  /// 启动悬浮窗播放
  /// [videoPath] 视频文件路径
  /// [title] 视频标题
  static Future<bool> startFloating({
    required String videoPath,
    required String title,
  }) async {
    try {
      // 检查权限
      if (!await isPermissionGranted()) {
        final granted = await requestPermission();
        if (!granted) {
          return false;
        }
      }
      
      _currentVideoPath = videoPath;
      _currentTitle = title;
      
      // 显示悬浮窗 - 使用正确的命名参数
      await FlutterOverlayWindow.showOverlay(
        height: 200,
        width: 300,
        alignment: OverlayAlignment.centerRight,
        flag: OverlayFlag.defaultFlag,
        overlayTitle: title,
        overlayContent: '视频播放中',
        enableDrag: true,
        positionGravity: PositionGravity.right,
      );
      
      _isFloating = true;
      
      // 发送视频信息到悬浮窗
      await Future.delayed(Duration(milliseconds: 500));
      await _sendVideoToOverlay(videoPath, title);
      
      return true;
    } catch (e) {
      debugPrint('启动悬浮窗失败: $e');
      return false;
    }
  }
  
  /// 发送视频信息到悬浮窗
  static Future<void> _sendVideoToOverlay(String videoPath, String title) async {
    try {
      // 使用 shareData 发送数据到悬浮窗
      await FlutterOverlayWindow.shareData({
        'path': videoPath,
        'title': title,
      });
    } catch (e) {
      debugPrint('发送视频信息到悬浮窗失败: $e');
    }
  }
  
  /// 关闭悬浮窗
  static Future<bool> stopFloating() async {
    try {
      if (_isFloating) {
        await FlutterOverlayWindow.closeOverlay();
        _isFloating = false;
        _currentVideoPath = null;
        _currentTitle = null;
      }
      return true;
    } catch (e) {
      debugPrint('关闭悬浮窗失败: $e');
      return false;
    }
  }
  
  /// 更新悬浮窗大小
  static Future<void> updateSize(int width, int height) async {
    try {
      await FlutterOverlayWindow.resizeOverlay(width, height);
    } catch (e) {
      debugPrint('更新悬浮窗大小失败: $e');
    }
  }
  
  /// 发送播放控制命令到悬浮窗
  static Future<void> sendCommand(String command, [Map<String, dynamic>? args]) async {
    try {
      await FlutterOverlayWindow.shareData({
        'command': command,
        ...?args,
      });
    } catch (e) {
      debugPrint('发送命令到悬浮窗失败: $e');
    }
  }
  
  /// 播放/暂停
  static Future<void> togglePlayPause() async {
    await sendCommand('togglePlayPause');
  }
  
  /// 跳转到指定位置
  static Future<void> seekTo(Duration position) async {
    await sendCommand('seekTo', {'position': position.inMilliseconds});
  }
  
  /// 监听悬浮窗事件
  static Stream<dynamic> get overlayListener {
    return FlutterOverlayWindow.overlayListener;
  }
}
