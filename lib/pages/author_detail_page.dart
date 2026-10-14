import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/video_info.dart';
import '../services/app_state.dart';
import '../components/empty_state.dart';
import '../components/skeleton_card.dart';
import '../components/video_card.dart';
import '../theme/app_theme.dart';
import '../theme/ui_style.dart';

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

  // ─── 折叠头（与批量页作者主页保持一致的视觉）───
  static const double _kExpandedHeight = 130.0;
  static const double _kCollapsedHeight = 56.0;
  double _collapseRatio = 0.0;

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
    // 头部折叠比例（驱动 SliverPersistentHeader 的展开/收起形态）
    final expandRange = _kExpandedHeight - _kCollapsedHeight;
    final offset = _scrollController.offset.clamp(0.0, expandRange);
    final ratio = offset / expandRange;
    if ((ratio - _collapseRatio).abs() > 0.01) {
      setState(() => _collapseRatio = ratio);
    }

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
          // 由爬虫依据站点"下一页"控件判定（条数不固定时更可靠）
          final siteHasMore = crawler.lastRequestHasMore;
          setState(() {
            final existingIds = _authorVideos.map((v) => v.id).toSet();
            final unique = newVideos.where((v) => !existingIds.contains(v.id)).toList();
            _authorVideos.addAll(unique);
            _authorHasMore = siteHasMore;
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

  /// 关注/取消关注（折叠头上的胶囊按钮）
  ///
  /// 保留原有的防重复点击与错误提示，只是入口从卡片按钮换到了头部。
  Future<void> _onFollowToggle() async {
    if (_isProcessingFollow) return;

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
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
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
    final statusBarH = MediaQuery.of(context).padding.top;

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _onRefresh,
            color: AppTheme.primaryColor,
            backgroundColor: isDark ? AppTheme.darkSurface : Colors.white,
            displacement: 40,
            child: CustomScrollView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                // 折叠头：与批量页作者主页保持一致的样式与交互
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _AuthorHeaderDelegate(
                    statusBarHeight: statusBarH,
                    expandedHeight: _kExpandedHeight,
                    collapsedHeight: _kCollapsedHeight,
                    collapseRatio: _collapseRatio,
                    authorName: widget.author.name,
                    videoCount: _authorVideos.length,
                    isFollowed: _isFollowed,
                    onFollowToggle: _onFollowToggle,
                    onBack: () => Navigator.of(context).maybePop(),
                    selectedCount: _selectedIds.length,
                    onToggleSelectAll: _authorVideos.isEmpty
                        ? null
                        : _toggleSelectAll,
                    allSelected: _authorVideos.isNotEmpty &&
                        _selectedIds.length == _authorVideos.length,
                  ),
                ),
                // 视频列表
                _buildVideoList(appState, isDark),
                // 底部加载指示器
                _buildBottomLoader(),
                // 给底部浮动按钮留白
                const SliverToBoxAdapter(child: SizedBox(height: 96)),
              ],
            ),
          ),
        ],
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

  // 说明：原卡片式头部（大头像 + 独立关注按钮）与 AppBar 已移除，
  // 统一改为与批量页作者主页一致的折叠头（见文件末尾 _AuthorHeaderDelegate）。

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

