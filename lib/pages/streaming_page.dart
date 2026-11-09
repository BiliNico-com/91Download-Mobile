import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:provider/provider.dart';
import '../crawler/config.dart';
import '../models/video_info.dart';
import '../services/app_state.dart';
import '../services/download_manager.dart';
import '../theme/app_tokens.dart';
import '../utils/logger.dart';
import '../components/player_glass.dart';
import 'author_detail_page.dart';

/// 在线播放页（实验性功能）
///
/// 视觉对齐新版设计：上方深色播放区（顶栏标题 + 返回 + 下载入口），
/// 下方浅色信息卡（标题、元数据、作者、下载按钮）。
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
        setState(() {
          _error = '请先在设置中选择站点';
          _isLoading = false;
        });
        return;
      }

      final detail = await crawler.getVideoDetail(widget.video);
      if (detail == null || detail.m3u8Url == null) {
        // 用爬虫记录的真实原因，不要把「被站点人机验证拦下」
        // 也说成笼统的「无法获取播放地址」——两者用户该做的事完全不同
        final reason = crawler.lastDetailError;
        setState(() {
          _error = (reason != null && reason.isNotEmpty)
              ? reason
              : '无法获取视频播放地址';
          _isLoading = false;
        });
        return;
      }

      logger.log('Streaming', 'm3u8: ${detail.m3u8Url}');
      _author = detail.author;
      _authorId = detail.authorId;
      _durationText = detail.duration;
      _viewsText = detail.views;
      _uploadDateText = detail.uploadDate;

      // 地址可能是协议相对的（//cdn.../index.m3u8），Uri.parse 会抛
      // Unsupported scheme ''，播放页会显示「播放加载失败」。
      _videoController = VideoPlayerController.networkUrl(
        Uri.parse(CrawlerConfig.resolveAbsoluteUrl(
            detail.url, detail.m3u8Url!)),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );

      await _videoController!.initialize();
      if (!mounted) return;

      // 说明：此处原使用 Chewie 自带控件，与内置播放器的自绘控件风格不一致。
      // 现改为只用 video_player 渲染画面 + 自绘玻璃控件，两个播放页保持统一。
      _videoController!.setLooping(false);

      setState(() {
        _isLoading = false;
      });
      // 自动开播后启动控件自动隐藏
      _startHideControlsTimer();
    } catch (e) {
      logger.log('Streaming', 'Error: $e');
      setState(() {
        _error = '播放加载失败: $e';
        _isLoading = false;
      });
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
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
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
    final t = AppTokens.of(context);
    final screenHeight = MediaQuery.of(context).size.height;
    final statusBarH = MediaQuery.of(context).padding.top;

    if (_isLoading) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            const Center(
              child: CircularProgressIndicator(color: Colors.white70, strokeWidth: 2.5),
            ),
            _buildTopBar(t, statusBarH, overlay: true),
          ],
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            _buildErrorView(t),
            _buildTopBar(t, statusBarH, overlay: true),
          ],
        ),
      );
    }

    // 播放区高度：状态栏 + 顶栏 + 画面（16:9），不超过屏幕 46%
    final playerHeight =
        (screenHeight * 0.46).clamp(200.0, screenHeight * 0.46);

    return Scaffold(
      backgroundColor: t.bg,
      body: Column(
        children: [
          // ── 深色播放区 ──
          Container(
            color: Colors.black,
            child: Column(
              children: [
                _buildTopBar(t, statusBarH, overlay: false),
                SizedBox(
                  height: playerHeight - statusBarH - 46,
                  child: _buildPlayer(),
                ),
              ],
            ),
          ),
          // ── 浅色内容区 ──
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                  12, 14, 12, MediaQuery.of(context).padding.bottom + 24),
              child: _buildVideoInfo(t),
            ),
          ),
        ],
      ),
    );
  }

  /// 播放区顶栏：返回 + 标题 + 下载
  Widget _buildTopBar(AppTokens t, double statusBarH, {required bool overlay}) {
    return Container(
      color: overlay ? Colors.transparent : Colors.black,
      padding: EdgeInsets.only(top: statusBarH),
      child: SizedBox(
        height: 46,
        child: Row(
          children: [
            const SizedBox(width: 8),
            // 尺寸与圆角对齐全站 AppIconBtn（34x34 / r11 / 图标 19）：
            // 之前这里是 32x32 / r10，比别的页面小一圈，方框看起来「比例不对」。
            GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.arrow_back_rounded,
                    size: 19, color: Colors.white),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.video.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
            GestureDetector(
              onTap: _isDownloading ? null : _downloadVideo,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 34,
                height: 34,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                alignment: Alignment.center,
                child: _isDownloading
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.download_rounded,
                        size: 19, color: Colors.white),
              ),
            ),
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
                  icon: value.isPlaying ? Icons.pause : Icons.play_arrow,
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
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 11),
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
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 11),
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
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600),
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
                      fontWeight:
                          selected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  trailing: selected
                      ? Icon(Icons.check,
                          color: Theme.of(context).colorScheme.primary,
                          size: 20)
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

  Widget _buildErrorView(AppTokens t) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.10),
                borderRadius: BorderRadius.circular(AppRadius.xxl),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.error_outline_rounded,
                  size: 30, color: Colors.white70),
            ),
            const SizedBox(height: 16),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, height: 1.5, color: Colors.white70),
            ),
            const SizedBox(height: 22),
            GestureDetector(
              onTap: () {
                setState(() {
                  _isLoading = true;
                  _error = null;
                });
                _loadVideo();
              },
              behavior: HitTestBehavior.opaque,
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 22),
                decoration: BoxDecoration(
                  color: AppTokens.blue,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                alignment: Alignment.center,
                child: const Text(
                  '重试',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 下方信息卡：标题 + 元数据 + 作者 + 下载按钮 + 实验性标识
  Widget _buildVideoInfo(AppTokens t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(AppRadius.xxl),
            border: t.cardBorder,
            boxShadow: t.cardShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.video.title,
                style: TextStyle(
                  fontSize: 14.5,
                  height: 1.45,
                  fontWeight: FontWeight.w700,
                  color: t.text1,
                ),
              ),
              const SizedBox(height: 12),
              _buildMetaChips(t),
              const SizedBox(height: 14),
              Divider(height: 1, thickness: 1, color: t.line),
              const SizedBox(height: 6),
              if (_authorId != null && _authorId!.isNotEmpty)
                _buildAuthorRow(t),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: _isDownloading ? null : _downloadVideo,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 46,
            decoration: BoxDecoration(
              color: _isDownloading ? t.surface3 : AppTokens.blue,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isDownloading)
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: t.text3),
                  )
                else
                  const Icon(Icons.download_rounded,
                      size: 18, color: Colors.white),
                const SizedBox(width: 7),
                Text(
                  _isDownloading ? '添加中...' : '下载此视频',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: _isDownloading ? t.text3 : Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: t.warningSoft,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.science_rounded, size: 12, color: t.warning),
                const SizedBox(width: 5),
                Text(
                  '实验性功能',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: t.warning,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 元数据胶囊行：时长 / 上传 / 观看
  Widget _buildMetaChips(AppTokens t) {
    final items = <Widget>[];
    void add(IconData icon, String? text) {
      if (text == null || text.isEmpty) return;
      items.add(
        Container(
          margin: const EdgeInsets.only(right: 7, bottom: 7),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: t.surface2,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 11, color: t.text3),
              const SizedBox(width: 4),
              Text(
                text,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: t.text2,
                ),
              ),
            ],
          ),
        ),
      );
    }

    add(Icons.schedule_rounded, _durationText);
    add(Icons.calendar_today_rounded, _uploadDateText);
    add(Icons.visibility_rounded, _viewsText);
    if (items.isEmpty) return const SizedBox.shrink();
    return Wrap(children: items);
  }

  Widget _buildAuthorRow(AppTokens t) {
    return InkWell(
      onTap: _navigateToAuthor,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: t.accentSoft,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.person_rounded, size: 16, color: t.accent),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _author ?? _authorId!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: t.text1,
                ),
              ),
            ),
            Text(
              '查看主页',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: t.accent,
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: t.accent),
          ],
        ),
      ),
    );
  }
}
