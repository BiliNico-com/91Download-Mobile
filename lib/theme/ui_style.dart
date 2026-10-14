import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局 UI 风格开关
///
/// 提供「玻璃拟态（毛玻璃）」与「传统实心」两种观感，可在设置页实时切换。
/// 这样若觉得玻璃效果在低端机上卡顿或观感不佳，
/// 直接关掉即可回到传统样式，**无需回滚代码**。
///
/// 使用方式：把需要切换风格的地方包一层 [AdaptiveSurface]，
/// 而不是直接写死 BackdropFilter。
class UiStyle {
  UiStyle._();

  static const String _prefKey = 'glassEffectEnabled';

  /// 是否启用玻璃拟态。
  ///
  /// 用 ValueNotifier 而非静态 bool，是为了让切换后界面立即重建，
  /// 不必重启 App。
  static final ValueNotifier<bool> glassEnabled = ValueNotifier<bool>(true);

  static bool get isGlassEnabled => glassEnabled.value;

  /// 切换并持久化，重启后保持用户选择
  static Future<void> setGlassEnabled(bool v) async {
    glassEnabled.value = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, v);
    } catch (_) {
      // 持久化失败不影响本次生效
    }
  }

  /// 启动时读取上次的选择
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      glassEnabled.value = prefs.getBool(_prefKey) ?? true;
    } catch (_) {}
  }
}

/// 自适应容器：根据 [UiStyle.glassEnabled] 决定用毛玻璃还是实心色
///
/// 设计要点：
/// · **默认走实心底色**，避免低端机上 BackdropFilter 造成的掉帧；
///   只有开启玻璃时才叠加模糊层。
/// · 模糊强度、底色、描边集中在这里，页面不必各自调参。
class AdaptiveSurface extends StatelessWidget {
  final Widget child;

  /// 圆角
  final BorderRadius borderRadius;

  /// 是否使用更实的底色（用于需要更强对比的场合）
  final bool solid;

  /// 内边距
  final EdgeInsetsGeometry? padding;

  /// 玻璃关闭时使用的实心色；不传则按主题自动取
  final Color? fallbackColor;

  /// 模糊强度（玻璃开启时生效）
  final double blurSigma;

  const AdaptiveSurface({
    super.key,
    required this.child,
    this.borderRadius = AppThemeRadius.brLg,
    this.solid = false,
    this.padding,
    this.fallbackColor,
    this.blurSigma = 16,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: UiStyle.glassEnabled,
      builder: (context, glass, _) {
        final brightness = Theme.of(context).brightness;
        final isDark = brightness == Brightness.dark;

        // 玻璃关闭 → 直接给实心色，代价最低
        if (!glass) {
          return Container(
            padding: padding,
            decoration: BoxDecoration(
              color: fallbackColor ??
                  (solid
                      ? (isDark ? const Color(0xFF2E2E2E) : Colors.white)
                      : (isDark ? const Color(0xFF242424) : Colors.white)),
              borderRadius: borderRadius,
            ),
            child: child,
          );
        }

        // 玻璃开启 → 半透明 + 背景模糊
        final fill = solid
            ? (isDark
                ? Colors.black.withOpacity(0.55)
                : Colors.white.withOpacity(0.85))
            : (isDark
                ? Colors.white.withOpacity(0.10)
                : Colors.white.withOpacity(0.55));

        return ClipRRect(
          borderRadius: borderRadius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
            child: Container(
              padding: padding,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: borderRadius,
                border: Border.all(
                  color: Colors.white.withOpacity(isDark ? 0.14 : 0.30),
                  width: 0.8,
                ),
              ),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// 圆角快捷常量（与 AppTheme 保持一致，避免循环依赖单独放这里）
class AppThemeRadius {
  static const double sm = 4;
  static const double md = 8;
  static const double lg = 12;
  static const double xl = 16;
  static const double pill = 999;

  static const BorderRadius brSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius brMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius brLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius brXl = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius brPill = BorderRadius.all(Radius.circular(pill));
}
