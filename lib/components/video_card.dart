import 'dart:ui';
import 'package:flutter/material.dart';
import '../models/video_info.dart';
import '../services/app_state.dart';
import '../theme/app_theme.dart';

/// 统一视频卡片组件
/// 
/// 支持列表模式和网格模式，封装了封面、隐私模糊、选中标记、时长标签、
/// 作者信息、关注标签等公共逻辑
class VideoCard extends StatelessWidget {
  final VideoInfo video;
  final AppState appState;
  final bool isListMode;
  final bool isSelected;
  final bool showAuthor;
  final bool showFollowBadge;
  final bool showUploadDate;
  final bool showChevron;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onAuthorTap;

  const VideoCard({
    super.key,
    required this.video,
    required this.appState,
    this.isListMode = true,
    this.isSelected = false,
    this.showAuthor = true,
    this.showFollowBadge = true,
    this.showUploadDate = true,
    this.showChevron = false,
    this.onTap,
    this.onLongPress,
    this.onAuthorTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Card(
        color: isSelected
            ? AppTheme.primaryColor.withOpacity(0.15)
            : null,
        clipBehavior: Clip.antiAlias,
        child: isListMode ? _buildListLayout(isDark) : _buildGridLayout(isDark),
      ),
    );
  }

  Widget _buildListLayout(bool isDark) {
    return Padding(
      padding: const EdgeInsets.all(AppTheme.spacingMd),
      child: Row(
        children: [
          _buildThumbnail(isDark, width: 120, height: 68, iconSize: 20),
          const SizedBox(width: AppTheme.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTitle(isDark, maxLines: 2, fontSize: 14),
                const SizedBox(height: 4),
                if (showAuthor) _buildAuthorRow(isDark, fontSize: 12, iconSize: 14),
                if (showUploadDate && video.uploadDate != null && video.uploadDate!.isNotEmpty)
                  _buildUploadDate(isDark, fontSize: 10, iconSize: 12, paddingTop: 4),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridLayout(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _buildThumbnail(
            isDark,
            width: double.infinity,
            height: double.infinity,
            iconSize: 32,
            fit: StackFit.expand,
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(AppTheme.spacingSm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTitle(isDark, maxLines: 2, fontSize: 12),
              if (showAuthor) _buildAuthorRow(isDark, fontSize: 10, iconSize: 12, paddingTop: 2),
              if (showUploadDate && video.uploadDate != null && video.uploadDate!.isNotEmpty)
                _buildUploadDate(isDark, fontSize: 9, iconSize: 10, paddingTop: 2),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildThumbnail(bool isDark, {
    required double width,
    required double height,
    required double iconSize,
    StackFit fit = StackFit.loose,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: fit,
          children: [
            // 背景色 / 封面图
            Container(
              color: isDark ? const Color(0xFF2C2C2C) : Colors.grey[800],
              child: video.cover != null
                  ? Image.network(
                      video.cover!,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      errorBuilder: (_, __, ___) => Center(
                        child: Icon(Icons.video_library, color: Colors.grey, size: iconSize),
                      ),
                    )
                  : Center(
                      child: Icon(Icons.video_library, color: Colors.grey, size: iconSize),
                    ),
            ),
            // 隐私模式模糊
            if (appState.privacyMode)
              BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                child: Container(color: Colors.transparent),
              ),
            // 选中标记
            if (isSelected)
              Positioned(
                top: AppTheme.spacingXs,
                left: AppTheme.spacingXs,
                child: Icon(Icons.check_circle, color: AppTheme.primaryColor, size: iconSize),
              ),
            // 时长标签
            if (video.duration != null)
              Positioned(
                right: AppTheme.spacingXs,
                bottom: AppTheme.spacingXs,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  ),
                  child: Text(
                    video.duration!,
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTitle(bool isDark, {required int maxLines, required double fontSize}) {
    return Text(
      video.title,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: fontSize,
        color: isDark ? AppTheme.darkTextPrimary : AppTheme.textPrimary,
      ),
    );
  }

  Widget _buildAuthorRow(bool isDark, {
    required double fontSize,
    required double iconSize,
    double paddingTop = 0,
  }) {
    final hasAuthorId = video.authorId != null && video.authorId!.isNotEmpty;
    final isFollowed = hasAuthorId && showFollowBadge
        ? appState.followedAuthorsService.isFollowedSync(video.authorId!)
        : false;

    return Padding(
      padding: EdgeInsets.only(top: paddingTop),
      child: GestureDetector(
        onTap: hasAuthorId ? onAuthorTap : null,
        behavior: HitTestBehavior.translucent,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.person_outline,
              size: iconSize,
              color: hasAuthorId ? AppTheme.primaryColor : (isDark ? AppTheme.darkTextSecondary : AppTheme.textHint),
            ),
            const SizedBox(width: 2),
            Text(
              video.author ?? '',
              style: TextStyle(
                fontSize: fontSize,
                color: hasAuthorId ? AppTheme.primaryColor : (isDark ? AppTheme.darkTextSecondary : AppTheme.textHint),
              ),
            ),
            if (isFollowed) ...[
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: AppTheme.errorColor.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: const Text(
                  '已关注',
                  style: TextStyle(fontSize: 9, color: Colors.white),
                ),
              ),
            ],
            if (showChevron && hasAuthorId) ...[
              const SizedBox(width: 2),
              Icon(Icons.chevron_right, size: iconSize, color: AppTheme.primaryColor),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildUploadDate(bool isDark, {
    required double fontSize,
    required double iconSize,
    required double paddingTop,
  }) {
    return Padding(
      padding: EdgeInsets.only(top: paddingTop),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.access_time,
            size: iconSize,
            color: isDark ? AppTheme.darkTextSecondary : AppTheme.textHint,
          ),
          const SizedBox(width: 2),
          Text(
            video.uploadDate!,
            style: TextStyle(
              fontSize: fontSize,
              color: isDark ? AppTheme.darkTextSecondary : AppTheme.textHint,
            ),
          ),
        ],
      ),
    );
  }
}
