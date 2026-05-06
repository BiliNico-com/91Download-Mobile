import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'batch_page.dart';
import 'search_page.dart';
import 'download_page.dart';
import 'settings_page.dart';
import 'followed_page.dart';
import '../services/app_state.dart';
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
      // 在Android上会调用SystemNavigator.pop()或exit(0)
      // 在iOS上会调用exit(0)
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
        bottomNavigationBar: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (index) {
            goToPage(index);
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.download_rounded),
              selectedIcon: Icon(Icons.download),
              label: '批量',
            ),
            NavigationDestination(
              icon: Icon(Icons.search_rounded),
              selectedIcon: Icon(Icons.search),
              label: '搜索',
            ),
            NavigationDestination(
              icon: Icon(Icons.favorite_border_rounded),
              selectedIcon: Icon(Icons.favorite),
              label: '已关注',
            ),
            NavigationDestination(
              icon: Icon(Icons.history_rounded),
              selectedIcon: Icon(Icons.history),
              label: '已下载',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_rounded),
              selectedIcon: Icon(Icons.settings),
              label: '设置',
            ),
          ],
        ),
      ),
    );
  }
}
