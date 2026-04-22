import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../crawler/config.dart';
import '../models/video_info.dart';
import '../services/app_state.dart';
import '../services/followed_authors_service.dart';
import '../utils/logger.dart';

class BatchPage extends StatefulWidget {
  const BatchPage({super.key});

  @override
  State<BatchPage> createState() => _BatchPageState();
}

class _BatchPageState extends State<BatchPage> with AutomaticKeepAliveClientMixin {
  String _selectedType = 'list';
  int _currentPage = 1;
  int _loadedPage = 0;
  bool _hasMore = true;
  List<VideoInfo> _videos = [];
  Set<String> _selectedIds = {};
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String _status = '就绪';
  double _progress = 0.0;
  String _progressText = '';
  int _totalVideos = 0;
  
  // 作者主页模式
  bool _isAuthorPageMode = false;
  String _currentAuthorId = '';
  String _currentAuthorName = '';
  List<VideoInfo> _authorVideos = [];
  int _authorCurrentPage = 0;
  bool _authorHasMore = true;
  
  // 进入作者主页前的滚动位置（返回时恢复）
  double _savedScrollOffset = 0;

  // ─── 新增：滚动折叠比例 ───
  double _collapseRatio = 0.0;

  final ScrollController _scrollController = ScrollController();
  bool _showBackToTop = false;
  final TextEditingController _pageController = TextEditingController();

