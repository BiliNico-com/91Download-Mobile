import 'package:flutter/material.dart';
import '../models/video_info.dart';
import '../services/app_state.dart';
import 'cover_image.dart';

/// 视频列表项（横向布局）——搜索页与批量页共用
///
/// 抽出来的原因：此前 search_page 与 batch_page 各写了一份几乎相同的实现
/// （封面尺寸、选中标记、时长标签、作者行都重复），
/// 导致同一个问题要改两处（例如之前硬编码分页阈值就漏改过一处）。
///
/// 各页面差异较大的部分（点击行为、作者跳转）通过回调注入，
/// 组件本身只负责统一的呈现。
class VideoListItem extends StatelessWidget {
  final VideoInfo video;
  final AppState appState;

  /// 是否处于选中态
  final bool isSelected;

  /// 点击整行的行为
  final VoidCallback onTap;

  /// 点击封面（在线播放模式下才有值；为 null 时冒泡给外层做选中）
  final VoidCallback? onCoverTap;

  /// 点击作者名（为 null 时不显示为可点击样式）
  final VoidCallback? onAuthorTap;

  /// 是否已在关注列表中（用于作者名后的「已关注」角标）
  final bool isAuthorFollowed;

  /// 是否显示上传时间（搜索页显示，批量页不显示）
  final bool showUploadDate;

  const VideoListItem({
    super.key,
    required this.video,
    required this.appState,
    required this.isSelected,
    required this.onTap,
    this.onCoverTap,
    this.onAuthorTap,
    this.isAuthorFollowed = false,
    this.showUploadDate = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Card(
        color: isSelected ? Colors.blue.withOpacity(0.2) : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // 封面图（与批量页一致：120x68）
              GestureDetector(
                // 在线播放模式：点击封面直接播放；否则冒泡到外层做选中
                onTap: onCoverTap,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 120,
                    height: 68,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CoverImage(
                          url: video.cover,
                          borderRadius: BorderRadius.zero,
                          blur: appState.privacyMode,
                        ),
                        // 选中标记
                        if (isSelected)
                          const Positioned(
                            top: 4,
                            left: 4,
                            child: Icon(Icons.check_circle,
                                color: Colors.blue, size: 20),
                          ),
                        // 在线播放模式下显示播放角标，提示封面可点
                        if (appState.streamingMode)
                          const Positioned(
                            left: 4,
                            bottom: 4,
                            child: Icon(Icons.play_circle_fill,
                                color: Colors.white70, size: 20),
                          ),
                        // 时长标签
                        if (video.duration != null)
                          Positioned(
                            right: 4,
                            bottom: 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                video.duration!,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 10),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // 信息：视频名称 + 作者
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      video.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14),
                    ),
                    const SizedBox(height: 4),
                    _buildAuthorRow(),
                    // 上传时间（可选）
                    if (showUploadDate &&
                        video.uploadDate != null &&
                        video.uploadDate!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.access_time,
                                size: 12, color: Colors.grey),
                            const SizedBox(width: 2),
                            Text(
                              video.uploadDate!,
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAuthorRow() {
    final author = video.author;
    if (author == null || author.isEmpty) return const SizedBox.shrink();

    // 可跳转作者主页
    if (onAuthorTap != null && video.authorId != null && video.authorId!.isNotEmpty) {
      return GestureDetector(
        onTap: onAuthorTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.person_outline, size: 14, color: Colors.blue),
            const SizedBox(width: 2),
            Text(author, style: const TextStyle(fontSize: 12, color: Colors.blue)),
            if (isAuthorFollowed) ...[
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: const Text(
                  '已关注',
                  style: TextStyle(fontSize: 9, color: Colors.white),
                ),
              ),
            ],
          ],
        ),
      );
    }

    // 仅展示，不可点击
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.person_outline, size: 14, color: Colors.grey),
        const SizedBox(width: 2),
        Text(author, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}

/// 视频网格项（竖向卡片）——搜索页与批量页共用
class VideoGridItem extends StatelessWidget {
  final VideoInfo video;
  final AppState appState;
  final bool isSelected;
  final VoidCallback onTap;

  /// 点击封面（在线播放模式下才有值）
  final VoidCallback? onCoverTap;

  /// 是否在封面左下角叠加更新日期（批量页使用）
  final bool showUpdateDateBadge;

  const VideoGridItem({
    super.key,
    required this.video,
    required this.appState,
    required this.isSelected,
    required this.onTap,
    this.onCoverTap,
    this.showUpdateDateBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Card(
        color: isSelected ? Colors.blue.withOpacity(0.2) : null,
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 缩略图
            Expanded(
              child: GestureDetector(
                onTap: onCoverTap,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CoverImage(
                      url: video.cover,
                      borderRadius: BorderRadius.zero,
                      blur: appState.privacyMode,
                    ),
                    // 时长
                    if (video.duration != null)
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            video.duration!,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 10),
                          ),
                        ),
                      ),
                    // 在线播放角标
                    if (appState.streamingMode)
                      const Positioned(
                        left: 4,
                        bottom: 4,
                        child: Icon(Icons.play_circle_fill,
                            color: Colors.white70, size: 20),
                      ),
                    // 更新日期标签（左下角，批量页使用）
                    if (showUpdateDateBadge &&
                        video.uploadDate != null &&
                        video.uploadDate!.isNotEmpty)
                      Positioned(
                        left: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.6),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.access_time,
                                  size: 10, color: Colors.white70),
                              const SizedBox(width: 2),
                              Text(
                                video.uploadDate!.length > 10
                                    ? video.uploadDate!.substring(0, 10)
                                    : video.uploadDate!,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 9),
                              ),
                            ],
                          ),
                        ),
                      ),
                    // 选中标记
                    if (isSelected)
                      const Positioned(
                        top: 4,
                        right: 4,
                        child: Icon(Icons.check_circle, color: Colors.blue),
                      ),
                  ],
                ),
              ),
            ),
            // 标题与作者
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (video.author != null && video.author!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      video.author!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
