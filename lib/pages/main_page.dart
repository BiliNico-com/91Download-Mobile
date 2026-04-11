import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'batch_page.dart';
import 'search_page.dart';
import 'download_page.dart';
import 'settings_page.dart';
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
  
  final _pageNames = ['批量爬取', '搜索', '下载', '设置'];
  final _pages = const [
    BatchPage(),
    SearchPage(),
    DownloadPage(),
    SettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    // 记录初始页面
    Future.microtask(() {
    });
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
      duration: Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _pageController,
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
    );
  }
}
