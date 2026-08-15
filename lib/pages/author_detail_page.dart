import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/video_info.dart';
import '../services/app_state.dart';
import '../components/empty_state.dart';
import '../components/skeleton_card.dart';
import '../components/video_card.dart';
import '../theme/app_theme.dart';

/// 作者详情页
/// 
/// 从 SearchPage 中拆分出的独立页面，负责展示作者信息和视频列表
class AuthorDetailPage extends StatefulWidget {
  final AuthorInfo author;

  const AuthorDetailPage({
    super.key,
    required this.author,
  });

  @override
  State<AuthorDetailPage> createState() => _AuthorDetailPageState();
}

class _AuthorDetailPageState extends State<AuthorDetailPage> {
  final List<VideoInfo> _authorVideos = [];
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _authorHasMore = true;
  int _authorCurrentPage = 0;
  String? _errorMessage;
  
  // 关注状态（本地缓存，避免频繁重建）
  bool _isFollowed = false;
  bool _isProcessingFollow = false;

  // 视频选择与批量下载
  Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _refreshFollowStatus();
        _loadMoreAuthorVideos();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 刷新关注状态（从服务端同步）
  void _refreshFollowStatus() {
    final appState = Provider.of<AppState>(context, listen: false);
    setState(() {
      _isFollowed = appState.followedAuthorsService.isFollowedSync(widget.author.id);
    });
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMoreAuthorVideos();
    }
  }

  Future<void> _loadMoreAuthorVideos() async {
    if (!_authorHasMore || _isLoading || _isLoadingMore) return;

    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;

    setState(() {
      _isLoadingMore = true;
      _errorMessage = null;
    });

    try {
      _authorCurrentPage++;
      final newVideos = await crawler.getAuthorVideos(
        widget.author.id,
        page: _authorCurrentPage,
      );

      if (mounted) {
        if (newVideos.isEmpty) {
          setState(() => _authorHasMore = false);
        } else {
          setState(() {
            final existingIds = _authorVideos.map((v) => v.id).toSet();
            final unique = newVideos.where((v) => !existingIds.contains(v.id)).toList();
            _authorVideos.addAll(unique);
            if (newVideos.length < 20) {
              _authorHasMore = false;
            }
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = '加载失败: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isLoadingMore = false);
      }
    }
  }

  Future<void> _onRefresh() async {
    setState(() {
      _authorVideos.clear();
      _authorCurrentPage = 0;
      _authorHasMore = true;
      _errorMessage = null;
      _selectedIds.clear();
    });
    await _loadMoreAuthorVideos();
  }

  /// 下载选中的视频
  Future<void> _downloadSelected() async {
    final appState = Provider.of<AppState>(context, listen: false);
    final videos = _authorVideos.where((v) => _selectedIds.contains(v.id)).toList();
    if (videos.isEmpty) return;

    final result = await appState.downloadManager.addTasks(videos);
    final newCount = result['new'] ?? 0;
    final dupCount = result['duplicate'] ?? 0;

    if (mounted) {
      String msg = '已添加 $newCount 个任务到下载队列';
      if (dupCount > 0) msg += '，$dupCount 个已存在';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
        ),
      );
      setState(() => _selectedIds.clear());
    }
  }

  /// 全选/取消全选
  void _toggleSelectAll() {
    setState(() {
      if (_selectedIds.length == _authorVideos.length) {
        _selectedIds.clear();
      } else {
        _selectedIds = _authorVideos.map((v) => v.id).toSet();
      }
    });
  }

  /// 执行关注/取消关注操作
  Future<void> _toggleFollow() async {
    // 防重复点击
    if (_isProcessingFollow) return;

    // 参数校验
    if (widget.author.id.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('作者ID为空，无法关注'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    
    setState(() => _isProcessingFollow = true);

    try {
      final appState = Provider.of<AppState>(context, listen: false);
      String? error;

      if (_isFollowed) {
        error = await appState.followedAuthorsService.unfollow(widget.author.id);
      } else {
        error = await appState.followedAuthorsService.follow(
          widget.author.id,
          widget.author.name.isNotEmpty ? widget.author.name : widget.author.id,
          avatarUrl: widget.author.avatar,
        );
      }

      if (mounted) {
        if (error == null) {
          setState(() => _isFollowed = !_isFollowed);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_isFollowed ? '已关注' : '已取消关注'),
              duration: const Duration(seconds: 1),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(error),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('操作失败: $e'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessingFollow = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.author.name),
        centerTitle: true,
        elevation: 0,
        actions: _authorVideos.isNotEmpty
            ? [
                // 全选/取消全选
                IconButton(
                  icon: Icon(_selectedIds.length == _authorVideos.length
                      ? Icons.deselect
                      : Icons.select_all),
                  onPressed: _toggleSelectAll,
                  tooltip: _selectedIds.length == _authorVideos.length ? '取消全选' : '全选',
                ),
              ]
            : null,
      ),
      body: RefreshIndicator(
        onRefresh: _onRefresh,
        color: AppTheme.primaryColor,
        backgroundColor: isDark ? AppTheme.darkSurface : Colors.white,
        displacement: 40,
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // 作者信息头部（含关注按钮）
            SliverToBoxAdapter(
              child: _buildAuthorHeader(isDark),
            ),
            // 视频列表
            _buildVideoList(appState, isDark),
            // 底部加载指示器
            _buildBottomLoader(),
          ],
        ),
      ),
      floatingActionButton: _selectedIds.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: _downloadSelected,
              icon: const Icon(Icons.download),
              label: Text('下载 (${_selectedIds.length})'),
              backgroundColor: AppTheme.primaryColor,
            )
          : null,
    );
  }

  Widget _buildAuthorHeader(bool isDark) {
    final bgColor = isDark ? AppTheme.darkSurface : AppTheme.cardBackground;
    final textColor = isDark ? AppTheme.darkTextPrimary : AppTheme.textPrimary;
    final subTextColor = isDark ? AppTheme.darkTextSecondary : AppTheme.textSecondary;

    return Container(
      margin: const EdgeInsets.all(AppTheme.spacingMd),
      padding: const EdgeInsets.all(AppTheme.spacingLg),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        children: [
          // 头像
          CircleAvatar(
            radius: 40,
            backgroundColor: AppTheme.primaryColor.withOpacity(0.1),
            child: Icon(Icons.person, size: 40, color: AppTheme.primaryColor),
          ),
          const SizedBox(height: AppTheme.spacingMd),
          // 作者名
          Text(
            widget.author.name,
            style: AppTheme.titleLarge.copyWith(color: textColor),
          ),
          // 个人主页链接
          if (widget.author.profileUrl?.isNotEmpty == true) ...[
            const SizedBox(height: AppTheme.spacingSm),
            Text(
              widget.author.profileUrl!,
              style: AppTheme.bodySmall.copyWith(color: subTextColor),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: AppTheme.spacingSm),
          // 视频数量
          Text(
            '${_authorVideos.length} 个视频',
            style: AppTheme.caption,
          ),

          const SizedBox(height: AppTheme.spacingLg),

          // ─── 关注/取消关注按钮（从AppBar移到body区域，彻底解决触摸问题） ───
          _buildFollowButton(isDark),

          const SizedBox(height: AppTheme.spacingMd),
        ],
      ),
    );
  }

  /// 构建关注按钮（独立方法，使用 GestureDetector + Container 确保真机可点击）
  Widget _buildFollowButton(bool isDark) {
    final isFollowing = _isFollowed;
    final isDisabled = _isProcessingFollow;

    // 按钮颜色配置
    Color bgColor;
    Color borderColor;
    Color iconColor;
    Color textColor;
    String label;
    Widget? trailing;

    if (isFollowing) {
      bgColor = isDark ? Colors.grey[700]!.withOpacity(0.8) : Colors.grey[200]!;
      borderColor = isDark ? Colors.grey[600]!.withOpacity(0.3) : Colors.grey[300]!;
      iconColor = isDark ? Colors.pink[300]! : Colors.red[400]!;
      textColor = isDark ? Colors.grey[300]! : Colors.grey[600]!;
      label = '已关注';
    } else {
      bgColor = AppTheme.primaryColor.withOpacity(0.12);
      borderColor = AppTheme.primaryColor.withOpacity(0.25);
      iconColor = AppTheme.primaryColor;
      textColor = AppTheme.primaryColor;
      label = '关注作者';
    }

    if (isDisabled) {
      trailing = SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: iconColor),
      );
      label = '处理中...';
    }

    // 使用 GestureDetector + Container，确保触摸区域足够大且不被拦截
    return GestureDetector(
      onTap: isDisabled ? null : _toggleFollow,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        height: 48,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: borderColor, width: 1),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isFollowing ? Icons.favorite : Icons.favorite_border,
              size: 20,
              color: iconColor,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildVideoList(AppState appState, bool isDark) {
    if (_isLoading && _authorVideos.isEmpty) {
      return const SliverFillRemaining(
        child: ShimmerVideoList(isListMode: true, count: 6),
      );
    }

    if (_errorMessage != null && _authorVideos.isEmpty) {
      return SliverFillRemaining(
        child: EmptyState.networkError(onRetry: _onRefresh),
      );
    }

    if (_authorVideos.isEmpty && !_isLoadingMore) {
      return const SliverFillRemaining(
        child: EmptyState(
          icon: Icons.videocam_off,
          title: '该作者暂无视频',
          subtitle: '作者可能还没有上传任何内容',
        ),
      );
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final video = _authorVideos[index];
          final isSelected = _selectedIds.contains(video.id);
          return VideoCard(
            video: video,
            appState: appState,
            isListMode: true,
            isSelected: isSelected,
            showAuthor: false,
            showUploadDate: true,
            onTap: () {
              setState(() {
                if (isSelected) {
                  _selectedIds.remove(video.id);
                } else {
                  _selectedIds.add(video.id);
                }
              });
            },
          );
        },
        childCount: _authorVideos.length,
      ),
    );
  }

  Widget _buildBottomLoader() {
    if (!_isLoadingMore) return const SliverToBoxAdapter(child: SizedBox.shrink());

    return const SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.all(AppTheme.spacingLg),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
    );
  }
}
