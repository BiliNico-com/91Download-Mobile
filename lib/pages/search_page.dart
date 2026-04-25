import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../services/followed_authors_service.dart';
import '../models/video_info.dart';
import '../utils/logger.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> with AutomaticKeepAliveClientMixin {
  final _keywordController = TextEditingController();
  final _pageController = TextEditingController();
  List<VideoInfo> _results = [];
  List<AuthorInfo> _authorResults = [];  // 作者搜索结果
  Set<String> _selectedIds = {};
  bool _isLoading = false;
  bool _isLoadingMore = false;  // 是否正在加载更多
  bool _isAuthorMode = false;
  
  // 分页相关
  int _currentPage = 1;
  int _loadedPage = 0;  // 已加载的页码（用于瀑布流加载）
  bool _hasMore = true;
  String _lastKeyword = '';
  String _sortBy = 'default';  // default, new, hot
  
  // 作者主页模式相关
  bool _isAuthorPageMode = false;  // 是否在作者主页模式
  String _currentAuthorId = '';    // 当前作者ID
  String _currentAuthorName = '';  // 当前作者名称
  List<VideoInfo> _authorVideos = [];  // 作者视频列表
  int _authorCurrentPage = 0;
  bool _authorHasMore = true;
  
  // 滚动控制
  final ScrollController _scrollController = ScrollController();
  bool _showBackToTop = false;
  String _status = '就绪';  // 就绪状态
  
  // 进入作者主页前的滚动位置（返回时恢复）
  double _savedScrollOffset = 0;
  
  @override
  bool get wantKeepAlive => true;  // 保持页面状态
  
  // 更新返回键回调
  void _updateWillPopCallback() {
    final appState = context.read<AppState>();
    if (_isAuthorPageMode || _isAuthorMode) {
      appState.onWillPopCallback = () {
        if (_isAuthorPageMode) {
          _exitAuthorPageMode();
          return true;
        }
        if (_isAuthorMode) {
          setState(() {
            _isAuthorMode = false;
            _authorResults.clear();
            _selectedIds.clear();
          });
          appState.onWillPopCallback = null;
          return true;
        }
        return false;
      };
    } else {
      appState.onWillPopCallback = null;
    }
  }
  
  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _pageController.text = '1';
  }
  
  @override
  void dispose() {
    // 清除返回键回调
    try {
      context.read<AppState>().onWillPopCallback = null;
    } catch (_) {}
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _keywordController.dispose();
    _pageController.dispose();
    super.dispose();
  }
  
  void _onScroll() {
    // 显示/隐藏回顶部按钮
    final showBtn = _scrollController.offset > 500;
    if (showBtn != _showBackToTop) {
      setState(() => _showBackToTop = showBtn);
    }
    
    // 自动加载更多
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      if (!_isLoading && !_isLoadingMore) {
        // 作者主页模式
        if (_isAuthorPageMode && _authorHasMore) {
          _loadMoreAuthorVideos();
        // 视频搜索模式（非作者搜索模式）
        } else if (!_isAuthorPageMode && !_isAuthorMode && _hasMore && _results.isNotEmpty) {
          _loadMore();
        }
      }
    }
  }
  
  void _scrollToTop() {
    _scrollController.animateTo(0, duration: Duration(milliseconds: 300), curve: Curves.easeOut);
  }
  
  /// 下拉刷新
  Future<void> _onRefresh() async {
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;

    // 作者主页模式
    if (_isAuthorPageMode) {
      setState(() {
        _authorVideos.clear();
        _selectedIds.clear();
        _authorCurrentPage = 0;
        _authorHasMore = true;
      });
      await _loadMoreAuthorVideos();
      return;
    }

    // 作者搜索模式 — 重新搜索
    if (_isAuthorMode) {
      setState(() {
        _authorResults.clear();
        _isLoading = false;
      });
      final authors = await crawler.searchAuthors(_keywordController.text);
      if (mounted) {
        setState(() {
          _authorResults = authors;
          _status = authors.isEmpty ? '无结果' : '就绪';
        });
      }
      return;
    }
    
    // 视频搜索模式
    if (_lastKeyword.isEmpty) return;
    
    final results = await crawler.searchVideos(_lastKeyword, page: 1, sort: _sortBy);
    if (mounted) {
      setState(() {
        _results = results;
        _loadedPage = 1;
        _hasMore = results.isNotEmpty;
      });
    }
  }
  
  Future<void> _loadMore() async {
    if (!_hasMore || _isLoading || _isLoadingMore || _lastKeyword.isEmpty) return;
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;

    setState(() => _isLoadingMore = true);
    final nextPage = _loadedPage + 1;
    
    final newResults = await crawler.searchVideos(_lastKeyword, page: nextPage, sort: _sortBy);
    
    if (newResults.isEmpty) {
      setState(() {
        _hasMore = false;
        _isLoadingMore = false;
      });
    } else {
      setState(() {
        _results.addAll(newResults);
        _loadedPage = nextPage;
        _currentPage = nextPage;
        // 如果返回结果少于每页数量，说明没有更多了
        if (newResults.length < 20) {
          _hasMore = false;
        }
        _isLoadingMore = false;
      });
    }
  }

  /// 加载更多作者视频
  Future<void> _loadMoreAuthorVideos() async {
    if (!_authorHasMore || _isLoading || _isLoadingMore || _currentAuthorId.isEmpty) return;
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;
    
    setState(() => _isLoadingMore = true);
    _authorCurrentPage++;
    
    final newVideos = await crawler.getAuthorVideos(_currentAuthorId, page: _authorCurrentPage);
    
    if (newVideos.isEmpty) {
      _authorHasMore = false;
    } else {
      setState(() {
        _authorVideos.addAll(newVideos);
        // 如果返回结果少于每页数量，说明没有更多了
        if (newVideos.length < 20) {
          _authorHasMore = false;
        }
      });
    }
    
    setState(() => _isLoadingMore = false);
  }

  /// 退出作者主页模式
  void _exitAuthorPageMode() {
    if (_isAuthorPageMode) {
      final savedOffset = _savedScrollOffset;
      setState(() {
        _isAuthorPageMode = false;
        _authorVideos.clear();
        _authorCurrentPage = 0;
        _authorHasMore = true;
        _selectedIds.clear();
      });
      // 更新返回键回调
      _updateWillPopCallback();
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
  }

  /// 进入作者主页模式
  Future<void> _enterAuthorPageMode(AuthorInfo author) async {
    // 保存当前滚动位置
    _savedScrollOffset = _scrollController.offset;
    setState(() {
      _isAuthorPageMode = true;
      _currentAuthorId = author.id;
      _currentAuthorName = author.name;
      _authorVideos.clear();
      _authorCurrentPage = 0;
      _authorHasMore = true;
      _selectedIds.clear();
    });
    // 更新返回键回调
    _updateWillPopCallback();
    // 滚动到顶部加载作者视频
    _scrollController.jumpTo(0);
    await _loadMoreAuthorVideos();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);  // 必须调用
    
    return Consumer<AppState>(
      builder: (context, appState, _) {
        return Scaffold(
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
                    // SliverAppBar：标题区域（滚动时隐藏）+ 搜索区域（始终可见）
                    SliverAppBar(
                      pinned: true,
                      floating: true,
                      snap: false,
                      expandedHeight: 112 + MediaQuery.of(context).padding.top, // 状态栏 + 标题区(56) + 搜索区(56)
                      backgroundColor: Colors.transparent,
                      elevation: 0,
                      scrolledUnderElevation: 0,
                      flexibleSpace: LayoutBuilder(
                        builder: (context, constraints) {
                          final statusBarHeight = MediaQuery.of(context).padding.top;
                          final expandRatio = ((constraints.maxHeight - 56 - statusBarHeight) / 56).clamp(0.0, 1.0);
                          final isExpanded = expandRatio > 0.5;
                      
                      return ClipRect(
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                          child: Container(
                            color: isExpanded
                              ? (Theme.of(context).brightness == Brightness.dark 
                                  ? Colors.black.withOpacity(0.5) 
                                  : Colors.white.withOpacity(0.85))
                              : (Theme.of(context).brightness == Brightness.dark 
                                  ? Colors.black.withOpacity(0.75) 
                                  : Colors.white.withOpacity(0.95)),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 状态栏占位
                                SizedBox(height: statusBarHeight),
                                // 标题区域（滚动时隐藏）
                                AnimatedOpacity(
                                  opacity: isExpanded ? 1.0 : 0.0,
                                  duration: Duration(milliseconds: 150),
                                  child: Container(
                                    height: 56,
                                    padding: EdgeInsets.only(left: 16, right: 8),
                                    child: Row(
                                      children: [
                                        Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            _isAuthorPageMode
                                              ? Row(
                                                  children: [
                                                    Text('作者: $_currentAuthorName', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black87)),
                                                    SizedBox(width: 12),
                                                    // 关注按钮
                                                    _buildFollowButton(appState),
                                                  ],
                                                )
                                              : Text('搜索', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black87)),
                                            Text(
                                              _isAuthorPageMode 
                                                ? '点击作者主页查看视频' 
                                                : '通过关键词搜索并下载视频',
                                              style: TextStyle(fontSize: 12, color: Theme.of(context).brightness == Brightness.dark ? Colors.grey : Colors.black54)),
                                          ],
                                        ),
                                        Spacer(),
                                        ..._buildAppBarActions(appState),
                                      ],
                                    ),
                                  ),
                                ),
                                // 搜索区域（始终可见，吸附到顶部）
                                Container(
                                  height: 56,
                                  color: Theme.of(context).scaffoldBackgroundColor.withOpacity(0.95),
                                  child: _buildSearchBar(appState),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                // 视频/作者搜索结果
                SliverPadding(
                  padding: EdgeInsets.all(8),
                  sliver: _isAuthorMode && !_isAuthorPageMode
                    ? _buildAuthorResultsSliver()
                    : _buildVideoResultsSliver(appState),
                ),
                // 底部留白给翻页控件和浮动按钮
                SliverToBoxAdapter(
                  child: SizedBox(height: 100),
                ),
              ],
              ),
              ),
            // 覆盖层：翻页控件 + 浮动按钮
            ..._buildOverlays(appState),
          ],
        ),
      );
    },
  );
}
  
  /// 覆盖层：翻页控件 + 浮动按钮
  List<Widget> _buildOverlays(AppState appState) {
    return [
      // 页码跳转悬浮胶囊（仅视频搜索模式显示，作者主页模式隐藏）
      if (!_isAuthorMode && !_isAuthorPageMode) _buildBottomPageNavigation(appState),
      // 回顶部按钮
      if (_showBackToTop && appState.showBackToTop)
        Positioned(
          bottom: (_selectedIds.isNotEmpty) ? 160.0 : 80.0,
          left: appState.backToTopPosition == 'left' ? 16 : null,
          right: appState.backToTopPosition == 'right' ? 16 : null,
          child: FloatingActionButton(
            mini: true,
            heroTag: 'search_back_to_top',
            onPressed: _scrollToTop,
            child: Icon(Icons.arrow_upward),
          ),
        ),
      // 下载按钮
      if (_selectedIds.isNotEmpty)
        Positioned(
          bottom: 80,
          right: 16,
          child: FloatingActionButton.extended(
            onPressed: _download,
            icon: Icon(Icons.download),
            label: Text('下载 (${_selectedIds.length})'),
          ),
        ),
    ];
  }

  /// 构建关注按钮
  Widget _buildFollowButton(AppState appState) {
    final isFollowed = appState.followedAuthorsService.followedList
        .any((a) => a.authorId == _currentAuthorId);
    
    return GestureDetector(
      onTap: () async {
        if (isFollowed) {
          await appState.followedAuthorsService.unfollow(_currentAuthorId);
        } else {
          await appState.followedAuthorsService.follow(_currentAuthorId, _currentAuthorName);
        }
        if (mounted) setState(() {});
      },
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
    );
  }

  /// AppBar右侧操作按钮
  List<Widget> _buildAppBarActions(AppState appState) {
    return [
      // 已选数量
      if (_selectedIds.isNotEmpty)
        Container(
          margin: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.blue.withOpacity(0.2),
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Text(
            '已选 ${_selectedIds.length} 个',
            style: TextStyle(color: Colors.blue, fontSize: 12),
          ),
        ),
      // 全选勾选框
      if (_selectedIds.isNotEmpty)
        GestureDetector(
          onTap: _toggleAll,
          child: Container(
            margin: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            padding: EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: _selectedIds.length == (_isAuthorPageMode ? _authorVideos.length : _results.length) 
                  ? Colors.blue 
                  : Theme.of(context).scaffoldBackgroundColor.withOpacity(0.85),
              borderRadius: BorderRadius.circular(8),
              border: _selectedIds.length == (_isAuthorPageMode ? _authorVideos.length : _results.length) 
                  ? null 
                  : Border.all(color: Colors.blue, width: 2),
            ),
            child: Icon(
              Icons.check,
              color: _selectedIds.length == (_isAuthorPageMode ? _authorVideos.length : _results.length) 
                  ? Colors.white 
                  : Colors.blue,
              size: 20,
            ),
          ),
        ),
      // 就绪按钮
      Container(
        margin: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: _status == '就绪' ? Colors.green.withOpacity(0.2) : Colors.orange.withOpacity(0.2),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          _status,
          style: TextStyle(
            color: _status == '就绪' ? Colors.green : Colors.orange,
            fontSize: 12,
          ),
        ),
      ),
      SizedBox(width: 4),
      // 隐私按钮
      IconButton(
        icon: Icon(
          appState.privacyMode ? Icons.visibility_off : Icons.visibility,
          color: appState.privacyMode ? Colors.red : Colors.grey,
        ),
        onPressed: () {
          appState.togglePrivacyMode();
        },
        tooltip: appState.privacyMode ? '取消模糊' : '模糊预览图',
      ),
    ];
  }

  /// 搜索栏（吸顶内容）- 深色模式优化风格
  Widget _buildSearchBar(AppState appState) {
    final siteType = appState.crawler?.siteType ?? 'original';
    final showSort = !_isAuthorMode && siteType != 'porn91';
    final isDark = appState.isDarkMode;
    
    // 作者主页模式下，隐藏下拉菜单，只显示返回按钮和搜索框
    if (_isAuthorPageMode) {
      return Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: isDark ? Colors.white.withOpacity(0.08) : Colors.grey.shade300,
              width: 0.5,
            ),
            boxShadow: isDark
                ? [BoxShadow(color: Colors.white.withOpacity(0.03), blurRadius: 1, spreadRadius: 0.5)]
                : [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8, offset: const Offset(0, 2))],
          ),
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: Text(
                    '$_currentAuthorName 的视频',
                    style: TextStyle(
                      color: isDark ? Colors.white.withOpacity(0.9) : Colors.black87,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
              // 蓝色搜索按钮（刷新）
              GestureDetector(
                onTap: _onRefresh,
                child: Container(
                  width: 36,
                  height: 36,
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF2E7AE6) : const Color(0xFF3A7BF7),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.refresh, color: Colors.white, size: 20),
                ),
              ),
            ],
          ),
        ),
      );
    }
    
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          // 深色模式用更暗的背景，几乎和页面融为一体
          color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
          borderRadius: BorderRadius.circular(22),
          // 弱化边框，深色模式下几乎不可见
          border: Border.all(
            color: isDark ? Colors.white.withOpacity(0.08) : Colors.grey.shade300,
            width: 0.5,
          ),
          // 深色模式去掉阴影，或只用极淡的内发光
          boxShadow: isDark
              ? [
                  BoxShadow(
                    color: Colors.white.withOpacity(0.03),
                    blurRadius: 1,
                    spreadRadius: 0.5,
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: Row(
          children: [
            // 输入框
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 14),
                child: TextField(
                  controller: _keywordController,
                  style: TextStyle(
                    color: isDark ? Colors.white.withOpacity(0.9) : Colors.black87,
                    fontSize: 14,
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: '输入关键词...',
                    hintStyle: TextStyle(
                      color: isDark ? Colors.white.withOpacity(0.3) : Colors.grey.shade500,
                      fontSize: 14,
                    ),
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  onSubmitted: (_) => _search(),
                  textInputAction: TextInputAction.search,
                ),
              ),
            ),
            // 分隔线 — 深色模式下更淡
            Container(
              width: 1,
              height: 18,
              color: isDark ? Colors.white.withOpacity(0.06) : Colors.grey.shade300,
            ),
            // 搜索类型下拉
            _buildSearchDropdown(
              value: _isAuthorMode,
              items: [DropdownMenuItem(value: false, child: Text('搜视频')), DropdownMenuItem(value: true, child: Text('搜作者'))],
              onChanged: (v) {
                setState(() => _isAuthorMode = v!);
                _updateWillPopCallback();
              },
              isDark: isDark,
            ),
            // 排序下拉（仅视频搜索模式 + original CMS）
            if (showSort) ...[
              Container(
                width: 1,
                height: 18,
                color: isDark ? Colors.white.withOpacity(0.06) : Colors.grey.shade300,
              ),
              _buildSearchDropdown(
                value: _sortBy,
                items: [
                  DropdownMenuItem(value: 'default', child: Text('默认')),
                  DropdownMenuItem(value: 'new', child: Text('最新')),
                  DropdownMenuItem(value: 'hot', child: Text('最热')),
                ],
                onChanged: (v) {
                  if (v != null && v != _sortBy) {
                    setState(() => _sortBy = v);
                    if (_lastKeyword.isNotEmpty) _search();
                  }
                },
                isDark: isDark,
              ),
            ],
            const SizedBox(width: 4),
            // 蓝色搜索按钮 — 深色模式下稍微暗一点
            GestureDetector(
              onTap: _search,
              child: Container(
                width: 36,
                height: 36,
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF2E7AE6) : const Color(0xFF3A7BF7),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.search, color: Colors.white, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 搜索栏下拉菜单
  Widget _buildSearchDropdown<T>({
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
    required bool isDark,
  }) {
    return Theme(
      data: Theme.of(context).copyWith(
        canvasColor: isDark ? const Color(0xFF2C2C2E) : Colors.white,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          icon: Icon(
            Icons.keyboard_arrow_down,
            size: 16,
            color: isDark ? Colors.white.withOpacity(0.5) : Colors.grey.shade600,
          ),
          style: TextStyle(
            color: isDark ? Colors.white.withOpacity(0.85) : Colors.black87,
            fontSize: 12,
          ),
          items: items.map((e) => DropdownMenuItem(
            value: e.value,
            child: Text(
              (e.child as Text).data ?? '',
              style: TextStyle(
                color: isDark ? Colors.white.withOpacity(0.85) : Colors.black87,
                fontSize: 12,
              ),
            ),
          )).toList(),
          onChanged: onChanged,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      ),
    );
  }

  /// 底部页码跳转区域（悬浮胶囊）
  Widget _buildBottomPageNavigation(AppState appState) {
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
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 当前页显示
              Text(
                '第$_currentPage页',
                style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Colors.grey[800], fontWeight: FontWeight.w500),
              ),
              SizedBox(width: 12),
              // 上一页按钮
              GestureDetector(
                onTap: (_isLoading || _isLoadingMore || _currentPage <= 1) 
                  ? null 
                  : () => _goToPage(_currentPage - 1),
                child: Container(
                  padding: EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: (_currentPage <= 1) 
                      ? (isDark ? Colors.grey[700] : Colors.grey[300])
                      : (isDark ? Colors.blue[900] : Colors.blue[100]),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.arrow_left,
                    size: 18,
                    color: (_currentPage <= 1) 
                      ? (isDark ? Colors.grey[500] : Colors.grey[500])
                      : (isDark ? Colors.blue[300] : Colors.blue[700]),
                  ),
                ),
              ),
              SizedBox(width: 8),
              // 跳转页输入框
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
                  onSubmitted: (_) {
                    final page = int.tryParse(_pageController.text);
                    if (page != null && page > 0) {
                      _goToPage(page);
                    }
                  },
                  textInputAction: TextInputAction.go,
                ),
              ),
              SizedBox(width: 8),
              // 下一页按钮
              GestureDetector(
                onTap: (_isLoading || _isLoadingMore) 
                  ? null 
                  : () => _goToPage(_currentPage + 1),
                child: Container(
                  padding: EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.blue[900] : Colors.blue[100],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.arrow_right,
                    size: 18,
                    color: isDark ? Colors.blue[300] : Colors.blue[700],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _toggleAll() {
    setState(() {
      final currentVideos = _isAuthorPageMode ? _authorVideos : _results;
      if (_selectedIds.length == currentVideos.length) {
        _selectedIds.clear();
      } else {
        _selectedIds = currentVideos.map((v) => v.id).toSet();
      }
    });
  }
  
  /// 跳转到指定页
  Future<void> _goToPage(int page) async {
    if (page < 1 || _lastKeyword.isEmpty) return;
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;
    
    setState(() {
      _isLoading = true;
      _currentPage = page;
      _results.clear();
      _selectedIds.clear();
    });
    
    
    final results = await crawler.searchVideos(_lastKeyword, page: page, sort: _sortBy);
    
    setState(() {
      _results = results;
      _loadedPage = page;  // 更新已加载页码
      _hasMore = results.isNotEmpty;
      _isLoading = false;
    });
    
    // 滚动到顶部
    _scrollController.animateTo(0, duration: Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  Future<void> _search() async {
    if (_keywordController.text.isEmpty) return;
    
    setState(() {
      _status = '搜索中...';
    });
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) {
      setState(() {
        _status = '请先选择站点';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('请先在设置页选择站点')),
        );
      }
      return;
    }
    
    setState(() {
      _isLoading = true;
      _results.clear();
      _authorResults.clear();
      _selectedIds.clear();
      // 重置分页
      _currentPage = 1;
      _loadedPage = 0;
      _hasMore = true;
      _lastKeyword = _keywordController.text;
      _pageController.text = '1';
    });
    
    if (_isAuthorMode) {
      // 搜索作者
      final authors = await crawler.searchAuthors(_keywordController.text);
      
      setState(() {
        _authorResults = authors;
        _isLoading = false;
        _status = authors.isEmpty ? '无结果' : '就绪';
      });
    } else {
      // 搜索视频
      final results = await crawler.searchVideos(_keywordController.text, sort: _sortBy);
      
      setState(() {
        _results = results;
        _loadedPage = 1;  // 第一次搜索后，已加载第1页
        _selectedIds.clear();  // 默认不全选
        _isLoading = false;
        _status = results.isEmpty ? '无结果' : '就绪';
      });
    }
  }

  /// 构建视频搜索结果的 Sliver 版本
  Widget _buildVideoResultsSliver(AppState appState) {
    final isListMode = appState.videoDisplayMode == 'list';
    
    // 作者主页模式使用 _authorVideos，普通模式使用 _results
    final videos = _isAuthorPageMode ? _authorVideos : _results;
    final hasMore = _isAuthorPageMode ? _authorHasMore : _hasMore;
    
    // 加载中
    if (_isLoading && videos.isEmpty) {
      return SliverToBoxAdapter(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(height: 100),
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('搜索中...', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }
    
    // 无数据
    if (videos.isEmpty) {
      return SliverToBoxAdapter(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(height: 100),
              Icon(Icons.search, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text('输入关键词搜索', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }
    
    if (isListMode) {
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildVideoListItem(videos[index], appState, videos.length),
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

  /// 作者搜索结果的 Sliver 版本
  Widget _buildAuthorResultsSliver() {
    if (_authorResults.isEmpty) {
      return SliverToBoxAdapter(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(height: 100),
              Icon(Icons.person_search, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text('输入作者名搜索', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }
    
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final author = _authorResults[index];
          return Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundImage: author.avatar != null ? NetworkImage(author.avatar!) : null,
                child: author.avatar == null ? Icon(Icons.person) : null,
              ),
              title: Text(author.name),
              subtitle: Text(author.videoCount > 0 ? '视频数: ${author.videoCount}' : '点击查看视频'),
              trailing: Icon(Icons.chevron_right),
              onTap: () => _enterAuthorPageMode(author),
            ),
          );
        },
        childCount: _authorResults.length,
      ),
    );
  }
  
  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  /// 列表模式的单个视频项（与批量页保持一致）
  Widget _buildVideoListItem(VideoInfo video, AppState appState, int totalCount) {
    final isSelected = _selectedIds.contains(video.id);
    
    return GestureDetector(
      onTap: () => _toggleSelection(video.id),
      child: Card(
        color: isSelected ? Colors.blue.withOpacity(0.2) : null,
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Row(
            children: [
              // 封面图（与批量页一致：120x68）
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
                      // 选中标记（与批量页一致）
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
              // 信息：视频名称 + 作者
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(video.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14)),
                    SizedBox(height: 4),
                    // 作者（有 authorId 可点击跳转，否则只显示）
                    if (video.author != null && video.author!.isNotEmpty)
                      video.authorId != null && video.authorId!.isNotEmpty
                        ? Builder(
                            builder: (context) {
                              final isFollowed = appState.followedAuthorsService.isFollowedSync(video.authorId!);
                              return GestureDetector(
                                onTap: () => _enterAuthorPageMode(AuthorInfo(id: video.authorId!, name: video.author!, profileUrl: '')),
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
                            },
                          )
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

  /// 网格模式的单个视频项
  Widget _buildVideoGridItem(VideoInfo video, AppState appState) {
    final isSelected = _selectedIds.contains(video.id);
    
    return GestureDetector(
      onTap: () => _toggleSelection(video.id),
      child: Card(
        color: isSelected ? Colors.blue.withOpacity(0.2) : null,
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 缩略图
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
                            errorBuilder: (_, __, ___) => Center(
                              child: Icon(Icons.video_library, color: Colors.grey),
                            ),
                          ),
                          // 隐私模式模糊
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
                  // 时长
                  if (video.duration != null)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          video.duration ?? '',
                          style: TextStyle(color: Colors.white, fontSize: 10),
                        ),
                      ),
                    ),
                  // 选中标记
                  if (isSelected)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Icon(Icons.check_circle, color: Colors.blue),
                    ),
                ],
              ),
            ),
            // 标题
            Padding(
              padding: EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12),
                  ),
                  // 作者（有 authorId 可点击跳转，否则只显示）
                  if (video.author != null && video.author!.isNotEmpty)
                    video.authorId != null && video.authorId!.isNotEmpty
                      ? Builder(
                          builder: (context) {
                            final isFollowed = appState.followedAuthorsService.isFollowedSync(video.authorId!);
                            return GestureDetector(
                              onTap: () => _enterAuthorPageMode(AuthorInfo(id: video.authorId!, name: video.author!, profileUrl: '')),
                              child: Padding(
                                padding: EdgeInsets.fromLTRB(0, 2, 8, 0),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.person_outline, size: 12, color: Colors.blue),
                                    SizedBox(width: 2),
                                    Text(
                                      video.author!,
                                      style: TextStyle(fontSize: 10, color: Colors.blue),
                                    ),
                                    if (isFollowed) ...[
                                      SizedBox(width: 3),
                                      Container(
                                        padding: EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: Colors.red.withOpacity(0.8),
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                        child: Text('已关注', style: TextStyle(fontSize: 7, color: Colors.white)),
                                      ),
                                    ],
                                    Icon(Icons.chevron_right, size: 12, color: Colors.blue),
                                  ],
                                ),
                              ),
                            );
                          },
                        )
                      : Padding(
                          padding: EdgeInsets.fromLTRB(0, 2, 8, 0),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.person_outline, size: 12, color: Colors.grey),
                              SizedBox(width: 2),
                              Text(video.author!, style: TextStyle(fontSize: 10, color: Colors.grey)),
                            ],
                          ),
                        ),
                // 上传时间
                if (video.uploadDate != null && video.uploadDate!.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.fromLTRB(0, 2, 8, 0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.access_time, size: 10, color: Colors.grey),
                        SizedBox(width: 2),
                        Text(
                          video.uploadDate!,
                          style: TextStyle(fontSize: 9, color: Colors.grey),
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
    );
  }
  
  /// 下载选中的视频
  Future<void> _download() async {
    if (_selectedIds.isEmpty) return;
    
    final appState = context.read<AppState>();
    
    // 获取选中的视频（支持作者主页模式）
    final currentVideos = _isAuthorPageMode ? _authorVideos : _results;
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
    
    // 队列中已存在的视频，直接跳过并提示
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
            duration: Duration(seconds: 3),
            action: SnackBarAction(
              label: '查看',
              onPressed: () {
                // 切换到下载页面（索引3）
                appState.navigateToPage?.call(3);
              },
            ),
          ),
        );
      }
    }
    
    // 清空选择
    setState(() {
      _selectedIds.clear();
    });
  }
}
