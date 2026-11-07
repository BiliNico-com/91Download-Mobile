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
  static const String _opacityPrefKey = 'glassOpacity';

  /// 玻璃默认不透明度（0~1 的「浓度」上限）。
  ///
  /// 顶栏与底栏共用这一个值，保证两侧观感统一；
  /// 用户在设置页拖动滑块时改的是这个上限。
  static const double defaultGlassOpacity = 0.72;

  /// 是否启用玻璃拟态。
  ///
  /// 用 ValueNotifier 而非静态 bool，是为了让切换后界面立即重建，
  /// 不必重启 App。
  static final ValueNotifier<bool> glassEnabled = ValueNotifier<bool>(true);

  /// 玻璃不透明度（0.2 ~ 1.0）。
  ///
  /// 同样用 ValueNotifier，拖动滑块时所有毛玻璃表面实时跟随。
  static final ValueNotifier<double> glassOpacity =
      ValueNotifier<double>(defaultGlassOpacity);

  static bool get isGlassEnabled => glassEnabled.value;

  /// 把「不透明度」换算成某主题下可用的叠加色。
  ///
  /// 深色主题用黑色叠加、浅色用白色叠加——「浓度」语义一致，
  /// 都是指挡住所透背景的程度，只是叠加色随主题取反。
  static Color glassFill(bool isDark, double opacity, {double scale = 1.0}) {
    final value = (opacity * scale).clamp(0.0, 1.0);
    return isDark
        ? Colors.black.withOpacity(value)
        : Colors.white.withOpacity(value);
  }

  /// 顶栏（AppBar / 折叠头）的玻璃底色。
  ///
  /// [collapseRatio] 0 = 完全展开，1 = 完全收起。
  /// 收起后稍微更实一点，避免列表内容从标题后面透出来。
  /// 浅色最多再加 16% 浓度，深色收到 0.85 封顶。
  static Color headerGlassFill(bool isDark, double collapseRatio) {
    final base = glassOpacity.value;
    final t = collapseRatio.clamp(0.0, 1.0);
    final extra = isDark ? 0.13 : 0.16;
    return glassFill(isDark, base, scale: 1.0 + extra * t);
  }

  /// 底栏（NavigationBar）的玻璃底色。
  ///
  /// 与顶栏同用 [glassOpacity]；底栏不随滚动变化，
  /// 取展开态浓度，这样静止时上下两侧颜色一致。
  static Color navBarGlassFill(bool isDark) {
    return glassFill(isDark, glassOpacity.value);
  }

  /// 玻璃表面描边色（顶栏/底栏通用）
  static Color glassBorderColor(bool isDark) {
    return isDark
        ? Colors.white.withOpacity(0.08)
        : Colors.black.withOpacity(0.06);
  }

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

  /// 设置玻璃不透明度并持久化（0.2 ~ 1.0）
  static Future<void> setGlassOpacity(double v) async {
    final clamped = v.clamp(0.2, 1.0).toDouble();
    glassOpacity.value = clamped;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_opacityPrefKey, clamped);
    } catch (_) {}
  }

  /// 启动时读取上次的选择
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      glassEnabled.value = prefs.getBool(_prefKey) ?? true;
      final saved = prefs.getDouble(_opacityPrefKey);
      if (saved != null) {
        glassOpacity.value = saved.clamp(0.2, 1.0).toDouble();
      }
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
