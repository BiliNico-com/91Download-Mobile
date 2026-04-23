import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:video_player/video_player.dart';
import '../utils/logger.dart';

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
      logger.logSync('FloatingVideo', '请求悬浮窗权限失败: $e');
      return false;
    }
  }
  
  /// 计算合适的悬浮窗尺寸（视频分辨率的50%）
  static Future<(int width, int height)> _calculateWindowSize(String videoPath) async {
    try {
      final controller = VideoPlayerController.file(File(videoPath));
      await controller.initialize();
      
      // 获取视频实际分辨率
      final videoWidth = controller.value.size.width;
      final videoHeight = controller.value.size.height;
      await controller.dispose();
      
      // 计算窗口大小为视频分辨率的50%
      final windowWidth = (videoWidth * 0.5).round();
      final windowHeight = (videoHeight * 0.5).round();
      
      // 限制窗口大小范围 - 增大最小尺寸
      final finalWidth = windowWidth.clamp(240, 450);
      final finalHeight = windowHeight.clamp(160, 320);
      
      print('[FloatingVideo] 视频分辨率: ${videoWidth}x$videoHeight, 窗口大小: ${finalWidth}x$finalHeight');
      
      return (finalWidth, finalHeight);
    } catch (e) {
      print('[FloatingVideo] 计算窗口大小失败: $e');
      // 默认尺寸 - 增大
      return (320, 200);
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
      print('[FloatingVideo] 开始启动悬浮窗, videoPath: $videoPath');
      logger.logSync('FloatingVideo', '开始启动悬浮窗, videoPath: $videoPath');
      
      // 如果已有悬浮窗在运行，先关闭
      if (_isFloating) {
        print('[FloatingVideo] 检测到已有悬浮窗运行，先关闭...');
        await stopFloating();
        await Future.delayed(Duration(milliseconds: 300));
      }
      
      // 检查权限
      if (!await isPermissionGranted()) {
        debugPrint('[FloatingVideo] 悬浮窗权限未授权，请求中...');
        logger.logSync('FloatingVideo', '悬浮窗权限未授权，请求中...');
        final granted = await requestPermission();
        if (!granted) {
          debugPrint('[FloatingVideo] 悬浮窗权限被拒绝');
        logger.logSync('FloatingVideo', '悬浮窗权限被拒绝');
          return false;
        }
      }
      
      debugPrint('[FloatingVideo] 悬浮窗权限已授权');
      logger.logSync('FloatingVideo', '悬浮窗权限已授权');
      _currentVideoPath = videoPath;
      _currentTitle = title;
      
      // 根据视频比例计算窗口大小
      final (width, height) = await _calculateWindowSize(videoPath);
      print('[FloatingVideo] 窗口大小: ${width}x$height');
      logger.logSync('FloatingVideo', '窗口大小: ${width}x$height');
      
      // 显示悬浮窗 - 使用正确的命名参数
      debugPrint('[FloatingVideo] 调用 showOverlay...');
      logger.logSync('FloatingVideo', '调用 showOverlay...');
      await FlutterOverlayWindow.showOverlay(
        height: height,
        width: width,
        alignment: OverlayAlignment.centerRight,
        flag: OverlayFlag.defaultFlag,
        overlayTitle: title,
        overlayContent: '视频播放中',
        enableDrag: true,
        positionGravity: PositionGravity.right,
      );
      
      _isFloating = true;
      debugPrint('[FloatingVideo] showOverlay 调用成功');
      logger.logSync('FloatingVideo', 'showOverlay 调用成功');
      
      // 发送视频信息到悬浮窗（等待悬浮窗初始化完成）
      await Future.delayed(Duration(milliseconds: 800));
      await _sendVideoToOverlay(videoPath, title, width, height);
      
      return true;
    } catch (e) {
      debugPrint('[FloatingVideo] 启动悬浮窗失败: $e');
      logger.logSync('FloatingVideo', '启动悬浮窗失败: $e');
      return false;
    }
  }
  
  /// 发送视频信息到悬浮窗
  static Future<void> _sendVideoToOverlay(String videoPath, String title, int width, int height) async {
    try {
      // 使用 shareData 发送数据到悬浮窗
      await FlutterOverlayWindow.shareData({
        'path': videoPath,
        'title': title,
        'width': width,
        'height': height,
      });
    } catch (e) {
      debugPrint('发送视频信息到悬浮窗失败: $e');
      logger.logSync('FloatingVideo', '发送视频信息到悬浮窗失败: $e');
    }
  }
  
  /// 调整悬浮窗大小
  static Future<void> resizeOverlay(int width, int height) async {
    try {
      await FlutterOverlayWindow.resizeOverlay(width, height, true);
      // 通知悬浮窗新尺寸
      await FlutterOverlayWindow.shareData({
        'width': width,
        'height': height,
      });
    } catch (e) {
      debugPrint('调整悬浮窗大小失败: $e');
      logger.logSync('FloatingVideo', '调整悬浮窗大小失败: $e');
    }
  }
  
  /// 关闭悬浮窗
  static Future<bool> stopFloating() async {
    try {
      // 修复：始终尝试关闭悬浮窗并重置状态，即使 _isFloating 为 false
      // 这样可以处理异常情况（如进程被杀死后状态不一致）
      await FlutterOverlayWindow.closeOverlay();
      final wasFloating = _isFloating;
      _isFloating = false;
      _currentVideoPath = null;
      _currentTitle = null;
      return true;
    } catch (e) {
      debugPrint('关闭悬浮窗失败: $e');
      logger.logSync('FloatingVideo', '关闭悬浮窗失败: $e');
      // 修复：即使关闭失败也重置状态，避免状态残留
      _isFloating = false;
      _currentVideoPath = null;
      _currentTitle = null;
      return false;
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
      logger.logSync('FloatingVideo', '发送命令到悬浮窗失败: $e');
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
