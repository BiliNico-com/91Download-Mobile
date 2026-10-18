import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../services/followed_authors_service.dart';
import '../models/video_info.dart';
import '../utils/logger.dart';
import '../components/video_card.dart';
import '../components/empty_state.dart';
import '../components/video_list_items.dart';
import '../components/skeleton_card.dart';
import '../utils/debouncer.dart';
import '../theme/app_theme.dart';
import '../theme/ui_style.dart';
import 'streaming_page.dart';

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

  /// 上一次渲染时的站点地址，用于检测"更换网址"并清掉旧站结果
  String? _lastSiteUrl;
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
  // 页码输入框焦点（用于判断能否安全写入页码）
  final FocusNode _pageFocusNode = FocusNode();
  // 关键词输入框焦点（聚焦时展示搜索历史）
  final FocusNode _keywordFocusNode = FocusNode();
  // 是否展示搜索历史下拉
  bool _showHistory = false;
  bool _showBackToTop = false;
  String _status = '就绪';  // 就绪状态
  
  // 进入作者主页前的滚动位置（返回时恢复）
  double _savedScrollOffset = 0;
  
  // 搜索防抖器
  late final Debouncer _searchDebouncer;
  
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
    _searchDebouncer = Debouncer(milliseconds: 500);
    _keywordFocusNode.addListener(_onKeywordFocusChange);
  }

  /// 输入框获得焦点且历史非空时展示历史下拉
  void _onKeywordFocusChange() {
    final focused = _keywordFocusNode.hasFocus;
    if (focused) {
      final appState = context.read<AppState>();
      final has = appState.searchHistory.isNotEmpty;
      if (has && !_showHistory) {
        setState(() => _showHistory = true);
      }
    } else if (_showHistory) {
      setState(() => _showHistory = false);
    }
  }

  /// 点击历史条目：填充并立即搜索
  void _applyHistory(AppState appState, String keyword) {
    _keywordController.text = keyword;
    // 输入框处于焦点时直接赋值 controller.text 不会同步光标位置，
    // 这里用 setState 让 TextField 重新读取 controller 值。
    setState(() {
      _showHistory = false;
      _isAuthorPageMode = false;
      _currentPage = 1;
    });
    _keywordFocusNode.unfocus();
    _search();
  }

  /// 从输入框内容记录一条历史
  void _rememberKeyword(AppState appState, String keyword) {
    final k = keyword.trim();
    if (k.isEmpty) return;
    appState.searchHistory.add(k);
  }
  
  @override
  void dispose() {
    _searchDebouncer.dispose();
    // 清除返回键回调
    try {
      context.read<AppState>().onWillPopCallback = null;
    } catch (_) {}
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _pageFocusNode.dispose();
    _keywordFocusNode.removeListener(_onKeywordFocusChange);
    _keywordFocusNode.dispose();
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
    _scrollController.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
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
        _currentPage = 1;  // 下拉刷新回到第1页
        _loadedPage = 1;
        _hasMore = results.isNotEmpty;
      });
      // 同步页码输入框显示（放在 setState 之外）
      _syncPageController('1');
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
      // 由爬虫依据站点"下一页"控件判定是否还有更多（条数不固定时更可靠）
      final siteHasMore = crawler.lastRequestHasMore;
      setState(() {
        // 去重：过滤掉已存在的视频
        final existingIds = _results.map((v) => v.id).toSet();
        final uniqueNewResults = newResults.where((v) => !existingIds.contains(v.id)).toList();
        _results.addAll(uniqueNewResults);
        _loadedPage = nextPage;
        _currentPage = nextPage;
        _hasMore = siteHasMore;
        _isLoadingMore = false;
      });
      // 同步页码输入框显示
      _syncPageController('$nextPage');
    }
  }

  /// 把页码同步到胶囊输入框
  ///
  /// 注意：仅在输入框「未获得焦点」时直接赋值。TextField 处于焦点时
  /// Flutter 会用其内部编辑态覆盖 controller.text，导致滚动加载后
  /// 页码显示不更新（手动点翻页时输入框通常已失焦，所以看起来是好的）。
  /// 聚焦时先收起键盘并解焦，再在下一帧写入，确保显示以代码为准。
  void _syncPageController(String value) {
    if (!mounted) return;
    final node = _pageFocusNode;
    if (node.hasFocus) {
      node.unfocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pageController.text = value;
      });
    } else {
      _pageController.text = value;
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
      // 由爬虫依据站点"下一页"控件判定（条数不固定时更可靠）
      final siteHasMore = crawler.lastRequestHasMore;
      setState(() {
        // 去重：过滤掉已存在的视频
        final existingIds = _authorVideos.map((v) => v.id).toSet();
        final uniqueNewVideos = newVideos.where((v) => !existingIds.contains(v.id)).toList();
        _authorVideos.addAll(uniqueNewVideos);
        _authorHasMore = siteHasMore;
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
        // ── 更换网址处理 ──
        // 本页被 KeepAlive 保活，换站后旧站的搜索结果会一直留在这里，
        // 用户看到的是"另一个网站的内容"。以网址为准清空一次。
        // 首次构建只记录，不触发（否则会与自动搜索重复）。
        final siteUrl = appState.currentSite ?? '';
        if (_lastSiteUrl == null) {
          _lastSiteUrl = siteUrl;
        } else if (_lastSiteUrl != siteUrl) {
          _lastSiteUrl = siteUrl;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _results.clear();
              _authorResults.clear();
              _selectedIds.clear();
              _currentPage = 1;
              _loadedPage = 0;
              _hasMore = true;
              _status = '就绪';
              // 站点都换了，作者主页模式必然失效
              _isAuthorPageMode = false;
            });
            _syncPageController('1');
          });
        }

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
                      
                      return ValueListenableBuilder<bool>(
                        valueListenable: UiStyle.glassEnabled,
                        builder: (context, glass, _) {
                          final isDark =
                              Theme.of(context).brightness == Brightness.dark;

                          // 关闭玻璃 → 完全不透明，内容被挡住；
                          // 开启 → 半透明，列表从栏下穿过时可见模糊。
                          final barColor = !glass
                              ? (isDark ? const Color(0xFF242424) : Colors.white)
                              : (isExpanded
                                  ? (isDark
                                      ? Colors.black.withOpacity(0.45)
                                      : Colors.white.withOpacity(0.72))
                                  : (isDark
                                      ? Colors.black.withOpacity(0.65)
                                      : Colors.white.withOpacity(0.88)));

                          final bar = Container(
                            color: barColor,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 状态栏占位
                                SizedBox(height: statusBarHeight),
                                // 标题区域（滚动时隐藏）
                                AnimatedOpacity(
                                  opacity: isExpanded ? 1.0 : 0.0,
                                  duration: const Duration(milliseconds: 150),
                                  child: Container(
                                    height: 56,
                                    padding: EdgeInsets.only(left: 16, right: 8),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              _isAuthorPageMode
                                                ? Row(
                                                    children: [
                                                      Flexible(
                                                        child: Text('作者: $_currentAuthorName', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black87)),
                                                      ),
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
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                // 搜索区域（始终可见，吸附到顶部）
                                Container(
                                  height: 56,
                                  color: glass
                                      ? Theme.of(context)
                                          .scaffoldBackgroundColor
                                          .withOpacity(0.95)
                                      : (isDark
                                          ? const Color(0xFF242424)
                                          : Colors.white),
                                  child: Row(
                                    children: [
                                      Expanded(child: _buildSearchBar(appState)),
                                      // 状态与隐私按钮常显：收起后标题行淡出，
                                      // 若跟着一起藏起来就没地方看当前状态了。
                                      // 与批量页行为保持一致。
                                      Padding(
                                        padding: EdgeInsets.only(right: 4),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: _buildAppBarActions(appState),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );

                          if (!glass) return bar;

                          return ClipRect(
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                              child: bar,
                            ),
                          );
                        },
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
      // 搜索历史下拉：必须是 Stack 里的独立一层。
      // 早前它挂在 SliverAppBar.flexibleSpace 内部，而 expandedHeight
      // 只算到「标题区 56 + 搜索框 56」，下拉撑开的部分落在 sliver 的
      // ClipRect 之外 —— 那块区域不属于任何控件，点击会直接穿到下层
      // 视频卡片上。移到 Stack 里作为独立层后命中测试才正确。
      if (_showHistory && appState.searchHistory.isNotEmpty && !_isAuthorPageMode)
        _buildHistoryOverlay(appState),
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

  /// 搜索历史覆盖层
  ///
  /// 用 GestureDetector(behavior: opaque) 铺满全屏来截住所有落在列表上的点击，
  /// 点空白处收起历史，点条目则应用关键词 —— 不再穿透到下层视频卡片。
  Widget _buildHistoryOverlay(AppState appState) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final statusBarHeight = MediaQuery.of(context).padding.top;
    // 搜索栏下沿：状态栏 + 标题区(56) + 搜索框(56)
    final double top = statusBarHeight + 112;

    return Positioned.fill(
      child: GestureDetector(
        // 拦截整层命中，避免点到下方列表
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _showHistory = false),
        child: Stack(
          children: [
            Positioned(
              top: top,
              left: 0,
              right: 0,
              child: GestureDetector(
                // 下拉本体自己消费点击，不让它冒泡到收起逻辑
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: _buildSearchHistoryDropdown(appState, isDark),
              ),
            ),
          ],
        ),
      ),
    );
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
    // 用实际渲染主题判断深浅色，避免与「跟随系统」设置不一致
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    // 作者主页模式下，隐藏下拉菜单，只显示返回按钮和搜索框
    if (_isAuthorPageMode) {
      return Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
            borderRadius: BorderRadius.circular(AppTheme.radiusPill),
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
    
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSearchBarRow(isDark, showSort),
      ],
    );
  }

  /// 搜索栏本体（胶囊输入框 + 分段控件 + 搜索按钮）
  Widget _buildSearchBarRow(bool isDark, bool showSort) {
    // Container(color:) 只负责绘制，不参与命中测试。
    // 包一层 opaque 的 GestureDetector，让搜索栏自己吃掉点击，
    // 避免落在栏空白处的点击穿透到下面的视频列表。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // 点搜索栏空白处：收起历史下拉
        if (_showHistory) setState(() => _showHistory = false);
      },
      child: Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          // 去线化：与胶囊翻页器风格统一，取消外边框
          color: isDark ? const Color(0xFF2C2C2E) : Colors.grey.shade50,
          borderRadius: BorderRadius.circular(AppTheme.radiusPill),
          // 使用弥散阴影建立悬浮感，替代边框
          boxShadow: isDark
              ? [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.25),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.grey.shade400.withOpacity(0.2),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
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
                  focusNode: _keywordFocusNode,
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
                  onChanged: (value) {
                    if (value.trim().isNotEmpty) {
                      _searchDebouncer.run(() => _search());
                    }
                  },
                  onSubmitted: (_) => _search(),
                  onTap: () {
                    // 点回输入框时重新展开历史（焦点未变化时 listener 不会触发）
                    final appState = context.read<AppState>();
                    if (appState.searchHistory.isNotEmpty && !_showHistory) {
                      setState(() => _showHistory = true);
                    }
                  },
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
            // 搜索类型：分段控件（只有两个选项，同时可见、一次点击）
            // 原来用下拉，需要"点开→选"两步，且看不出另一个选项是什么。
            _buildSearchTypeSegmented(isDark),
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
                    // 切换排序必然重置到第 1 页，明确告知避免"我明明在第 5 页"的困惑
                    const labels = {'default': '默认', 'new': '最新', 'hot': '最热'};
                    _showSearchToast('已按「${labels[v] ?? v}」排序，已回到第 1 页');
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
      ),
    );
  }

  /// 搜索历史下拉
  ///
  /// 展示在搜索栏下方，点击条目直接搜索；右侧 × 删除单条；右上角清空全部。
  Widget _buildSearchHistoryDropdown(AppState appState, bool isDark) {
    final entries = appState.searchHistory.entries;

    return Container(
      margin: EdgeInsets.fromLTRB(16, 0, 16, 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2C2C2E) : Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.35 : 0.12),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行 + 清空
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 4),
            child: Row(
              children: [
                Icon(Icons.history, size: 14,
                    color: isDark ? Colors.white.withOpacity(0.45) : Colors.grey),
                const SizedBox(width: 6),
                Text(
                  '搜索历史',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white.withOpacity(0.45) : Colors.grey,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    await appState.searchHistory.clear();
                    if (!mounted) return;
                    setState(() => _showHistory = false);
                  },
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('清空', style: TextStyle(fontSize: 12, color: Colors.grey)),
                ),
              ],
            ),
          ),
          // 历史条目（最多展示 8 条，避免下拉过高遮挡结果）
          ...entries.take(8).map((keyword) => InkWell(
                onTap: () => _applyHistory(appState, keyword),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          keyword,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: isDark ? Colors.white.withOpacity(0.85) : Colors.black87,
                          ),
                        ),
                      ),
                      // 单条删除
                      GestureDetector(
                        onTap: () => appState.searchHistory.remove(keyword),
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Icon(
                            Icons.close,
                            size: 16,
                            color: isDark ? Colors.white.withOpacity(0.3) : Colors.grey.shade400,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )),
          const SizedBox(height: 4),
        ],
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

  /// 搜索类型分段控件（视频 / 作者）
  ///
  /// 只有两个选项，用分段控件让两者**同时可见、一次点击**即可切换；
  /// 原来用下拉需要"点开 → 选"两步，且看不出另一个选项是什么。
  ///
  /// 切换后会：
  ///   · 若已有搜索关键词，自动用该关键词重新搜索（避免状态与结果不一致）
  ///   · 若没有关键词，清空结果并提示输入
  Widget _buildSearchTypeSegmented(bool isDark) {
    final trackBg = isDark ? const Color(0xFF2C2C2E) : const Color(0xFFECEFF3);
    final unselectedFg = isDark ? Colors.white70 : const Color(0xFF5F6368);

    Widget item(String label, bool value) {
      final on = _isAuthorMode == value;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: on ? null : () => _onSearchTypeChanged(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 170),
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? (isDark ? const Color(0xFF3A3A3C) : Colors.white) : null,
            borderRadius: BorderRadius.circular(AppTheme.radiusMd - 1),
            boxShadow: on
                ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.13),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: on ? AppTheme.primaryColor : unselectedFg,
              fontWeight: on ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: trackBg,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          item('视频', false),
          item('作者', true),
        ],
      ),
    );
  }

  /// 切换搜索类型
  ///
  /// 原来的实现只改标志位、不动结果，会出现"切到搜作者后，
  /// 屏幕上还留着上一次的视频结果"。这里让状态与结果保持一致：
  /// 输入框有内容就立刻按新类型重搜，没有就清空结果并提示输入。
  void _onSearchTypeChanged(bool toAuthor) {
    if (_isAuthorMode == toAuthor) return;

    final keyword = _keywordController.text.trim();

    setState(() {
      _isAuthorMode = toAuthor;
      _selectedIds.clear();
      // 结果与当前类型不再匹配，先清空，避免闪出错误内容
      _results.clear();
      _authorResults.clear();
      _currentPage = 1;
      _hasMore = true;
      _status = '就绪';
    });
    _syncPageController('1');
    _updateWillPopCallback();

    if (keyword.isNotEmpty) {
      _showSearchToast('已切换到搜${toAuthor ? "作者" : "视频"}，正在重新搜索');
      _search(); // _search 内部会按 _isAuthorMode 分流
    } else {
      _showSearchToast('已切换到搜${toAuthor ? "作者" : "视频"}，请输入关键词');
    }
  }

  /// 搜索页轻提示
  ///
  /// 统一封装，避免各处重复写 ScaffoldMessenger（并确保先 hide 掉上一条，
  /// 否则连续切换时提示会排队、显示滞后）。
  void _showSearchToast(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(milliseconds: 1600),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
      ),
    );
  }

  /// 底部页码跳转区域（悬浮胶囊）
  Widget _buildBottomPageNavigation(AppState appState) {
    // 用实际渲染主题判断深浅色，避免与「跟随系统」设置不一致
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Positioned(
      bottom: 16,
      left: 0,
      right: 0,
      child: Center(
        // 通过 AdaptiveSurface 统一风格：开启毛玻璃时为半透明模糊，
        // 关闭时回落为实心色（设置页可实时切换）。
        child: AdaptiveSurface(
          borderRadius: AppTheme.brPill,
          solid: true,
          fallbackColor:
              isDark ? Colors.grey[850] : Colors.white.withOpacity(0.95),
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 上一页按钮
              GestureDetector(
                onTap: (_isLoading || _isLoadingMore || _currentPage <= 1)
                  ? null
                  : () => _goToPage(_currentPage - 1),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: (_currentPage <= 1)
                      ? (isDark ? Colors.grey[700] : Colors.grey[300])
                      : (isDark ? Colors.blue[900] : Colors.blue[100]),
                    borderRadius: BorderRadius.circular(AppTheme.radiusPill),
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
              const SizedBox(width: 10),
              // 当前页码输入框 — 既是页码显示器也是跳转输入器
              Container(
                width: 64,
                height: 32,
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF2C2C2E) : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: isDark
                          ? Colors.black.withOpacity(0.3)
                          : Colors.grey.shade300.withOpacity(0.5),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Center(
                  child: TextField(
                    controller: _pageController,
                    focusNode: _pageFocusNode,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                    decoration: const InputDecoration(
                      hintText: '',
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
              ),
              const SizedBox(width: 10),
              // 下一页按钮
              GestureDetector(
                onTap: (_isLoading || _isLoadingMore)
                  ? null
                  : () => _goToPage(_currentPage + 1),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.blue[900] : Colors.blue[100],
                    borderRadius: BorderRadius.circular(AppTheme.radiusPill),
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

  void _toggleAll() {    setState(() {
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

    // 同步页码输入框显示
    _syncPageController('$page');
    
    // 滚动到顶部
    _scrollController.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
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
    });
    // 同步页码输入框显示（放在 setState 之外，与 _goToPage/_loadMore 保持一致）
    _syncPageController('1');

    // 记录搜索历史（自动去重并置顶；空白词已在 service 内过滤）
    _rememberKeyword(appState, _keywordController.text);
    // 搜索后收起历史下拉
    if (_showHistory) {
      setState(() => _showHistory = false);
    }
    
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
  /// 列表模式的单个视频项
  ///
  /// 呈现逻辑已抽到共用组件 [VideoListItem]，这里只提供本页特有的交互
  /// （选中切换、封面点击在线播放、作者跳转）。
  Widget _buildVideoListItem(VideoInfo video, AppState appState, int totalCount) {
    final isSelected = _selectedIds.contains(video.id);
    final authorId = video.authorId;

    return VideoListItem(
      video: video,
      appState: appState,
      isSelected: isSelected,
      showUploadDate: true,
      onTap: () => _toggleSelection(video.id),
      onCoverTap: appState.streamingMode
          ? () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => StreamingPage(video: video)),
              )
          : null,
      onAuthorTap: (authorId != null && authorId.isNotEmpty)
          ? () => _enterAuthorPageMode(
                AuthorInfo(id: authorId, name: video.author ?? '', profileUrl: ''),
              )
          : null,
      isAuthorFollowed: (authorId != null && authorId.isNotEmpty)
          ? appState.followedAuthorsService.isFollowedSync(authorId)
          : false,
    );
  }

  /// 网格模式的单个视频项
  /// 网格模式的单个视频项 —— 呈现抽到共用组件
  Widget _buildVideoGridItem(VideoInfo video, AppState appState) {
    final isSelected = _selectedIds.contains(video.id);

    return VideoGridItem(
      video: video,
      appState: appState,
      isSelected: isSelected,
      onTap: () => _toggleSelection(video.id),
      onCoverTap: appState.streamingMode
          ? () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => StreamingPage(video: video)),
              )
          : null,
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
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${inQueue.length} 个视频已在下载队列中，已跳过'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
    
    // 上面的循环里 await 过（isVideoDownloaded），页面可能已被销毁。
    // 之后还要用 context 弹窗，这里必须先确认仍然挂载。
    if (!mounted) return;

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
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
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
