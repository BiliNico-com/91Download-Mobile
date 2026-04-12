import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
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
  
  @override
  bool get wantKeepAlive => true;  // 保持页面状态
  
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
  
  /// 加载更多（下一页）
  Future<void> _loadMore() async {
    if (!_hasMore || _isLoading || _isLoadingMore || _lastKeyword.isEmpty) return;
    
    final appState = context.read<AppState>();
    final crawler = appState.crawler;
    if (crawler == null) return;
    
    setState(() => _isLoadingMore = true);
    _currentPage++;
    
    final newResults = await crawler.searchVideos(_lastKeyword, page: _currentPage, sort: _sortBy);
    
    if (newResults.isEmpty) {
      _hasMore = false;
    } else {
      setState(() {
        _results.addAll(newResults);
        // 如果返回结果少于每页数量，说明没有更多了
        if (newResults.length < 20) {
          _hasMore = false;
        }
      });
    }
    
    setState(() => _isLoadingMore = false);
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
      setState(() {
        _isAuthorPageMode = false;
        _authorVideos.clear();
        _authorCurrentPage = 0;
        _authorHasMore = true;
      });
    }
  }

  /// 进入作者主页模式
  Future<void> _enterAuthorPageMode(AuthorInfo author) async {
    setState(() {
      _isAuthorPageMode = true;
      _currentAuthorId = author.id;
      _currentAuthorName = author.name;
      _authorVideos.clear();
      _authorCurrentPage = 0;
      _authorHasMore = true;
    });
    await _loadMoreAuthorVideos();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);  // 必须调用
    
    return WillPopScope(
      onWillPop: () async {
        // 作者主页模式下拦截返回键
        if (_isAuthorPageMode) {
          _exitAuthorPageMode();
          return false;  // 不退出页面
        }
        return true;  // 正常返回
      },
      child: Consumer<AppState>(
        builder: (context, appState, _) {
          return Scaffold(
            extendBodyBehindAppBar: true,
            body: Stack(
              children: [
                CustomScrollView(
                  controller: _scrollController,
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
                            color: Colors.black.withOpacity(0.5),
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
                                              ? Text('作者: $_currentAuthorName', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500))
                                              : Text('搜索', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
                                            Text(
                                              _isAuthorPageMode 
                                                ? '点击作者主页查看视频' 
                                                : '通过关键词搜索并下载视频',
                                              style: TextStyle(fontSize: 12, color: Colors.grey)),
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
            // 覆盖层：翻页控件 + 浮动按钮
            ..._buildOverlays(appState),
          ],
        ),
      );
    },
  ),
);
}
  
  /// 覆盖层：翻页控件 + 浮动按钮
  List<Widget> _buildOverlays(AppState appState) {
    return [
      // 页码跳转悬浮胶囊（仅视频搜索模式显示）
      if (!_isAuthorMode) _buildBottomPageNavigation(appState),
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

  /// 搜索栏（吸顶内容）
  Widget _buildSearchBar(AppState appState) {
    final siteType = appState.crawler?.siteType ?? 'original';
    final showSort = !_isAuthorMode && siteType != 'porn91';
    final isDark = appState.isDarkMode;
    
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isDark ? Color(0xFF2a2a2a) : Colors.white.withOpacity(0.95),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            // 外发光效果
            BoxShadow(
              color: isDark ? Colors.blue.withOpacity(0.15) : Colors.black.withOpacity(0.08),
              blurRadius: 12,
              spreadRadius: 1,
              offset: Offset(0, 0),
            ),
            // 基础阴影
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
              // 搜索框
              Container(
                width: 140,
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: isDark ? Color(0xFF252525) : Colors.grey[100],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: TextField(
                  controller: _keywordController,
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: '输入关键词...',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    isDense: true,
                    hintStyle: TextStyle(fontSize: 11, color: isDark ? Colors.grey[500] : Colors.grey[600]),
                  ),
                  style: TextStyle(fontSize: 11, color: isDark ? Colors.white70 : Colors.black87),
                  onSubmitted: (_) => _search(),
                  textInputAction: TextInputAction.search,
                ),
              ),
              SizedBox(width: 8),
              // 排序选择（仅视频模式 + original CMS）
              if (showSort) ...[
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  decoration: BoxDecoration(
                    color: isDark ? Color(0xFF303030) : Colors.grey[100],
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: isDark ? Color(0xFF444444) : Colors.grey[300]!, width: 0.5),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _sortBy,
                      isDense: true,
                      style: TextStyle(fontSize: 11, color: isDark ? Colors.grey[300] : Colors.black87),
                      items: [
                        DropdownMenuItem(value: 'default', child: Text('默认', style: TextStyle(fontSize: 11, color: isDark ? Colors.grey[300] : Colors.black87))),
                        DropdownMenuItem(value: 'new', child: Text('最新', style: TextStyle(fontSize: 11, color: isDark ? Colors.grey[300] : Colors.black87))),
                        DropdownMenuItem(value: 'hot', child: Text('最热', style: TextStyle(fontSize: 11, color: isDark ? Colors.grey[300] : Colors.black87))),
                      ],
                      onChanged: (v) {
                        if (v != null && v != _sortBy) {
                          setState(() => _sortBy = v);
                          if (_lastKeyword.isNotEmpty) {
                            _search();
                          }
                        }
                      },
                    ),
                  ),
                ),
                SizedBox(width: 8),
              ],
              // 搜索模式选择
              Container(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  color: isDark ? Color(0xFF303030) : Colors.grey[100],
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: isDark ? Color(0xFF444444) : Colors.grey[300]!, width: 0.5),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<bool>(
                    value: _isAuthorMode,
                    isDense: true,
                    style: TextStyle(fontSize: 11, color: isDark ? Colors.grey[300] : Colors.black87),
                    items: [
                      DropdownMenuItem(value: false, child: Text('搜视频', style: TextStyle(fontSize: 11, color: isDark ? Colors.grey[300] : Colors.black87))),
                      DropdownMenuItem(value: true, child: Text('搜作者', style: TextStyle(fontSize: 11, color: isDark ? Colors.grey[300] : Colors.black87))),
                    ],
                    onChanged: (v) => setState(() => _isAuthorMode = v!),
                  ),
                ),
              ),
              SizedBox(width: 8),
              // 搜索按钮（渐变色）
              GestureDetector(
                onTap: _search,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Color(0xFF4a9eff), Color(0xFF2d7dd2)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: Color(0xFF4a9eff).withOpacity(0.4),
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(Icons.search, color: Colors.white, size: 18),
                ),
              ),
            ],
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

  /// 列表模式的单个视频项
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
              // 缩略图 + 时长 + 选中标记
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 120, 
                  height: 80,
                  color: Colors.grey[800],
                  child: video.cover != null
                    ? Stack(
                        children: [
                          Center(
                            child: Image.network(video.cover!, width: 120, height: 80, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Icon(Icons.video_file, size: 32, color: Colors.white54)),
                          ),
                          // 毛玻璃模糊遮罩
                          if (appState.privacyMode)
                            Positioned.fill(
                              child: ClipRect(
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                                  child: Container(
                                    color: Colors.black.withOpacity(0.3),
                                  ),
                                ),
                              ),
                            ),
                          // 选中标记（左上角）
                          if (isSelected)
                            Positioned(
                              top: 4,
                              left: 4,
                              child: Container(
                                padding: EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  color: Colors.blue,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(Icons.check, size: 12, color: Colors.white),
                              ),
                            ),
                          // 时长标签（右下角）
                          if (video.duration != null)
                            Positioned(
                              bottom: 4,
                              right: 4,
                              child: Container(
                                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.black87,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  video.duration!,
                                  style: TextStyle(color: Colors.white, fontSize: 10),
                                ),
                              ),
                            ),
                        ],
                      )
                    : Icon(Icons.video_file, size: 32, color: Colors.white54),
                ),
              ),
              SizedBox(width: 12),
              // 信息：视频名称 + 作者
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      video.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14),
                    ),
                    if (video.author != null) ...[
                      SizedBox(height: 4),
                      Text(
                        video.author!,
                        style: TextStyle(fontSize: 12, color: Colors.grey),
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
                  if (video.author != null) ...[
                    SizedBox(height: 2),
                    Text(
                      video.author!,
                      style: TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                  ],
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
    
    // 添加到下载管理器
    for (final video in selectedVideos) {
      appState.downloadManager.addTask(video);
    }
    
    // 显示提示
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已添加 ${selectedVideos.length} 个视频到下载队列'),
          action: SnackBarAction(
            label: '查看',
            onPressed: () {
              // 切换到下载页面（索引2）
              appState.navigateToPage?.call(2);
            },
          ),
        ),
      );
    }
    
    // 清空选择
    setState(() {
      _selectedIds.clear();
    });
  }
}
