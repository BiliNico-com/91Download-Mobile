import 'package:flutter/material.dart';
import '../models/video_info.dart';
import '../services/app_state.dart';
import '../theme/app_tokens.dart';
import 'cover_image.dart';

/// 视频列表项（横向行式布局）——搜索页与批量页共用
///
/// 抽出来的原因：此前 search_page 与 batch_page 各写了一份几乎相同的实现
/// （封面尺寸、选中标记、时长标签、作者行都重复），
/// 导致同一个问题要改两处（例如之前硬编码分页阈值就漏改过一处）。
///
/// 各页面差异较大的部分（点击行为、作者跳转）通过回调注入，
/// 组件本身只负责统一的呈现。
///
/// 视觉规范见 UI 原型的行式卡片：行高约 78、封面 100x60 圆角 9、
/// 标题 12.5 w700 两行截断、元信息 10.5 次要色。
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
    final t = AppTokens.of(context);
    final radius = BorderRadius.circular(AppRadius.lg);

    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Material(
        color: isSelected ? t.accentSoft : t.surface,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: isSelected ? t.accent : t.line),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 封面图
                GestureDetector(
                  // 在线播放模式：点击封面直接播放；否则冒泡到外层做选中
                  onTap: onCoverTap,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: SizedBox(
                      width: 100,
                      height: 60,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          CoverImage(
                            url: video.cover,
                            borderRadius: BorderRadius.zero,
                            blur: appState.privacyMode,
                          ),
                          // 选中标记（左上角勾选圆点）
                          if (isSelected)
                            Positioned(
                              top: 5,
                              left: 5,
                              child: _CheckDot(color: t.accent),
                            ),
                          // 在线播放模式下显示播放角标，提示封面可点
                          if (appState.streamingMode)
                            const Positioned(
                              left: 5,
                              bottom: 5,
                              child: Icon(Icons.play_circle_fill,
                                  color: Colors.white70, size: 18),
                            ),
                          // 时长标签
                          if (video.duration != null)
                            Positioned(
                              right: 4,
                              bottom: 4,
                              child: _Pill(text: video.duration!),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // 信息：视频名称 + 作者
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.25,
                          fontWeight: FontWeight.w700,
                          color: t.text1,
                        ),
                      ),
                      const SizedBox(height: 5),
                      _buildAuthorRow(t),
                      // 上传时间（可选）
                      if (showUploadDate &&
                          video.uploadDate != null &&
                          video.uploadDate!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.access_time_rounded,
                                  size: 11, color: t.text3),
                              const SizedBox(width: 3),
                              Text(
                                video.uploadDate!,
                                style: TextStyle(
                                    fontSize: 10.5, color: t.text3),
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
      ),
    );
  }

  Widget _buildAuthorRow(AppTokens t) {
    final author = video.author;
    if (author == null || author.isEmpty) return const SizedBox.shrink();

    // 可跳转作者主页
    if (onAuthorTap != null &&
        video.authorId != null &&
        video.authorId!.isNotEmpty) {
      return GestureDetector(
        onTap: onAuthorTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.person_outline_rounded, size: 12, color: t.accent),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: t.accent,
                ),
              ),
            ),
            if (isAuthorFollowed) ...[
              const SizedBox(width: 5),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: t.dangerSoft,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '已关注',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: t.danger,
                  ),
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
        Icon(Icons.person_outline_rounded, size: 12, color: t.text3),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, color: t.text3),
          ),
        ),
      ],
    );
  }
}

/// 视频网格项（竖向卡片）——搜索页与批量页共用
///
/// 视觉规范见 UI 原型网格卡：封面 16:10 顶部圆角、标题 12.5 两行、
/// 作者行 10.5 次要色、选中态整卡描边 + 封面左上角勾选圆点。
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
    final t = AppTokens.of(context);
    final radius = BorderRadius.circular(AppRadius.lg);

    return Material(
      color: isSelected ? t.accentSoft : t.surface,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: isSelected ? t.accent : t.line),
          ),
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
                      // 选中标记
                      if (isSelected)
                        Positioned(
                          top: 6,
                          left: 6,
                          child: _CheckDot(color: t.accent),
                        ),
                      // 在线播放角标
                      if (appState.streamingMode)
                        const Positioned(
                          left: 6,
                          bottom: 6,
                          child: Icon(Icons.play_circle_fill,
                              color: Colors.white70, size: 18),
                        ),
                      // 更新日期标签（左下角，批量页使用）
                      if (showUpdateDateBadge &&
                          video.uploadDate != null &&
                          video.uploadDate!.isNotEmpty)
                        Positioned(
                          left: 6,
                          bottom: 6,
                          child: _Pill(
                            text: video.uploadDate!.length > 10
                                ? video.uploadDate!.substring(0, 10)
                                : video.uploadDate!,
                            icon: Icons.access_time_rounded,
                          ),
                        ),
                      // 时长
                      if (video.duration != null)
                        Positioned(
                          right: 6,
                          bottom: 6,
                          child: _Pill(text: video.duration!),
                        ),
                    ],
                  ),
                ),
              ),
              // 标题与作者
              Padding(
                padding: const EdgeInsets.fromLTRB(9, 7, 9, 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      video.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                        color: t.text1,
                      ),
                    ),
                    if (video.author != null && video.author!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.person_outline_rounded,
                              size: 11, color: t.text3),
                          const SizedBox(width: 3),
                          Expanded(
                            child: Text(
                              video.author!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 10.5, color: t.text3),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 封面角上的勾选圆点：蓝色实心圆 + 白色对勾
class _CheckDot extends StatelessWidget {
  final Color color;
  const _CheckDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1.6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.24),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: const Icon(Icons.check_rounded, size: 12, color: Colors.white),
    );
  }
}

/// 封面角上的黑色半透明小胶囊（时长 / 日期）
class _Pill extends StatelessWidget {
  final String text;
  final IconData? icon;
  const _Pill({required this.text, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.72),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 9, color: Colors.white70),
            const SizedBox(width: 2),
          ],
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
