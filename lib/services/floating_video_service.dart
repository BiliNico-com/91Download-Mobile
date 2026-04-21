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
  static OverlayController? _overlayController;
  
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
      // 直接请求权限
      final result = await FlutterOverlayWindow.requestPermission();
      return result ?? false;
    } catch (e) {
      debugPrint('请求悬浮窗权限失败: $e');
      return false;
    }
  }
  
  /// 打开悬浮设置页面（用户需要在此授权）
  static Future<void> openSettings() async {
    try {
      await FlutterOverlayWindow.openSettings();
    } catch (e) {
      debugPrint('打开悬浮窗设置失败: $e');
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
          // 尝试打开设置页面
          await openSettings();
          return false;
        }
      }
      
      _currentVideoPath = videoPath;
      _currentTitle = title;
      
      // 创建悬浮窗配置
      final config = OverlayConfig(
        alignment: OverlayAlignment.centerRight,
        flag: OverlayFlag.clickThrough,
        visibility: Visibility.visible,
        positionGravity: PositionGravity.left,
        width: 200,
        height: 360,
      );
      
      // 显示悬浮窗
      final result = await FlutterOverlayWindow.showOverlay(config);
      
      if (result ?? false) {
        _isFloating = true;
        
        // 等待悬浮窗创建完成，然后通过 channel 传递视频信息
        await Future.delayed(Duration(milliseconds: 500));
        await _sendVideoToOverlay(videoPath, title);
        
        return true;
      }
      
      return false;
    } catch (e) {
      debugPrint('启动悬浮窗失败: $e');
      return false;
    }
  }
  
  /// 发送视频信息到悬浮窗
  static Future<void> _sendVideoToOverlay(String videoPath, String title) async {
    try {
      await _channel.invokeMethod('setVideo', {
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
  static Future<void> updateSize(double width, double height) async {
    try {
      final config = OverlayConfig(
        alignment: OverlayAlignment.center,
        flag: OverlayFlag.clickThrough,
        visibility: Visibility.visible,
        width: width,
        height: height,
      );
      await FlutterOverlayWindow.updateOverlay(config);
    } catch (e) {
      debugPrint('更新悬浮窗大小失败: $e');
    }
  }
  
  /// 发送播放控制命令到悬浮窗
  static Future<void> sendCommand(String command, [Map<String, dynamic>? args]) async {
    try {
      await _channel.invokeMethod(command, args ?? {});
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
  
  /// 获取悬浮窗播放状态
  static Future<Map<String, dynamic>?> getPlaybackState() async {
    try {
      final result = await _channel.invokeMethod('getPlaybackState');
      if (result != null) {
        return Map<String, dynamic>.from(result);
      }
      return null;
    } catch (e) {
      debugPrint('获取播放状态失败: $e');
      return null;
    }
  }
}
