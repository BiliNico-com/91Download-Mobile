import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 统一空状态组件
/// 
/// 支持多种场景：空搜索、网络错误、无下载任务、无关注作者等
///
/// ```dart
/// EmptyState(
///   icon: Icons.search_off,
///   title: '没有找到视频',
///   subtitle: '试试其他关键词',
/// )
/// ```
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final double iconSize;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.iconSize = 80,
  });

  /// 空搜索
  factory EmptyState.search({String? query}) => EmptyState(
    icon: Icons.search_off,
    title: query?.isNotEmpty == true ? '未找到 "$query" 相关结果' : '没有找到视频',
    subtitle: '换个关键词试试',
  );

  /// 网络错误
  factory EmptyState.networkError({VoidCallback? onRetry}) => EmptyState(
    icon: Icons.wifi_off,
    title: '网络连接失败',
    subtitle: '请检查网络设置后重试',
    actionLabel: '重试',
    onAction: onRetry,
  );

  /// 无下载任务
  factory EmptyState.noDownloads() => const EmptyState(
    icon: Icons.download_done,
    title: '暂无下载任务',
    subtitle: '去搜索页添加视频开始下载',
  );

  /// 无关注作者
  factory EmptyState.noFollowedAuthors() => const EmptyState(
    icon: Icons.person_off,
    title: '还没有关注任何作者',
    subtitle: '在视频列表中点击作者名称即可关注',
  );

  /// 无站点配置
  factory EmptyState.noSiteSelected() => const EmptyState(
    icon: Icons.language,
    title: '请先选择站点',
    subtitle: '在设置页面选择要使用的站点',
  );

  /// 无批量任务
  factory EmptyState.noBatchTasks() => const EmptyState(
    icon: Icons.playlist_add,
    title: '没有可批量下载的视频',
    subtitle: '先在搜索页获取视频列表',
  );

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final iconColor = isDark ? AppTheme.darkTextSecondary : AppTheme.textHint;
    final textColor = isDark ? AppTheme.darkTextPrimary : AppTheme.textPrimary;
    final subColor = isDark ? AppTheme.darkTextSecondary : AppTheme.textSecondary;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spacingXl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: iconSize, color: iconColor),
            const SizedBox(height: AppTheme.spacingLg),
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: AppTheme.spacingSm),
              Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 14,
                  color: subColor,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: AppTheme.spacingXl),
              FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.refresh),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
