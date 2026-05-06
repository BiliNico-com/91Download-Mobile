import 'package:flutter/services.dart';

/// PiP (Picture-in-Picture) 服务
/// 支持 Android 8.0+ 画中画模式
class PipService {
  static const _channel = MethodChannel('com.bilinico.download_91/pip');
  
  /// 检查 PiP 是否可用
  static Future<bool> isAvailable() async {
    try {
      final result = await _channel.invokeMethod<bool>('isPipAvailable');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }
  
  /// 检查当前是否处于 PiP 模式
  static Future<bool> isInPipMode() async {
    try {
      final result = await _channel.invokeMethod<bool>('isInPipMode');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }
  
  /// 进入 PiP 模式
  /// [aspectRatio] 画中画窗口的宽高比，默认 16:9
  static Future<bool> enterPipMode({double aspectRatio = 16 / 9}) async {
    try {
      final result = await _channel.invokeMethod<bool>('enterPip', {
        'aspectRatio': aspectRatio,
      });
      return result ?? false;
    } catch (e) {
      return false;
    }
  }
  
  /// 更新 PiP 参数
  /// 在 PiP 模式下可以调整窗口比例
  static Future<bool> updatePipParams({double aspectRatio = 16 / 9}) async {
    try {
      final result = await _channel.invokeMethod<bool>('updatePipParams', {
        'aspectRatio': aspectRatio,
      });
      return result ?? false;
    } catch (e) {
      return false;
    }
  }
}
