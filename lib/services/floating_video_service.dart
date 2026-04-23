import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/logger.dart';

/// 原生悬浮窗视频播放服务
/// 使用 MethodChannel 调用原生 Kotlin FloatingWindowService
/// 不再依赖 flutter_overlay_window 插件，彻底解决灰屏和抽动问题
class NativeFloatingService {
  static const _channel = MethodChannel('com.bilinico.download_91/floating_video');
  
  static bool _isFloating = false;
  static String? _currentVideoPath;
  static String? _currentTitle;
  
  /// 当前是否正在悬浮窗播放（基于本地状态）
  static bool get isFloating => _isFloating;
  
  /// 当前视频路径
  static String? get currentVideoPath => _currentVideoPath;
  
  /// 检查悬浮窗权限是否可用
  static Future<bool> isPermissionGranted() async {
    try {
      final result = await _channel.invokeMethod<bool>('getOverlayPermission');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }
  
  /// 请求悬浮窗权限（跳转系统设置页面）
  static Future<bool> requestPermission() async {
    try {
      await _channel.invokeMethod('requestOverlayPermission');
      // 注意：权限请求是异步的，需要用户在系统设置中手动开启
      // 这里返回 true 仅表示已发起请求
      logger.logSync('NativeFloating', '已跳转到悬浮窗权限设置页面');
      return true;
    } catch (e) {
      logger.logSync('NativeFloating', '请求悬浮窗权限失败: $e');
      return false;
    }
  }
  
  /// 打开悬浮窗权限设置
  static Future<void> openSettings() async {
    try {
      await _channel.invokeMethod('openSettings');
    } catch (e) {
      debugPrint('[NativeFloating] 打开设置失败: $e');
    }
  }

  /// 计算合适的悬浮窗尺寸
  static (int width, int height) _calculateWindowSize() {
    // 固定较大默认尺寸，适合大多数手机屏幕
    const defaultWidth = 400;
    const defaultHeight = 250;
    
    print('[NativeFloating] 窗口大小: ${defaultWidth}x$defaultHeight');
    return (defaultWidth, defaultHeight);
  }

  /// 启动悬浮窗播放
  static Future<bool> startFloating({
    required String videoPath,
    required String title,
  }) async {
    try {
      print('[NativeFloating] 开始启动原生悬浮窗, videoPath: $videoPath');
      logger.logSync('NativeFloating', '开始启动原生悬浮窗, videoPath: $videoPath');
      
      // 如果已有悬浮窗在运行，先关闭
      if (_isFloating) {
        print('[NativeFloating] 检测到已有悬浮窗运行，先关闭...');
        await stopFloating();
        await Future.delayed(Duration(milliseconds: 300));
      }
      
      // 检查权限
      if (!await isPermissionGranted()) {
        debugPrint('[NativeFloating] 悬浮窗权限未授权，请求中...');
        final granted = await requestPermission();
        if (!granted) {
          debugPrint('[NativeFloating] 悬浮窗权限被拒绝');
          return false;
        }
        // 等待用户授权后重试（实际场景中应该监听 onResume 再检查）
      }
      
      debugPrint('[NativeFloating] 悬浮窗权限已授权');
      
      // 计算窗口大小
      final (width, height) = _calculateWindowSize();
      
      // 通过 MethodChannel 启动原生悬浮窗服务
      await _channel.invokeMethod('startFloating', {
        'path': videoPath,
        'title': title,
        'width': width,
        'height': height,
      });
      
      _isFloating = true;
      _currentVideoPath = videoPath;
      _currentTitle = title;
      
      debugPrint('[NativeFloating] 原生悬浮窗启动成功');
      logger.logSync('NativeFloating', '原生悬浮窗启动成功: $title');
      
      return true;
    } catch (e) {
      debugPrint('[NativeFloating] 启动悬浮窗失败: $e');
      logger.logSync('NativeFloating', '启动悬浮窗失败: $e');
      return false;
    }
  }
  
  /// 关闭悬浮窗
  static Future<bool> stopFloating() async {
    try {
      await _channel.invokeMethod('stopFloating');
      _isFloating = false;
      _currentVideoPath = null;
      _currentTitle = null;
      debugPrint('[NativeFloating] 悬浮窗已关闭');
      return true;
    } catch (e) {
      debugPrint('[NativeFloating] 关闭悬浮窗失败: $e');
      // 即使关闭失败也重置状态
      _isFloating = false;
      _currentVideoPath = null;
      _currentTitle = null;
      return false;
    }
  }
  
  /// 暂停播放
  static Future<void> pause() async {
    try {
      await _channel.invokeMethod('pauseVideo');
    } catch (e) {
      debugPrint('[NativeFloating] 暂停失败: $e');
    }
  }
  
  /// 恢复播放
  static Future<void> play() async {
    try {
      await _channel.invokeMethod('playVideo');
    } catch (e) {
      debugPrint('[NativeFloating] 播放失败: $e');
    }
  }
  
  /// 跳转到指定位置
  static Future<void> seekTo(int positionMs) async {
    try {
      await _channel.invokeMethod('seekTo', {
        'position': positionMs,
      });
    } catch (e) {
      debugPrint('[NativeFloating] seek 失败: $e');
    }
  }
}

// ========== 兼容别名：保持原有 API 不变 ==========
// 由于 Dart 不继承静态成员，这里手动转发所有静态方法

class FloatingVideoService {
  static bool get isFloating => NativeFloatingService.isFloating;
  static String? get currentVideoPath => NativeFloatingService.currentVideoPath;
  
  static Future<bool> isPermissionGranted() => NativeFloatingService.isPermissionGranted();
  static Future<bool> requestPermission() => NativeFloatingService.requestPermission();
  static Future<void> openSettings() => NativeFloatingService.openSettings();
  static Future<bool> startFloating({required String videoPath, required String title}) =>
      NativeFloatingService.startFloating(videoPath: videoPath, title: title);
  static Future<bool> stopFloating() => NativeFloatingService.stopFloating();
  static Future<void> pause() => NativeFloatingService.pause();
  static Future<void> play() => NativeFloatingService.play();
  static Future<void> seekTo(int positionMs) => NativeFloatingService.seekTo(positionMs);
}
