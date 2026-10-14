import 'package:flutter/material.dart';

/// 应用主题配置
/// 
/// 统一管理颜色、字体、圆角等设计变量，避免各页面硬编码色值
class AppTheme {
  // ─────────────────── 主色 ───────────────────
  static const Color primaryColor = Colors.blue;
  static const Color primaryLight = Color(0xFF64B5F6);
  static const Color primaryDark = Color(0xFF1565C0);

  // ─────────────────── 功能色 ───────────────────
  static const Color successColor = Colors.green;
  static const Color errorColor = Colors.red;
  static const Color warningColor = Colors.orange;
  static const Color infoColor = Colors.blue;

  // ─────────────────── 中性色 ───────────────────
  static const Color textPrimary = Color(0xFF212121);
  static const Color textSecondary = Color(0xFF757575);
  static const Color textHint = Color(0xFF9E9E9E);
  static const Color dividerColor = Color(0xFFE0E0E0);
  static const Color scaffoldBackground = Color(0xFFF5F5F5);
  static const Color cardBackground = Colors.white;

  // ─────────────────── 暗黑模式色 ───────────────────
  //
  // 层次说明：原实现 darkSurface(0x1E) 与 darkBackground(0x12) 亮度差过小，
  // 深色模式下卡片与背景几乎糊在一起、看不出层级。
  // 现在拉开到 0x12 / 0x24 / 0x2C 三级，并给卡片加一层极淡描边，
  // 即使在不支持阴影的场景（如深色 OLED）也能区分出卡片边界。
  static const Color darkBackground = Color(0xFF121212);
  static const Color darkSurface = Color(0xFF242424);
  static const Color darkSurfaceHigh = Color(0xFF2E2E2E);
  static const Color darkTextPrimary = Color(0xFFE0E0E0);
  static const Color darkTextSecondary = Color(0xFFB0B0B0);

  /// 深色模式下卡片描边（极淡白，用于勾勒边界）
  static const Color darkCardBorder = Color(0xFF343434);

  /// 深色模式下输入框/次级容器填充
  static const Color darkInputFill = Color(0xFF2C2C2C);

  // ─────────────────── 间距 ───────────────────
  static const double spacingXs = 4.0;
  static const double spacingSm = 8.0;
  static const double spacingMd = 12.0;
  static const double spacingLg = 16.0;
  static const double spacingXl = 24.0;

  // ─────────────────── 圆角 ───────────────────
  //
  // 统一为 4 档。此前代码里散落 12 种值（2/3/4/6/8/10/12/14/16/22/24/40），
  // 既有圆角风格无法一处调整，观感也不统一。新代码请只用下面四档：
  //   radiusSm(4)  小标签、角标
  //   radiusMd(8)  按钮、输入框、列表卡片
  //   radiusLg(12) 卡片、面板
  //   radiusXl(16) 弹窗、大容器
  //   radiusPill   胶囊（等同于高度一半，用于页码胶囊、关注按钮等）
  static const double radiusSm = 4.0;
  static const double radiusMd = 8.0;
  static const double radiusLg = 12.0;
  static const double radiusXl = 16.0;

  /// 胶囊圆角：足够大即可呈现全圆角效果
  static const double radiusPill = 999.0;

  /// 常用 BorderRadius 快捷方式（避免各处重复写 circular）
  static const BorderRadius brSm = BorderRadius.all(Radius.circular(radiusSm));
  static const BorderRadius brMd = BorderRadius.all(Radius.circular(radiusMd));
  static const BorderRadius brLg = BorderRadius.all(Radius.circular(radiusLg));
  static const BorderRadius brXl = BorderRadius.all(Radius.circular(radiusXl));
  static const BorderRadius brPill =
      BorderRadius.all(Radius.circular(radiusPill));

  // ─────────────────── 控件尺寸 ───────────────────
  //
  // 此前按钮尺寸散落 36/40/48/64，图标散落 10~32 十余种。
  // 统一为三档按钮 + 四档图标，保证同类控件在不同页面一致。
  static const double buttonSm = 36.0;
  static const double buttonMd = 44.0;
  static const double buttonLg = 56.0;

  static const double iconSm = 16.0;
  static const double iconMd = 20.0;
  static const double iconLg = 24.0;
  static const double iconXl = 32.0;

  // ─────────────────── 阴影 ───────────────────
  static List<BoxShadow> get cardShadow => [
    BoxShadow(
      color: Colors.black.withOpacity(0.05),
      blurRadius: 8,
      offset: const Offset(0, 2),
    ),
  ];

  static List<BoxShadow> get elevatedShadow => [
    BoxShadow(
      color: Colors.black.withOpacity(0.1),
      blurRadius: 16,
      offset: const Offset(0, 4),
    ),
  ];

  // ─────────────────── 文本样式 ───────────────────
  static TextStyle get titleLarge => const TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.bold,
    color: textPrimary,
  );

  static TextStyle get titleMedium => const TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: textPrimary,
  );

  static TextStyle get bodyMedium => const TextStyle(
    fontSize: 14,
    color: textPrimary,
  );

  static TextStyle get bodySmall => const TextStyle(
    fontSize: 12,
    color: textSecondary,
  );

  static TextStyle get caption => const TextStyle(
    fontSize: 10,
    color: textHint,
  );

  // ─────────────────── 亮色主题 ───────────────────
  static ThemeData get lightTheme => ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    primaryColor: primaryColor,
    scaffoldBackgroundColor: scaffoldBackground,
    colorScheme: const ColorScheme.light(
      primary: primaryColor,
      secondary: primaryLight,
      surface: cardBackground,
      error: errorColor,
      onPrimary: Colors.white,
      onSurface: textPrimary,
    ),
    cardTheme: CardTheme(
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusMd),
      ),
    ),
    appBarTheme: const AppBarTheme(
      elevation: 0,
      centerTitle: true,
      backgroundColor: cardBackground,
      foregroundColor: textPrimary,
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.grey[100],
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusLg),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: spacingLg, vertical: spacingMd),
    ),
    dividerTheme: const DividerThemeData(
      color: dividerColor,
      thickness: 1,
    ),
  );

  // ─────────────────── 暗黑主题 ───────────────────
  static ThemeData get darkTheme => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    primaryColor: primaryLight,
    scaffoldBackgroundColor: darkBackground,
    colorScheme: const ColorScheme.dark(
      primary: primaryLight,
      secondary: primaryColor,
      surface: darkSurface,
      error: Color(0xFFCF6679),
      onPrimary: Colors.black,
      onSurface: darkTextPrimary,
    ),
    cardTheme: CardTheme(
      elevation: 0,
      color: darkSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        // 深色下用描边替代阴影来划分层次
        side: const BorderSide(color: darkCardBorder, width: 0.8),
      ),
    ),
    appBarTheme: const AppBarTheme(
      elevation: 0,
      centerTitle: true,
      backgroundColor: darkSurface,
      foregroundColor: darkTextPrimary,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: darkInputFill,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusLg),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: spacingLg, vertical: spacingMd),
    ),
    dividerTheme: const DividerThemeData(
      color: darkCardBorder,
      thickness: 1,
    ),
  );
}