/// 作者主页折叠头
///
/// 样式与交互对齐批量页（batch_page）的作者主页模式：
///   · 毛玻璃背景（BackdropFilter）+ 主题配色
///   · 展开 130 / 收起 56，滚动时平滑过渡
///   · 返回按钮（蓝底圆角方块）
///   · 标题「作者: XXX」+ 关注胶囊按钮
///   · 展开时第二行显示已加载视频数
class _AuthorHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double statusBarHeight;
  final double expandedHeight;
  final double collapsedHeight;
  final double collapseRatio;

  final String authorName;
  final int videoCount;
  final bool isFollowed;
  final VoidCallback onFollowToggle;
  final VoidCallback onBack;

  /// 已选数量与全选（选中态才展示，避免平时干扰）
  final int selectedCount;
  final VoidCallback? onToggleSelectAll;
  final bool allSelected;

  _AuthorHeaderDelegate({
    required this.statusBarHeight,
    required this.expandedHeight,
    required this.collapsedHeight,
    required this.collapseRatio,
    required this.authorName,
    required this.videoCount,
    required this.isFollowed,
    required this.onFollowToggle,
    required this.onBack,
    this.selectedCount = 0,
    this.onToggleSelectAll,
    this.allSelected = false,
  });

  @override
  double get minExtent => statusBarHeight + collapsedHeight;

  @override
  double get maxExtent => statusBarHeight + expandedHeight;

  @override
  Widget build(BuildContext ctx, double shrinkOffset, bool overlapsContent) {
    final isDark = Theme.of(ctx).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subTextColor = isDark ? Colors.grey : Colors.black54;

    final expanded = collapseRatio < 0.5;

    // 顶部栏背后是滚动的视频列表，毛玻璃开关在这里差异最明显
    return ValueListenableBuilder<bool>(
      valueListenable: UiStyle.glassEnabled,
      builder: (context, glass, _) {
        final bgColor = glass
            ? (isDark
                ? Colors.black.withOpacity(0.55)
                : Colors.white.withOpacity(0.72))
            : (isDark ? Theme.of(ctx).cardColor : Colors.white);

        final header = Container(
          color: bgColor,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: statusBarHeight),

              // ── 第一行：返回 + 标题 + 关注 + 全选 ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // 返回按钮
                    GestureDetector(
                      onTap: onBack,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.blue.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.arrow_back,
                            size: 20, color: Colors.blue),
                      ),
                    ),

                    // 标题 + 关注按钮
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              '作者: $authorName',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: expanded ? 20 : 16,
                                fontWeight: FontWeight.w600,
                                color: textColor,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _buildFollowChip(expanded),
                        ],
                      ),
                    ),

                    // 选中态才显示全选
                    if (selectedCount > 0 && onToggleSelectAll != null)
                      GestureDetector(
                        onTap: onToggleSelectAll,
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          margin: const EdgeInsets.only(right: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.blue.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                allSelected
                                    ? Icons.deselect
                                    : Icons.select_all,
                                size: 16,
                                color: Colors.blue,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                allSelected ? '取消' : '全选',
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.blue),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // ── 第二行：副标题（仅展开时）──
              if (expanded)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Text(
                    '已加载 $videoCount 个视频 (作者主页)',
                    style: TextStyle(fontSize: 12, color: subTextColor),
                  ),
                ),
            ],
          ),
        );

        // 关闭玻璃时省掉 BackdropFilter 开销
        if (!glass) return header;

        return ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: header,
          ),
        );
      },
    );
  }

  /// 关注胶囊按钮（展开/收起用不同尺寸）
  Widget _buildFollowChip(bool expanded) {
    final hPad = expanded ? 12.0 : 10.0;
    final vPad = expanded ? 6.0 : 4.0;
    final fontSize = expanded ? 13.0 : 12.0;
    final iconSize = expanded ? 16.0 : 14.0;
    final radius = expanded ? 16.0 : 12.0;

    return GestureDetector(
      onTap: onFollowToggle,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
        decoration: BoxDecoration(
          color: isFollowed
              ? Colors.red.withOpacity(0.2)
              : Colors.blue.withOpacity(0.2),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: isFollowed ? Colors.red : Colors.blue,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isFollowed ? Icons.favorite : Icons.favorite_border,
              size: iconSize,
              color: isFollowed ? Colors.red : Colors.blue,
            ),
            const SizedBox(width: 4),
            Text(
              isFollowed ? '已关注' : '关注',
              style: TextStyle(
                fontSize: fontSize,
                color: isFollowed ? Colors.red : Colors.blue,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _AuthorHeaderDelegate old) {
    return old.statusBarHeight != statusBarHeight ||
        old.expandedHeight != expandedHeight ||
        old.collapsedHeight != collapsedHeight ||
        old.collapseRatio != collapseRatio ||
        old.authorName != authorName ||
        old.videoCount != videoCount ||
        old.isFollowed != isFollowed ||
        old.selectedCount != selectedCount ||
        old.allSelected != allSelected;
  }
}
