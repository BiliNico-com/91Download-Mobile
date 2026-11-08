import 'package:flutter/material.dart';

/// 设计令牌（取自 UI 重构原型 _ui_v2.html）
///
/// 原型里所有颜色、圆角、间距都收敛到这几个词上，页面代码只引用语义名
/// （surface / surface2 / text2 ...），不再各处硬编码 0xFFxxxxxx。
/// 深浅两套值一一对应，页面里统一写 final t = AppTokens.of(context);
class AppTokens {
  final bool dark;
  const AppTokens._(this.dark);

  static AppTokens of(BuildContext context) =>
      AppTokens._(Theme.of(context).brightness == Brightness.dark);

  static const AppTokens light = AppTokens._(false);
  static const AppTokens darkMode = AppTokens._(true);

  // ── 主色（深浅共用）──
  static const Color blue = Color(0xFF1565C0);
  static const Color blue2 = Color(0xFF2E7DE0);
  static const Color blueL = Color(0xFF64B5F6);

  // ── 语义色 ──
  Color get success => dark ? const Color(0xFF3DD9A0) : const Color(0xFF0E8A63);
  Color get successSoft =>
      dark ? const Color(0xFF0E8A63).withOpacity(0.18) : const Color(0xFFE3F5EE);
  Color get warning => dark ? const Color(0xFFF0A93B) : const Color(0xFFB26B00);
  Color get warningSoft =>
      dark ? const Color(0xFFB26B00).withOpacity(0.20) : const Color(0xFFFFF3DF);
  Color get danger => dark ? const Color(0xFFFF6B6B) : const Color(0xFFC62828);
  Color get dangerSoft =>
      dark ? const Color(0xFFC62828).withOpacity(0.20) : const Color(0xFFFDECEC);

  // ── 强调色（选中态、链接、主按钮）──
  Color get accent => dark ? blueL : blue;
  Color get accentSoft => dark ? const Color(0xFF1565C0).withOpacity(0.24) : const Color(0xFFE7F1FD);
  Color get accentSoft2 => dark ? const Color(0xFF1565C0).withOpacity(0.34) : const Color(0xFFD3E5FB);

  // ── 背景与表面 ──
  Color get bg => dark ? const Color(0xFF0E1218) : const Color(0xFFF4F6FA);
  Color get surface => dark ? const Color(0xFF171C24) : Colors.white;
  Color get surface2 => dark ? const Color(0xFF1E242E) : const Color(0xFFF1F4F9);
  Color get surface3 => dark ? const Color(0xFF262E3A) : const Color(0xFFE8EDF6);

  // ── 文字 ──
  Color get text1 => dark ? const Color(0xFFEAF0F8) : const Color(0xFF0E1726);
  Color get text2 => dark ? const Color(0xFFA4B0C1) : const Color(0xFF5B6675);
  Color get text3 => dark ? const Color(0xFF6E7A8C) : const Color(0xFF93A0B0);

  Color get line => dark ? const Color(0xFF2A323E) : const Color(0xFFE4E9F2);

  /// 卡片阴影：深色下改用描边，避免阴影糊在深底上
  List<BoxShadow>? get cardShadow =>
      dark ? null : [
            BoxShadow(
              color: const Color(0xFF0E1726).withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ];

  Border? get cardBorder =>
      Border.all(color: line, width: dark ? 0.8 : 1);
}

/// 圆角常量（与原型一致）
class AppRadius {
  static const double sm = 8;
  static const double md = 11;
  static const double lg = 13;
  static const double xl = 15;
  static const double xxl = 18;
  static const double pill = 999;
}
