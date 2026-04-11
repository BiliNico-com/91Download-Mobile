import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'pages/main_page.dart';
import 'services/app_state.dart';
import 'utils/logger.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 初始化日志
  
  runApp(const MyApp());
}

/// 主题状态包装组件，监听系统主题变化
class ThemeWrapper extends StatefulWidget {
  final Widget child;
  
  const ThemeWrapper({super.key, required this.child});
  
  @override
  State<ThemeWrapper> createState() => _ThemeWrapperState();
}

class _ThemeWrapperState extends State<ThemeWrapper> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }
  
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  
  @override
  void didChangePlatformBrightness() {
    // 系统主题变化时通知刷新
    final appState = context.read<AppState>();
    if (appState.themeMode == 2) {
      // 跟随系统模式，重新通知构建
      appState.notifyListeners();
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState(),
      child: Consumer<AppState>(
        builder: (context, appState, _) {
          return ThemeWrapper(
            child: MaterialApp(
              title: '91Download',
              debugShowCheckedModeBanner: false,
              // 根据主题模式选择主题数据
              theme: appState.themeMode == 0 ? _buildLightTheme() : null,
              darkTheme: appState.themeMode == 1 ? _buildDarkTheme() : _buildDarkTheme(),
              themeMode: appState.themeMode == 2 
                  ? ThemeMode.system  // 跟随系统
                  : (appState.themeMode == 0 ? ThemeMode.light : ThemeMode.dark),
              home: const MainPage(),
            ),
          );
        },
      ),
    );
  }
  
  /// 日间模式主题 - 确保对比度足够
  ThemeData _buildLightTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF6366F1),
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: Colors.grey[50],
      // 卡片背景 - 白色
      cardColor: Colors.white,
      // AppBar - 白色
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: Colors.black87,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),
      // 文字颜色 - 确保对比度
      textTheme: TextTheme(
        bodyLarge: TextStyle(color: Colors.black87),
        bodyMedium: TextStyle(color: Colors.black87),
        bodySmall: TextStyle(color: Colors.grey[700]),
        titleLarge: TextStyle(color: Colors.black87),
        titleMedium: TextStyle(color: Colors.black87),
        titleSmall: TextStyle(color: Colors.grey[700]),
      ),
      // 输入框
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.grey[400]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Color(0xFF6366F1), width: 2),
        ),
      ),
      // 按钮
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          foregroundColor: Colors.white,
        ),
      ),
      // 分割线
      dividerColor: Colors.grey[300],
    );
  }
  
  /// 夜间模式主题 - 使用Material Design暗色主题标准
  /// 背景色：#121212，重要文字白色，次要文字中灰色
  ThemeData _buildDarkTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF6366F1),
        brightness: Brightness.dark,
        surface: const Color(0xFF121212),
      ),
      // 深色背景 - 使用#121212而非纯黑
      scaffoldBackgroundColor: const Color(0xFF121212),
      // 卡片背景 - #1E1E1E
      cardColor: const Color(0xFF1E1E1E),
      // AppBar - 深色
      appBarTheme: AppBarTheme(
        backgroundColor: const Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
        iconTheme: IconThemeData(color: Colors.white),
      ),
      // 文字颜色 - 确保对比度
      // 主文字：白色（#FFFFFF），次文字：中灰色（#B0B0B0）
      textTheme: TextTheme(
        bodyLarge: TextStyle(color: Colors.white),        // 主文字白色
        bodyMedium: TextStyle(color: Colors.white),       // 主文字白色
        bodySmall: TextStyle(color: Color(0xFFB0B0B0)),   // 次文字中灰
        titleLarge: TextStyle(color: Colors.white),       // 标题白色
        titleMedium: TextStyle(color: Colors.white),      // 副标题白色
        titleSmall: TextStyle(color: Color(0xFFB0B0B0)),  // 小标题中灰
      ),
      // 输入框 - 确保边框可见
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderSide: BorderSide(color: Color(0xFF444444)),  // 深灰边框
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Color(0xFF444444)),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Color(0xFF6366F1), width: 2),  // 聚焦时蓝色边框
        ),
        fillColor: Color(0xFF2A2A2A),  // 输入框背景稍浅
        filled: true,
        hintStyle: TextStyle(color: Color(0xFF888888)),  // 提示文字灰色
      ),
      // 按钮
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: Color(0xFF6366F1),
        ),
      ),
      // 分割线
      dividerColor: Color(0xFF333333),
      // 图标颜色
      iconTheme: IconThemeData(color: Colors.white),
      // Switch
      switchTheme: SwitchThemeData(
        thumbColor: MaterialStateProperty.resolveWith((states) {
          if (states.contains(MaterialState.selected)) {
            return Color(0xFF6366F1);
          }
          return Colors.grey;
        }),
        trackColor: MaterialStateProperty.resolveWith((states) {
          if (states.contains(MaterialState.selected)) {
            return Color(0xFF6366F1).withOpacity(0.5);
          }
          return Colors.grey.withOpacity(0.3);
        }),
      ),
      // Chip
      chipTheme: ChipThemeData(
        backgroundColor: Color(0xFF2A2A2A),
        selectedColor: Color(0xFF6366F1).withOpacity(0.3),
        labelStyle: TextStyle(color: Colors.white),
        secondaryLabelStyle: TextStyle(color: Colors.white),
      ),
      // ListTile
      listTileTheme: ListTileThemeData(
        textColor: Colors.white,
        iconColor: Colors.white,
      ),
      // Card
      cardTheme: CardTheme(
        color: const Color(0xFF1E1E1E),
        elevation: 0,
      ),
      // Drawer
      drawerTheme: DrawerThemeData(
        backgroundColor: const Color(0xFF1E1E1E),
      ),
      // BottomNavigationBar
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: const Color(0xFF1E1E1E),
        selectedItemColor: Color(0xFF6366F1),
        unselectedItemColor: Colors.grey,
      ),
      // Snackbar
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF2A2A2A),
        contentTextStyle: TextStyle(color: Colors.white),
        actionTextColor: Color(0xFF6366F1),
      ),
      // Dialog
      dialogTheme: DialogTheme(
        backgroundColor: const Color(0xFF1E1E1E),
        titleTextStyle: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
        contentTextStyle: TextStyle(color: Colors.white),
      ),
    );
  }
}
