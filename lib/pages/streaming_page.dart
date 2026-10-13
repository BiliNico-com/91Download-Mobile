import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:provider/provider.dart';
import '../models/video_info.dart';
import '../services/app_state.dart';
import '../services/download_manager.dart';
import '../theme/app_theme.dart';
import '../utils/logger.dart';
import '../components/player_glass.dart';
import 'author_detail_page.dart';

/// 在线播放页（实验性功能）
class StreamingPage extends StatefulWidget {
  final VideoInfo video;

  const StreamingPage({super.key, required this.video});

  @override
  State<StreamingPage> createState() => _StreamingPageState();
}

class _StreamingPageState extends State<StreamingPage> {
  VideoPlayerController? _videoController;
  bool _isLoading = true;
  String? _error;
  String? _author;
  String? _authorId;
  String? _durationText;
  String? _viewsText;
  String? _uploadDateText;
  bool _isDownloading = false;

  /// 自绘控件的显隐（与内置播放器一致的交互：点击切换、4 秒后自动隐藏）
  bool _showControls = true;
  Timer? _hideControlsTimer;

  /// 常驻播放倍速（与内置播放器一致）
  double _playbackSpeed = 1.0;

  @override
  void initState() {
    super.initState();
    _loadVideo();
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _startHideControlsTimer();
  }

