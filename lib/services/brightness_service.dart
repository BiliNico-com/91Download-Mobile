import 'package:flutter/services.dart';

/// 亮度控制服务 - 使用原生 Platform Channel 实现
class BrightnessService {
  static const _channel = MethodChannel('com.example.download_91/brightness');
  
  /// 获取当前亮度 (0.0 - 1.0)
  static Future<double> getBrightness() async {
    try {
      final result = await _channel.invokeMethod<double>('getBrightness');
      return result ?? 0.5;
    } catch (e) {
      return 0.5;
    }
  }
  
  /// 设置亮度 (0.0 - 1.0)
  static Future<void> setBrightness(double brightness) async {
    try {
      await _channel.invokeMethod('setBrightness', {
        'brightness': brightness.clamp(0.0, 1.0),
      });
    } catch (e) {
      // 忽略错误
    }
  }
  
  /// 保存当前亮度
  static Future<void> saveBrightness() async {
    try {
      await _channel.invokeMethod('saveBrightness');
    } catch (e) {
      // 忽略错误
    }
  }
  
  /// 恢复保存的亮度
  static Future<void> restoreBrightness() async {
    try {
      await _channel.invokeMethod('restoreBrightness');
    } catch (e) {
      // 忽略错误
    }
  }
  
  /// 重置为系统默认亮度
  static Future<void> resetBrightness() async {
    try {
      await _channel.invokeMethod('resetBrightness');
    } catch (e) {
      // 忽略错误
    }
  }
}
