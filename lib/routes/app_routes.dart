import 'package:flutter/material.dart';
import '../models/video_info.dart';
import '../pages/main_page.dart';
import '../pages/search_page.dart';
import '../pages/batch_page.dart';
import '../pages/download_page.dart';
import '../pages/followed_page.dart';
import '../pages/settings_page.dart';
import '../pages/author_detail_page.dart';

/// 应用路由表
/// 
/// 统一管理所有页面路由，支持命名路由和自定义过渡动画
class AppRoutes {
  static const String home = '/';
  static const String search = '/search';
  static const String batch = '/batch';
  static const String download = '/download';
  static const String followed = '/followed';
  static const String settings = '/settings';
  static const String authorDetail = '/author';

  /// 路由表映射
  static Map<String, WidgetBuilder> get routes => {
    home: (_) => const MainPage(),
    search: (_) => const SearchPage(),
    batch: (_) => const BatchPage(),
    download: (_) => const DownloadPage(),
    followed: (_) => const FollowedPage(),
    settings: (_) => const SettingsPage(),
  };

  /// 自定义页面路由（带过渡动画）
  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    final args = settings.arguments;

    switch (settings.name) {
      case authorDetail:
        return _buildFadeRoute(
          AuthorDetailPage(author: args as AuthorInfo),
          settings: settings,
        );
      default:
        return MaterialPageRoute(
          builder: routes[settings.name] ?? (_) => const MainPage(),
          settings: settings,
        );
    }
  }

  /// 淡入缩放过渡（用于详情页）
  static Route<T> _buildFadeRoute<T>(Widget page, {RouteSettings? settings}) {
    return PageRouteBuilder<T>(
      settings: settings,
      pageBuilder: (_, animation, __) => page,
      transitionsBuilder: (_, animation, __, child) {
        final fade = Tween<double>(begin: 0.0, end: 1.0).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOut),
        );
        final scale = Tween<double>(begin: 0.97, end: 1.0).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        );
        return FadeTransition(
          opacity: fade,
          child: ScaleTransition(scale: scale, child: child),
        );
      },
      transitionDuration: const Duration(milliseconds: 250),
      reverseTransitionDuration: const Duration(milliseconds: 200),
    );
  }

  /// 滑动过渡（用于列表到详情）
  static Route<T> _buildSlideRoute<T>(Widget page, {RouteSettings? settings}) {
    return MaterialPageRoute<T>(
      builder: (_) => page,
      settings: settings,
    );
  }

  /// 便捷导航方法
  static void goToAuthorDetail(BuildContext context, AuthorInfo author) {
    Navigator.of(context).pushNamed(authorDetail, arguments: author);
  }
}