  void _startHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(PlayerGlassTokens.autoHideDelay, () {
      if (mounted && (_videoController?.value.isPlaying ?? false)) {
        setState(() => _showControls = false);
      }
    });
  }

  void _togglePlayPause() {
    final c = _videoController;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
      _hideControlsTimer?.cancel();
      setState(() => _showControls = true);
    } else {
      c.play();
      _startHideControlsTimer();
    }
    setState(() {});
  }

  void _seekTo(Duration position) {
    final c = _videoController;
    if (c == null) return;
    var target = position;
    if (target < Duration.zero) target = Duration.zero;
    if (target > c.value.duration) target = c.value.duration;
    c.seekTo(target);
  }

  Future<void> _loadVideo() async {
    try {
      final appState = context.read<AppState>();
      final crawler = appState.crawler;
      if (crawler == null) {
        setState(() { _error = '请先在设置中选择站点'; _isLoading = false; });
        return;
      }

      final detail = await crawler.getVideoDetail(widget.video);
      if (detail == null || detail.m3u8Url == null) {
        setState(() { _error = '无法获取视频播放地址'; _isLoading = false; });
        return;
      }

      logger.log('Streaming', 'm3u8: ${detail.m3u8Url}');
      _author = detail.author;
      _authorId = detail.authorId;
      _durationText = detail.duration;
      _viewsText = detail.views;
      _uploadDateText = detail.uploadDate;

      _videoController = VideoPlayerController.networkUrl(
        Uri.parse(detail.m3u8Url!),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );

      await _videoController!.initialize();
      if (!mounted) return;

      // 说明：此处原使用 Chewie 自带控件，与内置播放器的自绘控件风格不一致。
      // 现改为只用 video_player 渲染画面 + 自绘玻璃控件，两个播放页保持统一。
      _videoController!.setLooping(false);

      setState(() { _isLoading = false; });
      // 自动开播后启动控件自动隐藏
      _startHideControlsTimer();
    } catch (e) {
      logger.log('Streaming', 'Error: $e');
      setState(() { _error = '播放加载失败: $e'; _isLoading = false; });
    }
  }

  Future<void> _downloadVideo() async {
    final appState = context.read<AppState>();
    final dm = appState.downloadManager;

    setState(() => _isDownloading = true);

    final result = await dm.addTask(widget.video);

    if (!mounted) return;
    setState(() => _isDownloading = false);

    String msg;
    if (result == 'new') {
      msg = '已添加到下载队列';
    } else if (result == 'duplicate') {
      msg = '该视频已在下载队列中';
    } else {
      msg = '已覆盖并重新下载';
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2), behavior: SnackBarBehavior.floating),
    );
  }

  void _navigateToAuthor() {
    if (_authorId == null || _authorId!.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AuthorDetailPage(
          author: AuthorInfo(
            id: _authorId!,
            name: _author ?? _authorId!,
            profileUrl: '',
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? AppTheme.darkBackground : AppTheme.scaffoldBackground;
    final cardColor = isDark ? AppTheme.darkSurface : AppTheme.cardBackground;
    final textColor = isDark ? AppTheme.darkTextPrimary : AppTheme.textPrimary;
    final subColor = isDark ? AppTheme.darkTextSecondary : AppTheme.textSecondary;
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: Text(widget.video.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
        centerTitle: true,
        backgroundColor: cardColor,
        foregroundColor: textColor,
        actions: [
          if (!_isLoading && _error == null)
            IconButton(
              icon: _isDownloading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download),
              tooltip: '下载此视频',
              onPressed: _isDownloading ? null : _downloadVideo,
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildErrorView()
              : SingleChildScrollView(
                  child: Column(
                    children: [
                      // 播放器：屏幕上半区域（自绘玻璃控件）
                      SizedBox(
                        height: screenHeight * 0.42,
                        child: _buildPlayer(),
                      ),
                      // 视频信息
                      _buildVideoInfo(cardColor, textColor, subColor),
                    ],
                  ),
                ),
    );
  }

  /// 自绘播放器（画面 + 玻璃控件），与内置播放器保持一致的观感
  Widget _buildPlayer() {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 与内置播放器一致的交互约定：
      //   单击 → 显示/隐藏控件
      //   双击 → 播放/暂停
      onTap: _toggleControls,
      onDoubleTap: _togglePlayPause,
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio == 0
                    ? 16 / 9
                    : controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
            ),
            // 控件层：随 _showControls 淡入淡出
            AnimatedOpacity(
              opacity: _showControls ? 1 : 0,
              duration: PlayerGlassTokens.fadeDuration,
              child: IgnorePointer(
                ignoring: !_showControls,
                child: _buildPlayerControls(controller),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayerControls(VideoPlayerController controller) {
    return Column(
      children: [
        // 中央播放/暂停：方形玻璃按钮，与底栏视觉统一
        Expanded(
          child: Center(
            child: ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: controller,
              builder: (context, value, child) {
                return GlassIconButton(
                  icon: value.isPlaying
                      ? Icons.pause
                      : Icons.play_arrow,
                  onPressed: _togglePlayPause,
                  size: 52,
                  filled: true,
                  tooltip: value.isPlaying ? '暂停' : '播放',
                );
              },
            ),
          ),
        ),
        // 底部进度 + 时间（长方形玻璃底栏）
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: GlassSurface(
            borderRadius: const BorderRadius.all(Radius.circular(10)),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: controller,
                  builder: (context, value, child) {
                    return Text(
                      formatPlayerDuration(value.position),
                      style: const TextStyle(color: Colors.white70, fontSize: 11),
                    );
                  },
                ),
                const SizedBox(width: 8),
                Expanded(child: _buildProgressBar(controller)),
                const SizedBox(width: 8),
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: controller,
                  builder: (context, value, child) {
                    return Text(
                      formatPlayerDuration(value.duration),
                      style: const TextStyle(color: Colors.white70, fontSize: 11),
                    );
                  },
                ),
                const SizedBox(width: 4),
                // 倍速：与内置播放器保持一致
                TextButton(
                  onPressed: _showSpeedPicker,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    foregroundColor: _playbackSpeed == 1.0
                        ? Colors.white70
                        : Colors.lightBlueAccent,
                  ),
                  child: Text(
                    '${_playbackSpeed}x',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 弹出倍速选择面板
  void _showSpeedPicker() {
    _hideControlsTimer?.cancel();
    final controller = _videoController;
    if (controller == null) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('播放速度',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
              ),
              const Divider(height: 1, color: Colors.white24),
              ...kPlayerSpeedOptions.map((speed) {
                final selected = (speed - _playbackSpeed).abs() < 0.001;
                return ListTile(
                  dense: true,
                  title: Text(
                    speed == 1.0 ? '正常 (1.0x)' : '${speed}x',
                    style: TextStyle(
                      color: selected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.white,
                      fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  trailing: selected
                      ? Icon(Icons.check,
                          color: Theme.of(context).colorScheme.primary, size: 20)
                      : null,
                  onTap: () {
                    setState(() => _playbackSpeed = speed);
                    controller.setPlaybackSpeed(speed);
                    Navigator.of(sheetContext).pop();
                    _startHideControlsTimer();
                  },
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    ).then((_) {
      if (mounted) setState(() => _showControls = true);
    });
  }

  Widget _buildProgressBar(VideoPlayerController controller) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, child) {
        final total = value.duration.inMilliseconds;
        final progress =
            total > 0 ? (value.position.inMilliseconds / total) : 0.0;

        return LayoutBuilder(
          builder: (context, constraints) {
            final barWidth = constraints.maxWidth;

            void seekToFraction(double fraction) {
              if (total <= 0) return;
              final f = fraction.clamp(0.0, 1.0);
              _seekTo(Duration(milliseconds: (f * total).round()));
            }

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => seekToFraction(d.localPosition.dx / barWidth),
              onHorizontalDragUpdate: (d) =>
                  seekToFraction(d.localPosition.dx / barWidth),
              child: SizedBox(
                height: 22,
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.28),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    FractionallySizedBox(
                      widthFactor: progress.clamp(0.0, 1.0),
                      child: Container(
                        height: 3,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Positioned(
                      left: (barWidth * progress.clamp(0.0, 1.0)) - 5,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.black26, width: 0.5),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                setState(() { _isLoading = true; _error = null; });
                _loadVideo();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoInfo(Color cardColor, Color textColor, Color subColor) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(AppTheme.spacingMd),
      padding: const EdgeInsets.all(AppTheme.spacingLg),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          Text(widget.video.title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: textColor)),
          const Divider(height: 24),

          // 元数据行
          _buildInfoRow('时长', _durationText, textColor, subColor),
          _buildInfoRow('上传', _uploadDateText, textColor, subColor),
          _buildInfoRow('观看', _viewsText, textColor, subColor),

          // 作者 — 可点击跳转
          if (_authorId != null && _authorId!.isNotEmpty) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _navigateToAuthor,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  SizedBox(width: 48, child: Text('作者', style: TextStyle(fontSize: 13, color: subColor))),
                  Expanded(
                    child: Text(
                      _author ?? _authorId!,
                      style: TextStyle(fontSize: 13, color: AppTheme.primaryColor, fontWeight: FontWeight.w500),
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 18, color: AppTheme.primaryColor),
                ],
              ),
            ),
          ],

          const SizedBox(height: 16),
          // 下载按钮
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isDownloading ? null : _downloadVideo,
              icon: _isDownloading
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download),
              label: Text(_isDownloading ? '添加中...' : '下载此视频'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),

          const SizedBox(height: 12),
          // 实验性标识
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.science, size: 14, color: Colors.orange),
                SizedBox(width: 6),
                Text('实验性功能', style: TextStyle(fontSize: 12, color: Colors.orange)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String? value, Color textColor, Color subColor) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.spacingSm),
      child: Row(
        children: [
          SizedBox(width: 48, child: Text(label, style: TextStyle(fontSize: 13, color: subColor))),
          Expanded(child: Text(value ?? '-', style: TextStyle(fontSize: 13, color: textColor))),
        ],
      ),
    );
  }
}
