import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'dart:ui';
import 'batch_page.dart';
import 'search_page.dart';
import 'download_page.dart';
import 'settings_page.dart';
import 'followed_page.dart';
import '../services/app_state.dart';
import '../theme/app_tokens.dart';
import '../theme/ui_style.dart';
import '../utils/logger.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  int _currentIndex = 0;
  late PageController _pageController;
  
  // 双击退出相关
  DateTime? _lastPressedTime;
  static const _exitTimeout = Duration(seconds: 2);
  
  final _pageNames = ['批量爬取', '搜索', '已关注', '下载', '设置'];
  final _pages = const [
    BatchPage(),
    SearchPage(),
    FollowedPage(),
    DownloadPage(),
    SettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 设置导航函数
    final appState = context.read<AppState>();
    appState.navigateToPage = (index) {
      goToPage(index);
    };
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }
  
  // 跳转到指定页面
  void goToPage(int index) {
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }
  
  // 处理返回键
  Future<void> _handlePopInvoked(bool didPop) async {
    if (!didPop) {
      final appState = context.read<AppState>();
      
      // 先检查子页面是否需要处理返回事件（如作者模式）
      if (appState.onWillPopCallback != null) {
        final handled = appState.onWillPopCallback!();
        if (handled) return;
      }
      
      // 如果在非第一个页面，返回到第一个页面
      if (_currentIndex != 0) {
        goToPage(0);
        return;
      }
      
      // 在第一个页面，检查双击退出
      final now = DateTime.now();
      if (_lastPressedTime == null || now.difference(_lastPressedTime!) > _exitTimeout) {
        // 第一次点击，显示提示
        _lastPressedTime = now;
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('再按一次退出程序'),
            duration: _exitTimeout,
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.only(
              bottom: 80,
              left: 16,
              right: 16,
            ),
          ),
        );
        return;
      }
      
      // 第二次点击，退出程序
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop) {
          _handlePopInvoked(didPop);
        }
      },
      child: Scaffold(
        body: PageView(
          controller: _pageController,
          physics: const NeverScrollableScrollPhysics(), // 禁用侧滑切换页面
          onPageChanged: (index) {
            setState(() {
              _currentIndex = index;
            });
          },
          children: _pages,
        ),
        bottomNavigationBar: _buildGlassNavBar(),
        extendBody: true,
      ),
    );
  }

  /// 底部导航栏
  ///
  /// 由 Material 的 NavigationBar 换成自绘的一行胶囊：选中项图标底下铺一块
  /// 两侧半圆的浅蓝底（原型 .icw），文字由 12 缩到 10 —— 原来 80 高的
  /// NavigationBar 换成 62，内容区能多出 18px。
  ///
  /// 「毛玻璃效果」开关仍然生效：开启时用 ClipRect + BackdropFilter 让下方
  /// 内容透上来，关闭时退回实心背景，两种模式下布局完全一致。
  Widget _buildGlassNavBar() {
    return ValueListenableBuilder<bool>(
      valueListenable: UiStyle.glassEnabled,
      builder: (context, glass, _) {
        return ValueListenableBuilder<double>(
          valueListenable: UiStyle.glassOpacity,
          builder: (context, _, __) {
            final t = AppTokens.of(context);
            final isDark = t.dark;
            final bottomInset = MediaQuery.of(context).padding.bottom;

            final bar = Container(
              height: 62 + bottomInset,
              padding: EdgeInsets.only(bottom: bottomInset),
              decoration: BoxDecoration(
                color: glass ? Colors.transparent : t.surface,
                border: Border(
                  top: BorderSide(
                    color: glass
                        ? UiStyle.glassBorderColor(isDark)
                        : t.line,
                    width: 0.8,
                  ),
                ),
              ),
              child: Row(
                children: [
                  _buildNavItem(t, 0, Icons.download_rounded, Icons.download, '批量'),
                  _buildNavItem(t, 1, Icons.search_rounded, Icons.search, '搜索'),
                  _buildNavItem(
                    t,
                    2,
                    Icons.favorite_border_rounded,
                    Icons.favorite,
                    '已关注',
                    badge: context.watch<AppState>()
                        .followedAuthorsService
                        .newContentCount,
                  ),
                  _buildNavItem(t, 3, Icons.history_rounded, Icons.history, '已下载'),
                  _buildNavItem(t, 4, Icons.settings_rounded, Icons.settings, '设置'),
                ],
              ),
            );

            if (!glass) return bar;

            return ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: UiStyle.navBarGlassFill(isDark),
                  ),
                  child: bar,
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 单个底栏项：54x26 胶囊底 + 22 图标 + 10px 文字
  Widget _buildNavItem(
    AppTokens t,
    int index,
    IconData icon,
    IconData activeIcon,
    String label, {
    int badge = 0,
  }) {
    final on = _currentIndex == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => goToPage(index),
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  width: 54,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: on ? t.accentSoft : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Icon(
                    on ? activeIcon : icon,
                    size: 22,
                    color: on ? t.accent : t.text3,
                  ),
                ),
                if (badge > 0)
                  Positioned(
                    right: 6,
                    top: -3,
                    child: Container(
                      height: 15,
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: t.danger,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Text(
                        badge > 99 ? '99+' : '$badge',
                        style: const TextStyle(
                          fontSize: 9,
                          height: 1,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                height: 1,
                fontWeight: FontWeight.w600,
                color: on ? t.accent : t.text3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
