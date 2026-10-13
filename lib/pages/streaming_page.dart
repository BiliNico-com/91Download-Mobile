import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:provider/provider.dart';
import '../models/video_info.dart';
import '../services/app_state.dart';
import '../services/download_manager.dart';
import '../theme/app_theme.dart';
import '../utils/logger.dart';
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
  ChewieController? _chewieController;
  bool _isLoading = true;
  String? _error;
  String? _author;
  String? _authorId;
  String? _durationText;
  String? _viewsText;
  String? _uploadDateText;
  bool _isDownloading = false;

  @override
  void initState() {
    super.initState();
    _loadVideo();
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

      _chewieController = ChewieController(
        videoPlayerController: _videoController!,
        autoPlay: true,
        looping: false,
        allowFullScreen: true,
        allowPlaybackSpeedChanging: true,
        showControls: true,
        materialProgressColors: ChewieProgressColors(
          playedColor: AppTheme.primaryColor,
          handleColor: AppTheme.primaryLight,
          bufferedColor: AppTheme.primaryColor.withOpacity(0.3),
        ),
      );

      setState(() { _isLoading = false; });
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
    _chewieController?.dispose();
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
                      // 播放器：屏幕上半区域
                      SizedBox(
                        height: screenHeight * 0.42,
                        child: Chewie(controller: _chewieController!),
                      ),
                      // 视频信息
                      _buildVideoInfo(cardColor, textColor, subColor),
                    ],
                  ),
                ),
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
