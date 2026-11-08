import 'package:flutter/material.dart';
import '../theme/app_tokens.dart';

/// 统一空状态组件
///
/// 支持多种场景：空搜索、网络错误、无下载任务、无关注作者等
///
/// 用法：EmptyState(icon: Icons.search_off, title: '没有找到视频', subtitle: '试试其他关键词')
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
        icon: Icons.search_off_rounded,
        title: query?.isNotEmpty == true ? '未找到 "$query" 相关结果' : '没有找到视频',
        subtitle: '换个关键词试试',
        iconSize: 56,
      );

  /// 网络错误
  factory EmptyState.networkError({VoidCallback? onRetry}) => EmptyState(
        icon: Icons.wifi_off_rounded,
        title: '网络连接失败',
        subtitle: '请检查网络设置后重试',
        actionLabel: '重试',
        onAction: onRetry,
        iconSize: 56,
      );

  /// 无下载任务
  factory EmptyState.noDownloads() => const EmptyState(
        icon: Icons.download_done_rounded,
        title: '暂无下载任务',
        subtitle: '去搜索页添加视频开始下载',
        iconSize: 56,
      );

  /// 无关注作者
  factory EmptyState.noFollowedAuthors() => const EmptyState(
        icon: Icons.person_off_rounded,
        title: '还没有关注任何作者',
        subtitle: '在视频列表中点击作者名称即可关注',
        iconSize: 56,
      );

  /// 无站点配置
  factory EmptyState.noSiteSelected() => const EmptyState(
        icon: Icons.language_rounded,
        title: '请先选择站点',
        subtitle: '在设置页面选择要使用的站点',
        iconSize: 56,
      );

  /// 无批量任务
  factory EmptyState.noBatchTasks() => const EmptyState(
        icon: Icons.playlist_add_rounded,
        title: '没有可批量下载的视频',
        subtitle: '先在搜索页获取视频列表',
        iconSize: 56,
      );

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: iconSize,
              height: iconSize,
              decoration: BoxDecoration(
                color: t.surface2,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: iconSize * 0.46, color: t.text3),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
                color: t.text1,
              ),
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                style: TextStyle(fontSize: 12, height: 1.45, color: t.text3),
                textAlign: TextAlign.center,
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              GestureDetector(
                onTap: onAction,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  decoration: BoxDecoration(
                    color: AppTokens.blue,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    actionLabel!,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