  // ─── 布局常量 ───
  static const double _kExpandedHeight = 130.0;
  static const double _kCollapsedHeight = 56.0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _pageController.text = '1';
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _onScroll() {
    // ─── 回顶部按钮显示/隐藏 ───
    final showBtn = _scrollController.offset > 500;
    if (showBtn != _showBackToTop) {
      setState(() => _showBackToTop = showBtn);
    }
    // ─── 瀑布流自动加载 ───
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      if (!_isLoading && !_isLoadingMore) {
        // 作者主页模式
        if (_isAuthorPageMode && _authorHasMore && _authorVideos.isNotEmpty) {
          _loadMoreAuthorVideos();
        }
        // 普通模式
        else if (!_isAuthorPageMode && _hasMore && _videos.isNotEmpty) {
          _loadMore();
        }
      }
    }
    // ─── 折叠比例计算 ───
    final expandRange = _kExpandedHeight - _kCollapsedHeight;
    final offset = _scrollController.offset.clamp(0.0, expandRange);
    final ratio = offset / expandRange;
    if ((ratio - _collapseRatio).abs() > 0.01) {
      setState(() => _collapseRatio = ratio);
    }
  }

  Future<void> _loadMore() async {
    if (!_hasMore || _isLoading || _isLoadingMore) return;
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;

    setState(() => _isLoadingMore = true);
    final nextPage = _loadedPage + 1;
    final newVideos = await crawler.getVideoList(_selectedType, nextPage);

    if (newVideos.isEmpty) {
      setState(() {
        _hasMore = false;
        _isLoadingMore = false;
      });
    } else {
      setState(() {
        _videos.addAll(newVideos);
        _totalVideos = _videos.length;
        _loadedPage = nextPage;
        _hasMore = newVideos.length >= 24;
        _isLoadingMore = false;
      });
    }
  }

  void _scrollToTop() {
    _scrollController.animateTo(0, duration: Duration(milliseconds: 300), curve: Curves.easeOut);
  }
  
  /// 进入作者主页模式
  Future<void> _enterAuthorPageMode(String authorId, String authorName) async {
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;
    
    // 保存当前滚动位置
    _savedScrollOffset = _scrollController.offset;
    
    // 设置返回键回调，让 MainPage 能处理作者模式的返回
    appState.onWillPopCallback = () {
      if (_isAuthorPageMode) {
        _exitAuthorPageMode();
        return true;
      }
      return false;
    };
    
    setState(() {
      _isAuthorPageMode = true;
      _currentAuthorId = authorId;
      _currentAuthorName = authorName;
      _authorVideos.clear();
      _authorCurrentPage = 0;
      _authorHasMore = true;
      _selectedIds.clear();
    });
    
    // 滚动到顶部加载作者视频
    _scrollController.jumpTo(0);
    await _loadMoreAuthorVideos();
  }
  
  /// 退出作者主页模式
  void _exitAuthorPageMode() {
    final appState = context.read<AppState>();
    // 清除返回键回调
    appState.onWillPopCallback = null;
    
    final savedOffset = _savedScrollOffset;
    setState(() {
      _isAuthorPageMode = false;
      _authorVideos.clear();
      _currentAuthorId = '';
      _currentAuthorName = '';
      _selectedIds.clear();
    });
    // 恢复进入前的滚动位置
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        final maxOffset = _scrollController.position.maxScrollExtent;
        if (savedOffset <= maxOffset) {
          _scrollController.jumpTo(savedOffset);
        }
      }
    });
  }
  
  /// 加载更多作者视频
  Future<void> _loadMoreAuthorVideos() async {
    if (!_authorHasMore || _isLoading) return;
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;
    
    setState(() => _isLoading = true);
    _authorCurrentPage++;
    
    final newVideos = await crawler.getAuthorVideos(_currentAuthorId, page: _authorCurrentPage);
    
    if (newVideos.isEmpty) {
      setState(() {
        _authorHasMore = false;
        _isLoading = false;
      });
    } else {
      setState(() {
        _authorVideos.addAll(newVideos);
        _isLoading = false;
        if (newVideos.length < 20) _authorHasMore = false;
      });
    }
  }
  
  /// 下拉刷新（只在顶部时触发）
  Future<void> _onRefresh() async {
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;
    
    if (_isAuthorPageMode) {
      // 作者模式下刷新作者视频
      setState(() {
        _authorVideos.clear();
        _selectedIds.clear();
        _authorCurrentPage = 0;
        _authorHasMore = true;
      });
      await _loadMoreAuthorVideos();
    } else {
      // 重新加载第一页
      setState(() {
        _videos.clear();
        _selectedIds.clear();
        _loadedPage = 0;
        _hasMore = true;
      });
      await _goToPage();
    }
  }

  static const _typeNamesPorn91 = {
    'list': '视频',
    'ori': '91原创',
    'hot': '当前最热',
    'top': '本月最热',
    'topm': '每月最热',
    'long': '10分钟以上',
    'longer': '20分钟以上',
    'tf': '本月收藏',
    'rf': '最近加精',
    'hd': '高清',
    'md': '本月讨论',
    'mf': '收藏最多',
  };

  static const _typeNamesOriginal = {
    'list': '视频',
    'top7': '周榜',
    'top': '月榜',
    '5min': '5分钟+',
    'long': '10分钟+',
  };

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final statusBarH = MediaQuery.of(context).padding.top;
    return Consumer<AppState>(
      builder: (context, appState, _) {
        // 检查是否有待进入的作者主页（从关注页面跳转）
        if (appState.pendingAuthorInfo != null && !_isAuthorPageMode && appState.crawler != null) {
          final info = appState.pendingAuthorInfo!;
          appState.pendingAuthorInfo = null;  // 立即清除，防止重复触发
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _enterAuthorPageMode(info['authorId']!, info['authorName']!);
            }
          });
        }
        
        if (!appState.isSiteSelected) {
          return _buildNoSiteSelected();
        }
        // ✅ 修复：站点切换时，检查当前选中类型是否在新站点类型列表中
        final typeNames = _getTypeNames(appState.crawler?.siteType ?? 'original');
        if (!typeNames.containsKey(_selectedType)) {
          // 当前选中类型不存在于新站点，自动切回第一个
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _selectedType = typeNames.keys.first;
                _videos.clear();
                _selectedIds.clear();
                _loadedPage = 0;
                _hasMore = true;
              });
              _pageController.text = '1';
              _goToPage();
            }
          });
        }
        // ─── 自动加载第一页 ───
        if (_videos.isEmpty && !_isLoading && appState.crawler != null) {
          Future.microtask(() => _goToPage());
        }
        return WillPopScope(
          onWillPop: () async {
            // 作者主页模式下拦截返回键
            if (_isAuthorPageMode) {
              _exitAuthorPageMode();
              return false;  // 不退出页面
            }
            return true;  // 正常返回
          },
          child: Scaffold(
            extendBodyBehindAppBar: true,
            body: Stack(
              children: [
                RefreshIndicator(
                  onRefresh: _onRefresh,
                  color: Colors.blue,
                  backgroundColor: Colors.white,
                  displacement: 40,
                  child: CustomScrollView(
                  controller: _scrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    // ══════════════════════════════════════
                    //  自定义 Header（替代原 SliverAppBar）
                    // ══════════════════════════════════════
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _BatchHeaderDelegate(
                        statusBarHeight: statusBarH,
                        expandedHeight: _kExpandedHeight,
                        collapsedHeight: _kCollapsedHeight,
                        collapseRatio: _collapseRatio,
                        selectedType: _selectedType,
                        typeNames: _getTypeNames(appState.crawler?.siteType ?? 'original'),
                        videoCount: _isAuthorPageMode ? _authorVideos.length : _videos.length,
                      selectedCount: _selectedIds.length,
                      totalCount: _isAuthorPageMode ? _authorVideos.length : _videos.length,
                      status: _status,
                      privacyMode: appState.privacyMode,
                      isAuthorPageMode: _isAuthorPageMode,
                      authorName: _currentAuthorName,
                      // 使用 isFollowedSync 同步方法快速判断关注状态
                      isFollowed: _isAuthorPageMode && appState.followedAuthorsService.isFollowedSync(_currentAuthorId),
                      onBack: _isAuthorPageMode ? _exitAuthorPageMode : null,
                      onFollowToggle: _isAuthorPageMode ? () async {
                        // 使用 isFollowedSync 判断当前状态
                        final currentlyFollowed = appState.followedAuthorsService.isFollowedSync(_currentAuthorId);
                        if (currentlyFollowed) {
                          await appState.followedAuthorsService.unfollow(_currentAuthorId);
                        } else {
                          await appState.followedAuthorsService.follow(_currentAuthorId, _currentAuthorName);
                        }
                        // 刷新 UI（notifyListeners 已在 follow/unfollow 中调用，这里确保 setState 触发重建）
                        if (mounted) setState(() {});
                      } : null,
                      onTypeChanged: (v) async {
                        if (v != null && v != _selectedType) {
                          setState(() {
                            _selectedType = v;
                            _videos.clear();
                            _selectedIds.clear();
                            _loadedPage = 0;
                          });
                          _pageController.text = '1';
                          await _goToPage();
                        }
                      },
                      onPrivacyToggle: () => appState.togglePrivacyMode(),
                      onSelectAll: () {
                        final currentVideos = _isAuthorPageMode ? _authorVideos : _videos;
                        final isAllSelected = _selectedIds.length == currentVideos.length;
                        setState(() {
                          if (isAllSelected) {
                            _selectedIds.clear();
                          } else {
                            _selectedIds = currentVideos.map((v) => v.id).toSet();
                          }
                        });
                      },
                    ),
                  ),

                  // 内容区域 - 视频列表
                  SliverPadding(
                    padding: EdgeInsets.all(8),
                    sliver: _buildSliverVideoGrid(appState),
                  ),

                  // 底部留白
                  SliverToBoxAdapter(
                    child: SizedBox(height: 100),
                  ),
                ],
                ),
              ),
              // 悬浮覆盖层
              ..._buildOverlays(appState),
            ],
          ),
        ),
        );  // WillPopScope
      },
    );
  }

  Widget _buildNoSiteSelected() {
    return Scaffold(
      appBar: AppBar(title: Text('批量爬取')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.language, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('请先选择站点', style: TextStyle(fontSize: 18, color: Colors.grey)),
            SizedBox(height: 8),
            Text('在设置页面选择要使用的站点', style: TextStyle(fontSize: 14, color: Colors.grey)),
            SizedBox(height: 24),
            Text('← 左滑到设置页面选择站点', style: TextStyle(fontSize: 14, color: Colors.blue)),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildOverlays(AppState appState) {
    return [
      // 页码跳转（作者主页模式隐藏）
      if (!_isAuthorPageMode) _buildBottomPageNavigation(),
      if (_showBackToTop && appState.showBackToTop)
        Positioned(
          bottom: (appState.backToTopPosition == 'right' && _selectedIds.isNotEmpty) ? 160.0 : 80.0,
          left: appState.backToTopPosition == 'left' ? 16 : null,
          right: appState.backToTopPosition == 'right' ? 16 : null,
          child: FloatingActionButton(
            mini: true,
            heroTag: 'batch_back_to_top',
            onPressed: _scrollToTop,
            child: Icon(Icons.arrow_upward),
          ),
        ),
      if (_selectedIds.isNotEmpty)
        Positioned(
          bottom: 80,
          right: 16,
          child: FloatingActionButton.extended(
            onPressed: _startDownload,
            icon: Icon(Icons.download),
            label: Text('下载 (${_selectedIds.length})'),
          ),
        ),
    ];
  }

  Widget _buildSliverVideoGrid(AppState appState) {
    final isListMode = appState.videoDisplayMode == 'list';
    // ✅ 修复：根据作者页面模式切换数据源
    final videos = _isAuthorPageMode ? _authorVideos : _videos;
    if (_isLoading && videos.isEmpty) {
      return SliverToBoxAdapter(child: Center(child: CircularProgressIndicator()));
    }
    if (videos.isEmpty) {
      return SliverToBoxAdapter(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.video_library_outlined, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text(_isAuthorPageMode ? '该作者暂无视频' : '输入页码并点击跳转', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }
    if (isListMode) {
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildVideoListItem(videos[index], appState),
          childCount: videos.length,
        ),
      );
    } else {
      return SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 0.85,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildVideoGridItem(videos[index], appState),
          childCount: videos.length,
        ),
      );
    }
  }

  /// 构建作者行（列表模式）- 不包含关注按钮，关注按钮在作者主页
  Widget _buildAuthorRowWithFollow(VideoInfo video, AppState appState) {
    final isFollowed = appState.followedAuthorsService.isFollowedSync(video.authorId ?? '');
    debugPrint('[BatchPage] 作者: ${video.author}, authorId: ${video.authorId}, 已关注: $isFollowed');
    return GestureDetector(
      onTap: () => _enterAuthorPageMode(video.authorId!, video.author!),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_outline, size: 14, color: Colors.blue),
          SizedBox(width: 2),
          Text(
            video.author!,
            style: TextStyle(fontSize: 12, color: Colors.blue),
          ),
          if (isFollowed) ...[
            SizedBox(width: 4),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.8),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text('已关注', style: TextStyle(fontSize: 9, color: Colors.white)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildVideoListItem(VideoInfo video, AppState appState) {
    final isSelected = _selectedIds.contains(video.id);
    final hasAuthor = video.author != null && video.author!.isNotEmpty &&
                      video.authorId != null && video.authorId!.isNotEmpty;
    
    return GestureDetector(
      onTap: () {
        setState(() {
          if (isSelected) {
            _selectedIds.remove(video.id);
          } else {
            _selectedIds.add(video.id);
          }
        });
      },
      child: Card(
        color: isSelected ? Colors.blue.withOpacity(0.2) : null,
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Row(
            children: [
              // 封面图
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 120,
                  height: 68,
                  color: Colors.grey[800],
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (video.cover != null)
                        Image.network(
                          video.cover!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Icon(Icons.video_library, color: Colors.grey),
                        ),
                      if (appState.privacyMode)
                        BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                          child: Container(color: Colors.transparent),
                        ),
                      if (isSelected)
                        Positioned(top: 4, left: 4, child: Icon(Icons.check_circle, color: Colors.blue, size: 20)),
                      // 时长标签
                      if (video.duration != null)
                        Positioned(
                          right: 4,
                          bottom: 4,
                          child: Container(
                            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
                            child: Text(video.duration!, style: TextStyle(color: Colors.white, fontSize: 10)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(width: 12),
              // 标题和作者
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(video.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14)),
                    SizedBox(height: 4),
                    // 作者（有 authorId 可点击跳转，否则只显示）
                    if (video.author != null && video.author!.isNotEmpty)
                      video.authorId != null && video.authorId!.isNotEmpty
                        ? _buildAuthorRowWithFollow(video, appState)
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.person_outline, size: 14, color: Colors.grey),
                              SizedBox(width: 2),
                              Text(
                                video.author!,
                                style: TextStyle(fontSize: 12, color: Colors.grey),
                              ),
                            ],
                          ),
                    // 上传时间
                    if (video.uploadDate != null && video.uploadDate!.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.access_time, size: 12, color: Colors.grey),
                            SizedBox(width: 2),
                            Text(
                              video.uploadDate!,
                              style: TextStyle(fontSize: 10, color: Colors.grey),
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

  Widget _buildVideoGridItem(VideoInfo video, AppState appState) {
    final isSelected = _selectedIds.contains(video.id);
    final hasAuthor = video.author != null && video.author!.isNotEmpty &&
                      video.authorId != null && video.authorId!.isNotEmpty;
    final isFollowed = hasAuthor && appState.followedAuthorsService.isFollowedSync(video.authorId!);
    
    return GestureDetector(
      onTap: () {
        setState(() {
          if (isSelected) {
            _selectedIds.remove(video.id);
          } else {
            _selectedIds.add(video.id);
          }
        });
      },
      child: Card(
        color: isSelected ? Colors.blue.withOpacity(0.2) : null,
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面图区域
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(color: Colors.grey[800]),
                  if (video.cover != null)
                    ClipRRect(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.network(
                            video.cover!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Center(child: Icon(Icons.video_library, color: Colors.grey)),
                          ),
                          if (appState.privacyMode)
                            Positioned.fill(
                              child: BackdropFilter(
                                filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                                child: Container(color: Colors.transparent),
                              ),
                            ),
                        ],
                      ),
                    ),
                  // 时长标签（右下角）
                  if (video.duration != null)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
                        child: Text(video.duration!, style: TextStyle(color: Colors.white, fontSize: 10)),
                      ),
                    ),
                  // 作者标签（左下角）
                  if (video.author != null && video.author!.isNotEmpty)
                    Positioned(
                      left: 4,
                      bottom: 4,
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6), 
                          borderRadius: BorderRadius.circular(4)
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.person, size: 10, color: Colors.white70),
                            SizedBox(width: 2),
                            Text(
                              video.author!.length > 8 ? video.author!.substring(0, 8) + '...' : video.author!,
                              style: TextStyle(color: Colors.white, fontSize: 9),
                            ),
                            if (isFollowed) ...[
                              SizedBox(width: 3),
                              Text('❤️', style: TextStyle(fontSize: 8)),
                            ],
                          ],
                        ),
                      ),
                    ),
                  // 选中标记
                  if (isSelected)
                    Positioned(top: 4, right: 4, child: Icon(Icons.check_circle, color: Colors.blue)),
                ],
              ),
            ),
            // 标题区域
            Padding(
              padding: EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: Text(video.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12)),
            ),
            // 作者（底部，有 authorId 可点击）
            if (video.author != null && video.author!.isNotEmpty)
              video.authorId != null && video.authorId!.isNotEmpty
                ? _buildGridAuthorRow(video, appState)
                : Padding(
                    padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.person_outline, size: 12, color: Colors.grey),
                        SizedBox(width: 2),
                        Text(video.author!, style: TextStyle(fontSize: 10, color: Colors.grey)),
                      ],
                    ),
                  ),
          ],
        ),
      ),
    );
  }

  /// 构建网格模式下的作者行（不包含关注按钮）
  Widget _buildGridAuthorRow(VideoInfo video, AppState appState) {
    final isFollowed = appState.followedAuthorsService.isFollowedSync(video.authorId ?? '');
    return GestureDetector(
      onTap: () => _enterAuthorPageMode(video.authorId!, video.author!),
      child: Padding(
        padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.person_outline, size: 12, color: Colors.blue),
            SizedBox(width: 2),
            Text(
              video.author!.length > 8 ? video.author!.substring(0, 8) + '..' : video.author!,
              style: TextStyle(fontSize: 10, color: Colors.blue),
            ),
            if (isFollowed) ...[
              SizedBox(width: 4),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text('已关注', style: TextStyle(fontSize: 8, color: Colors.white)),
              ),
            ],
            Icon(Icons.chevron_right, size: 12, color: Colors.blue),
          ],
        ),
      ),
    );
  }

  Map<String, String> _getTypeNames(String siteType) {
    return siteType == 'porn91' ? _typeNamesPorn91 : _typeNamesOriginal;
  }

  Widget _buildBottomPageNavigation() {
    final appState = Provider.of<AppState>(context, listen: false);
    final isDark = appState.isDarkMode;
    return Positioned(
      bottom: 16,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isDark ? Colors.grey[850] : Colors.white.withOpacity(0.95),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 8, offset: Offset(0, 2))],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '第$_loadedPage页',
                style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Colors.grey[800], fontWeight: FontWeight.w500),
              ),
              SizedBox(width: 12),
              GestureDetector(
                onTap: (_isLoading || _isLoadingMore || _loadedPage <= 1) ? null : () => _goToPageDirect(_loadedPage - 1),
                child: Container(
                  padding: EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: (_loadedPage <= 1) ? (isDark ? Colors.grey[700] : Colors.grey[300]) : (isDark ? Colors.blue[900] : Colors.blue[100]),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.arrow_left, size: 18, color: (_loadedPage <= 1) ? Colors.grey[500] : (isDark ? Colors.blue[300] : Colors.blue[700])),
                ),
              ),
              SizedBox(width: 8),
              Container(
                width: 60,
                height: 28,
                decoration: BoxDecoration(
                  color: isDark ? Colors.grey[800] : Colors.grey[100],
                  border: Border.all(color: isDark ? Colors.grey[700]! : Colors.grey[400]!),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: TextField(
                  controller: _pageController,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Colors.black87),
                  decoration: InputDecoration(
                    hintText: '回车',
                    hintStyle: TextStyle(fontSize: 10, color: isDark ? Colors.grey[500] : Colors.grey[600]),
                    contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onSubmitted: (_) => _goToPage(),
                  textInputAction: TextInputAction.go,
                ),
              ),
              SizedBox(width: 8),
              GestureDetector(
                onTap: (_isLoading || _isLoadingMore) ? null : () => _goToPageDirect(_loadedPage + 1),
                child: Container(
                  padding: EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.blue[900] : Colors.blue[100],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.arrow_right, size: 18, color: isDark ? Colors.blue[300] : Colors.blue[700]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _goToPageDirect(int targetPage) async {
    if (targetPage < 1) return;
    _pageController.text = targetPage.toString();
    await _goToPage();
  }

  Future<void> _goToPage() async {
    final targetPage = int.tryParse(_pageController.text) ?? 1;
    if (targetPage < 1) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('请输入有效的页码')));
      return;
    }
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) {
      setState(() => _status = '请先选择站点');
      return;
    }

    setState(() {
      _status = '加载中...';
      _isLoading = true;
      _videos.clear();
      _selectedIds.clear();
      _hasMore = true;
    });

    final videos = await crawler.getVideoList(_selectedType, targetPage);
    setState(() {
      _videos = videos;
      _totalVideos = videos.length;
      _loadedPage = targetPage;
      _currentPage = targetPage;
      _isLoading = false;
      _status = videos.isEmpty ? '无结果' : '就绪';
      _hasMore = videos.length >= 24;
    });
    _scrollToTop();
  }

  Future<void> _startDownload() async {
    final appState = context.read<AppState>();
    // ✅ 修复：根据作者页面模式使用正确的视频列表
    final currentVideos = _isAuthorPageMode ? _authorVideos : _videos;
    final selectedVideos = currentVideos.where((v) => _selectedIds.contains(v.id)).toList();
    if (selectedVideos.isEmpty) return;
    
    // 检测哪些视频已经下载过
    final alreadyDownloaded = <VideoInfo>[];
    final newVideos = <VideoInfo>[];
    final inQueue = <VideoInfo>[];
    
    for (final video in selectedVideos) {
      if (appState.downloadManager.isVideoInQueue(video.id)) {
        inQueue.add(video);
      } else if (await appState.downloadManager.isVideoDownloaded(video.id)) {
        alreadyDownloaded.add(video);
      } else {
        newVideos.add(video);
      }
    }
    
    // 队列中已存在的视频（正在下载/等待/暂停），直接跳过并提示
    if (inQueue.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${inQueue.length} 个视频已在下载队列中，已跳过')),
        );
      }
    }
    
    // 如果有已下载的视频，弹窗询问是否覆盖
    bool overwriteConfirmed = false;
    if (alreadyDownloaded.isNotEmpty) {
      if (newVideos.isEmpty && alreadyDownloaded.isNotEmpty) {
        // 全部已下载，询问是否全部覆盖
        overwriteConfirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('视频已下载'),
            content: Text('选中的 ${alreadyDownloaded.length} 个视频已经下载过了，是否覆盖重新下载？'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('覆盖下载')),
            ],
          ),
        ) ?? false;
        if (!overwriteConfirmed) {
          setState(() => _selectedIds.clear());
          return;
        }
      } else {
        // 部分已下载，询问是否覆盖已下载的部分
        final result = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('检测到已下载视频'),
            content: Text(
              '选中的 ${selectedVideos.length} 个视频中：\n'
              '• ${newVideos.length} 个新视频\n'
              '• ${alreadyDownloaded.length} 个已下载\n'
              '• ${inQueue.length} 个在队列中\n\n'
              '是否覆盖已下载的 ${alreadyDownloaded.length} 个视频？',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('取消')),
              TextButton(onPressed: () => Navigator.pop(ctx, 'new_only'), child: const Text('只下载新的')),
              TextButton(onPressed: () => Navigator.pop(ctx, 'all'), child: const Text('全部下载')),
            ],
          ),
        );
        
        if (result == null || result == 'cancel') {
          setState(() => _selectedIds.clear());
          return;
        }
        if (result == 'all') {
          overwriteConfirmed = true;
        }
        // result == 'new_only' 时 overwriteConfirmed 保持 false
      }
    }
    
    // 添加新视频到下载队列
    final toDownload = <VideoInfo>[...newVideos];
    if (overwriteConfirmed) {
      toDownload.addAll(alreadyDownloaded);
    }
    
    if (toDownload.isNotEmpty) {
      final result = await appState.downloadManager.addTasks(toDownload, forceRestart: overwriteConfirmed);
      if (mounted) {
        final msg = '已添加 ${result['new']} 个视频到下载队列'
            '${result['duplicate']! > 0 ? '，${result['duplicate']} 个已跳过' : ''}';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            action: SnackBarAction(label: '查看', onPressed: () => appState.navigateToPage?.call(3)),
          ),
        );
      }
    }
    
    setState(() => _selectedIds.clear());
  }
}

