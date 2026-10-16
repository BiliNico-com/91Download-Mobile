import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 亮度控制服务 - 使用原生 Platform Channel 实现
///
/// 仅调整本 App 窗口的亮度（`WindowManager.LayoutParams.screenBrightness`）：
/// - 不需要 WRITE_SETTINGS 权限
/// - 退出 App 后由系统自动还原，不会污染用户的系统亮度设置
class BrightnessService {
  static const _channel = MethodChannel('com.example.download_91/brightness');

  /// 原生端通道未注册（例如运行在桌面上）时只提示一次，避免刷屏
  static bool _warnedMissing = false;

  @visibleForTesting
  static void resetWarnFlag() => _warnedMissing = false;

  /// 获取当前亮度 (0.0 - 1.0)
  static Future<double> getBrightness() async {
    try {
      final result = await _channel.invokeMethod<double>('getBrightness');
      return (result ?? 0.5).clamp(0.0, 1.0);
    } catch (e) {
      _log('getBrightness', e);
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
      _log('setBrightness', e);
    }
  }

  /// 保存当前亮度，供退出播放时还原
  static Future<void> saveBrightness() async {
    try {
      await _channel.invokeMethod('saveBrightness');
    } catch (e) {
      _log('saveBrightness', e);
    }
  }

  /// 恢复保存的亮度；返回是否确实恢复了
  static Future<bool> restoreBrightness() async {
    try {
      final ok = await _channel.invokeMethod<bool>('restoreBrightness');
      return ok ?? false;
    } catch (e) {
      _log('restoreBrightness', e);
      return false;
    }
  }

  /// 重置为系统默认亮度
  static Future<void> resetBrightness() async {
    try {
      await _channel.invokeMethod('resetBrightness');
    } catch (e) {
      _log('resetBrightness', e);
    }
  }

  static void _log(String method, Object error) {
    // 通道不存在属于「原生未实现」，提示一次即可；其余错误照常打印
    if (error is MissingPluginException) {
      if (_warnedMissing) return;
      _warnedMissing = true;
      debugPrint('[Brightness] 原生亮度通道不可用，亮度调节将不生效: $error');
      return;
    }
    debugPrint('[Brightness] $method 失败: $error');
  }
}
