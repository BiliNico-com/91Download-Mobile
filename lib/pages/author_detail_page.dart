import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/video_info.dart';
import '../services/app_state.dart';
import '../components/cover_image.dart';
import '../components/empty_state.dart';
import '../components/skeleton_card.dart';
import '../components/video_list_items.dart';
import '../components/app_shell.dart';
import '../theme/app_tokens.dart';
import 'streaming_page.dart';

/// 作者详情页
///
/// 从 SearchPage 中拆分出的独立页面，负责展示作者信息和视频列表。
/// 视觉按新版设计：顶部作者卡（头像 + 名字 + 关注 + 三栏数据），
/// 下面是行式视频列表，选中后底部浮出下载条。
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
  bool _isLoading = true;
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
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMoreAuthorVideos();
    }
  }

  Future<void> _loadMoreAuthorVideos() async {
    if (!_authorHasMore || _isLoading || _isLoadingMore) return;

    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

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
            final unique =
                newVideos.where((v) => !existingIds.contains(v.id)).toList();
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
        setState(() {
          _isLoadingMore = false;
          _isLoading = false;
        });
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
    final videos =
        _authorVideos.where((v) => _selectedIds.contains(v.id)).toList();
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

  /// 关注/取消关注
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
          widget.author.name.isNotEmpty
              ? widget.author.name
              : widget.author.id,
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
    final t = AppTokens.of(context);
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: t.bg,
      appBar: _buildAppBar(t),
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _onRefresh,
            color: t.accent,
            backgroundColor: t.surface,
            child: ListView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(12, 12, 12, bottomInset + 96),
              children: [
                _buildHero(appState, t),
                const SizedBox(height: 14),
                _buildListHead(t),
                const SizedBox(height: 9),
                ..._buildVideoRows(appState, t),
                if (_isLoadingMore)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: t.accent,
                        ),
                      ),
                    ),
                  ),
                if (!_authorHasMore && _authorVideos.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Center(
                      child: Text(
                        '· 已经到底了 ·',
                        style: TextStyle(fontSize: 11.5, color: t.text3),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_selectedIds.isNotEmpty)
            Positioned(
              left: 12,
              right: 12,
              bottom: bottomInset + 12,
              child: AppFloatBar(
                selectedCount: _selectedIds.length,
                actionLabel: '开始下载',
                onAction: _downloadSelected,
                onCancel: () => setState(() => _selectedIds.clear()),
              ),
            ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(AppTokens t) {
    return AppBar(
      backgroundColor: t.surface,
      centerTitle: false,
      toolbarHeight: 58,
      titleSpacing: 0,
      leadingWidth: 52,
      leading: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Center(
          child: AppIconBtn(
            icon: Icons.arrow_back_rounded,
            tooltip: '返回',
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
      ),
      title: Text(
        '作者主页',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: t.text1,
        ),
      ),
      actions: [
        if (_isProcessingFollow)
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
              ),
            ),
          ),
      ],
      shape: Border(bottom: BorderSide(color: t.line, width: 1)),
    );
  }

  /// 作者信息卡：头像 + 名字 + 关注按钮 + 三栏数据
  Widget _buildHero(AppState appState, AppTokens t) {
    final name =
        widget.author.name.isNotEmpty ? widget.author.name : widget.author.id;
    final family = SitePill.familyNames[appState.currentSiteType] ?? '站点';
    final stats = <String>[
      _authorHasMore ? '${_authorVideos.length}+' : '${_authorVideos.length}',
    ];

    return Container(
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
          Row(
            children: [
              _buildAvatar(t),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.3,
                              color: t.text1,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: t.accentSoft,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            '作者',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              color: t.accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      _isFollowed ? '已关注 · 有新内容会在「已关注」提示' : '关注后可在「已关注」查看更新',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: t.text3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _buildFollowBtn(t),
            ],
          ),
          const SizedBox(height: 13),
          Divider(height: 1, thickness: 1, color: t.line),
          const SizedBox(height: 11),
          Row(
            children: [
              _buildStat(t, stats.first, '作品'),
              _buildStat(t, family, '站点'),
              _buildStat(t, _authorHasMore ? '加载中' : '已加载完', '状态'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(AppTokens t) {
    final name =
        widget.author.name.isNotEmpty ? widget.author.name : widget.author.id;
    final letter = name.isEmpty ? '?' : name.characters.first.toUpperCase();

    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            width: 62,
            height: 62,
            child: (widget.author.avatar != null &&
                    widget.author.avatar!.isNotEmpty)
                ? CoverImage(
                    url: widget.author.avatar!,
                    borderRadius: BorderRadius.circular(999),
                    fallbackIcon: Icons.person_rounded,
                    fallbackIconSize: 28,
                  )
                : Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [AppTokens.blue, Color(0xFF42A5F5)],
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      letter,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
          ),
        ),
        Positioned(
          right: 1,
          bottom: 1,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: t.success,
              shape: BoxShape.circle,
              border: Border.all(color: t.surface, width: 2),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStat(AppTokens t, String value, String label) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: t.text1,
            ),
          ),
          const SizedBox(height: 3),
          Text(label, style: TextStyle(fontSize: 10.5, color: t.text3)),
        ],
      ),
    );
  }

  Widget _buildFollowBtn(AppTokens t) {
    return GestureDetector(
      onTap: _onFollowToggle,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: _isFollowed ? t.dangerSoft : t.accentSoft,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _isFollowed ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              size: 13,
              color: _isFollowed ? t.danger : t.accent,
            ),
            const SizedBox(width: 4),
            Text(
              _isFollowed ? '已关注' : '关注',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: _isFollowed ? t.danger : t.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildListHead(AppTokens t) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        children: [
          Text(
            '共 ${_authorVideos.length} 条视频',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: t.text3,
            ),
          ),
          const Spacer(),
          if (_selectedIds.isNotEmpty) ...[
            AppCountPill(text: '已选 ${_selectedIds.length}', color: t.accent),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _toggleSelectAll,
              behavior: HitTestBehavior.opaque,
              child: Container(
                height: 26,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color:
                      _selectedIds.length == _authorVideos.length
                          ? AppTokens.blue
                          : t.surface2,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                alignment: Alignment.center,
                child: Text(
                  _selectedIds.length == _authorVideos.length ? '取消全选' : '全选',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: _selectedIds.length == _authorVideos.length
                        ? Colors.white
                        : t.text2,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildVideoRows(AppState appState, AppTokens t) {
    if (_isLoading && _authorVideos.isEmpty) {
      // 这里是 ListView 的 children，再嵌 ListView 会拿到无界高度，
      // 所以用非滚动的 Inline 版本
      return const [
        ShimmerVideoInline(isListMode: true, count: 6),
      ];
    }

    if (_errorMessage != null && _authorVideos.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: 40),
          child: EmptyState.networkError(onRetry: _onRefresh),
        ),
      ];
    }

    if (_authorVideos.isEmpty && !_isLoadingMore) {
      return const [
        Padding(
          padding: EdgeInsets.only(top: 40),
          child: EmptyState(
            icon: Icons.videocam_off_rounded,
            title: '该作者暂无视频',
            subtitle: '作者可能还没有上传任何内容',
            iconSize: 56,
          ),
        ),
      ];
    }

    return [
      for (final video in _authorVideos)
        VideoListItem(
          video: video,
          appState: appState,
          isSelected: _selectedIds.contains(video.id),
          showUploadDate: true,
          onTap: () {
            setState(() {
              if (_selectedIds.contains(video.id)) {
                _selectedIds.remove(video.id);
              } else {
                _selectedIds.add(video.id);
              }
            });
          },
          onCoverTap: appState.streamingMode
              ? () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => StreamingPage(video: video),
                    ),
                  );
                }
              : null,
        ),
    ];
  }
}