// ════════════════════════════════════════════════════════════
//  核心：自定义 SliverPersistentHeaderDelegate
//  替换原有 SliverAppBar + flexibleSpace 实现滚动折叠动画
// ════════════════════════════════════════════════════════════
class _BatchHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double statusBarHeight;
  final double expandedHeight;
  final double collapsedHeight;
  final double collapseRatio;
  final String selectedType;
  final Map<String, String> typeNames;
  final int videoCount;
  final int selectedCount;
  final int totalCount;
  final String status;
  final bool privacyMode;
  final bool isAuthorPageMode;
  final String authorName;
  final bool isFollowed;
  final VoidCallback? onBack;
  final VoidCallback? onFollowToggle;
  final ValueChanged<String?> onTypeChanged;
  final VoidCallback onPrivacyToggle;
  final VoidCallback onSelectAll;

  const _BatchHeaderDelegate({
    required this.statusBarHeight,
    required this.expandedHeight,
    required this.collapsedHeight,
    required this.collapseRatio,
    required this.selectedType,
    required this.typeNames,
    required this.videoCount,
    required this.selectedCount,
    required this.totalCount,
    required this.status,
    required this.privacyMode,
    this.isAuthorPageMode = false,
    this.authorName = '',
    this.isFollowed = false,
    this.onBack,
    this.onFollowToggle,
    required this.onTypeChanged,
    required this.onPrivacyToggle,
    required this.onSelectAll,
  });

  @override
  double get minExtent => statusBarHeight + collapsedHeight;
  @override
  double get maxExtent => statusBarHeight + expandedHeight;

  @override
  Widget build(BuildContext ctx, double shrinkOffset, bool overlapsContent) {
    final isDark = Theme.of(ctx).brightness == Brightness.dark;
    // 作者模式下显示作者名称
    final displayTitle = isAuthorPageMode ? '作者: $authorName' : '批量爬取';
    // 主题适配颜色
    final bgColor = isDark ? Colors.black.withOpacity(0.75) : Colors.white.withOpacity(0.9);
    final textColor = isDark ? Colors.white : Colors.black87;
    final subTextColor = isDark ? Colors.grey : Colors.black54;
    
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          color: bgColor,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: statusBarHeight),
              
              // ── 第一行：标题/下拉选择器 + 右侧按钮 ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // 作者模式显示返回按钮
                    if (isAuthorPageMode && onBack != null)
                      GestureDetector(
                        onTap: onBack,
                        child: Container(
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.blue.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(Icons.arrow_back, size: 20, color: Colors.blue),
                        ),
                      ),
                    // 左侧：展开时显示标题+关注按钮（作者模式），收起时根据模式显示
                    collapseRatio < 0.5
                        ? Expanded(
                            child: isAuthorPageMode
                                ? Row(
                                    children: [
                                      Text(
                                        displayTitle,
                                        style: TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w600,
                                          color: textColor,
                                        ),
                                      ),
                                      SizedBox(width: 8),
                                      // 展开状态下也显示关注按钮
                                      if (onFollowToggle != null)
                                        GestureDetector(
                                          onTap: onFollowToggle,
                                          child: Container(
                                            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                            decoration: BoxDecoration(
                                              color: isFollowed ? Colors.red.withOpacity(0.2) : Colors.blue.withOpacity(0.2),
                                              borderRadius: BorderRadius.circular(16),
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
                                                  size: 16,
                                                  color: isFollowed ? Colors.red : Colors.blue,
                                                ),
                                                SizedBox(width: 4),
                                                Text(
                                                  isFollowed ? '已关注' : '关注',
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    color: isFollowed ? Colors.red : Colors.blue,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                    ],
                                  )
                                : Text(
                                    displayTitle,
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w600,
                                      color: textColor,
                                    ),
                                  ),
                          )
                        // 收起时：作者模式显示作者名+关注按钮，非作者模式显示下拉选择器
                        : isAuthorPageMode
                            ? Expanded(
                                child: Row(
                                  children: [
                                    Text(
                                      displayTitle,
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: textColor,
                                      ),
                                    ),
                                    SizedBox(width: 8),
                                    // 收起状态下的关注按钮
                                    if (onFollowToggle != null)
                                      GestureDetector(
                                        onTap: onFollowToggle,
                                        child: Container(
                                          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: isFollowed ? Colors.red.withOpacity(0.2) : Colors.blue.withOpacity(0.2),
                                            borderRadius: BorderRadius.circular(12),
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
                                                size: 14,
                                                color: isFollowed ? Colors.red : Colors.blue,
                                              ),
                                              SizedBox(width: 4),
                                              Text(
                                                isFollowed ? '已关注' : '关注',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: isFollowed ? Colors.red : Colors.blue,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              )
                            : _buildTypeChip(ctx, isDark),
                    // 收起时加 Spacer 让右侧按钮靠右
                    if (collapseRatio >= 0.5) const Spacer(),
                    // 右侧按钮
                    _buildRightButtons(),
                  ],
                ),
              ),
              
              // ── 第二行：副标题（展开时显示）──
              if (collapseRatio < 0.5)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Text(
                    isAuthorPageMode 
                        ? '已加载 $videoCount 个视频 (作者主页)' 
                        : '已加载 $videoCount 个视频',
                    style: TextStyle(fontSize: 12, color: subTextColor),
                  ),
                ),
              
              // ── 第三行：下拉选择器（展开时显示，非作者模式下显示）──
              if (collapseRatio < 0.5 && !isAuthorPageMode)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: _buildTypeChip(ctx, isDark),
                ),
            ],
          ),
        ),
      ),
    );
  }
  
  // 右侧按钮组
  Widget _buildRightButtons() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 已选数量
        if (selectedCount > 0)
          Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '已选 $selectedCount 个',
              style: const TextStyle(color: Colors.blue, fontSize: 11),
            ),
          ),
        
        // 全选按钮
        if (selectedCount > 0)
          GestureDetector(
            onTap: onSelectAll,
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: selectedCount == totalCount
                    ? Colors.blue
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: selectedCount == totalCount
                    ? null
                    : Border.all(color: Colors.blue, width: 2),
              ),
              child: Icon(
                Icons.check,
                color: selectedCount == totalCount
                    ? Colors.white
                    : Colors.blue,
                size: 18,
              ),
            ),
          ),
        
        // 就绪标签
        Container(
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: status == '就绪'
                ? Colors.green.withOpacity(0.2)
                : Colors.orange.withOpacity(0.2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            status,
            style: TextStyle(
              color: status == '就绪' ? Colors.green : Colors.orange,
              fontSize: 11,
            ),
          ),
        ),
        
        // 隐私按钮
        IconButton(
          icon: Icon(
            privacyMode ? Icons.visibility_off : Icons.visibility,
            color: privacyMode ? Colors.red : Colors.grey,
            size: 20,
          ),
          onPressed: onPrivacyToggle,
          tooltip: privacyMode ? '取消模糊' : '模糊预览图',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      ],
    );
  }
  
  // 列表选择器组件
  Widget _buildTypeChip(BuildContext ctx, bool isDark) {
    final dropdownBg = isDark ? const Color(0xFF252525) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF252525) : Colors.white.withOpacity(0.95),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF333333) : Colors.grey[300]!,
          width: 0.5,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF4a9eff).withOpacity(0.1),
            blurRadius: 8,
            spreadRadius: 1,
          ),
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.list_alt, size: 16, color: const Color(0xFF4a9eff)),
          const SizedBox(width: 6),
          Theme(
            data: Theme.of(ctx).copyWith(canvasColor: dropdownBg),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: selectedType,
                isDense: true,
                icon: Icon(Icons.keyboard_arrow_down, size: 16, color: Colors.grey[600]),
                style: TextStyle(fontSize: 12, color: textColor),
                items: typeNames.entries.map((e) => DropdownMenuItem(
                  value: e.key,
                  child: Text(e.value, style: TextStyle(fontSize: 12, color: isDark ? Colors.grey[300] : Colors.black87)),
                )).toList(),
                onChanged: onTypeChanged,
                underline: const SizedBox(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool shouldRebuild(_BatchHeaderDelegate old) =>
      old.collapseRatio != collapseRatio ||
      old.selectedType != selectedType ||
      old.videoCount != videoCount ||
      old.selectedCount != selectedCount ||
      old.totalCount != totalCount ||
      old.status != status ||
      old.privacyMode != privacyMode ||
      old.isAuthorPageMode != isAuthorPageMode ||
      old.authorName != authorName ||
      old.isFollowed != isFollowed;
}
