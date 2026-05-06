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
  bool _isProcessingFollow = false;
  bool _isFollowed = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // 延迟到第一帧渲染完成后加载，避免 initState 中调用 setState
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final appState = Provider.of<AppState>(context, listen: false);
        setState(() => _isFollowed = appState.followedAuthorsService.isFollowedSync(widget.author.id));
        _loadMoreAuthorVideos();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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
    });
    await _loadMoreAuthorVideos();
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
        actions: [
          // 使用 Material + InkWell 替代 GestureDetector，解决真机触摸无响应问题
          // 通过 _isFollowed 本地状态缓存避免频繁重建
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _isProcessingFollow
                  ? null
                  : () async {
                      setState(() => _isProcessingFollow = true);
                      try {
                        bool success;
                        if (_isFollowed) {
                          success = await appState.followedAuthorsService.unfollow(widget.author.id);
                        } else {
                          success = await appState.followedAuthorsService.follow(
                            widget.author.id,
                            widget.author.name,
                            avatarUrl: widget.author.avatar,
                          );
                        }
                        if (success) {
                          appState.notifyListeners();
                          // 同步更新本地状态
                          if (mounted) {
                            setState(() => _isFollowed = !_isFollowed);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(_isFollowed ? '已取消关注' : '关注成功'),
                                duration: const Duration(seconds: 1),
                              ),
                            );
                          }
                        } else if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('操作失败，请重试')),
                          );
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('操作失败: $e')),
                          );
                        }
                      } finally {
                        if (mounted) setState(() => _isProcessingFollow = false);
                      }
                    },
              borderRadius: BorderRadius.circular(20),
              child: Container(
                margin: const EdgeInsets.only(right: 12),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: _isFollowed
                      ? (isDark ? Colors.grey[700]!.withOpacity(0.8) : Colors.grey[200]!)
                      : AppTheme.primaryColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _isFollowed
                        ? (isDark ? Colors.grey[600]!.withOpacity(0.3) : Colors.grey[300]!)
                        : AppTheme.primaryColor.withOpacity(0.25),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isProcessingFollow)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryColor),
                      )
                    else
                      Icon(
                        _isFollowed ? Icons.favorite : Icons.favorite_border,
                        size: 17,
                        color: _isFollowed
                            ? (isDark ? Colors.pink[300] : Colors.red[400])
                            : AppTheme.primaryColor,
                      ),
                    const SizedBox(width: 5),
                    Text(
                      _isProcessingFollow ? '处理中...' : (_isFollowed ? '已关注' : '关注'),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _isFollowed
                            ? (isDark ? Colors.grey[300] : Colors.grey[600])
                            : AppTheme.primaryColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
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
            // 作者信息头部
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
    );
  }

  Widget _buildAuthorHeader(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.spacingLg),
      margin: const EdgeInsets.all(AppTheme.spacingMd),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkSurface : AppTheme.cardBackground,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        children: [
          CircleAvatar(
            radius: 40,
            backgroundColor: AppTheme.primaryColor.withOpacity(0.1),
            child: const Icon(Icons.person, size: 40, color: AppTheme.primaryColor),
          ),
          const SizedBox(height: AppTheme.spacingMd),
          Text(
            widget.author.name,
            style: AppTheme.titleLarge.copyWith(
              color: isDark ? AppTheme.darkTextPrimary : AppTheme.textPrimary,
            ),
          ),
          if (widget.author.profileUrl?.isNotEmpty == true) ...[
            const SizedBox(height: AppTheme.spacingSm),
            Text(
              widget.author.profileUrl!,
              style: AppTheme.bodySmall.copyWith(
                color: isDark ? AppTheme.darkTextSecondary : AppTheme.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: AppTheme.spacingSm),
          Text(
            '${_authorVideos.length} 个视频',
            style: AppTheme.caption,
          ),
        ],
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
          return VideoCard(
            video: video,
            appState: appState,
            isListMode: true,
            showAuthor: false, // 作者页不需要显示作者
            showUploadDate: true,
            onTap: () {},
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
